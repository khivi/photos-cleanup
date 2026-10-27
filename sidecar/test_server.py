"""Sidecar tests. The engine's PhotosDB is mocked so these run without a real
Photos library (no TCC / Full Disk Access needed in CI)."""

from fastapi.testclient import TestClient

from sidecar import server


class FakePhoto:
    def __init__(self, uuid="x", size=0, deriv=None):
        self.uuid = uuid
        self.original_filename = f"{uuid}.jpg"
        self.width = 100
        self.height = 100
        self.date = None
        self.ismovie = False
        self.original_filesize = size
        self.path_derivatives = deriv or []


class FakeDB:
    def photos(self):
        # 1 GiB + unscored(None) + 2 GiB -> count 3, size 3.0 GB
        return [FakePhoto(size=1024**3), FakePhoto(size=None), FakePhoto(size=2 * 1024**3)]


def test_health():
    assert TestClient(server.app, base_url="http://127.0.0.1").get("/health").json() == {"ok": True}


def test_no_cors_headers():
    r = TestClient(server.app, base_url="http://127.0.0.1").get(
        "/health", headers={"Origin": "https://evil.example"}
    )
    assert "access-control-allow-origin" not in r.headers


def test_rejects_foreign_host():
    r = TestClient(server.app, base_url="http://127.0.0.1").get(
        "/health", headers={"Host": "evil.example"}
    )
    assert r.status_code == 400


def test_stats(monkeypatch):
    monkeypatch.setattr(server, "db", lambda: FakeDB())
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/stats").json()
    assert data["count"] == 3
    assert data["size_gb"] == 3.0


def test_photos_returns_all(monkeypatch):
    items = [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/photos").json()
    assert data["total"] == 3
    assert [p["uuid"] for p in data["photos"]] == ["a", "b", "c"]


def test_thumb_serves_and_404(monkeypatch, tmp_path):
    f = tmp_path / "t.jpg"
    f.write_bytes(b"\xff\xd8\xff")  # jpeg magic bytes
    items = [FakePhoto("a", deriv=[str(f)])]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    client = TestClient(server.app, base_url="http://127.0.0.1")
    assert client.get("/thumb/a").status_code == 200
    assert client.get("/thumb/missing").status_code == 404


def _patch_engine(monkeypatch, candidates, verdicts=None):
    monkeypatch.setattr(server, "db", lambda: object())
    monkeypatch.setattr(server.common, "load_ignore_albums", lambda extra=None: frozenset())
    monkeypatch.setattr(
        server.common, "get_candidate_photos", lambda pdb, ignore, **kw: (candidates, {})
    )
    monkeypatch.setattr(server, "_verdicts", lambda: verdicts or {})
    monkeypatch.setattr(server, "_start_classifier", lambda photos: None)
    monkeypatch.setattr(server, "_committed", set())


def test_cleanup_screenshots_attaches_verdicts(monkeypatch):
    verdict = {"keep": False, "kind": "receipt", "reason": "Paid coffee receipt"}
    _patch_engine(monkeypatch, [FakePhoto("a"), FakePhoto("b")], {"a": verdict})
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/screenshots").json()
    assert data["count"] == 2
    assert {p["uuid"]: p["verdict"] for p in data["photos"]} == {"a": verdict, "b": None}
    assert data["classify"] == {"pending": 0, "error": None}


def test_cleanup_low_quality_filters_by_score(monkeypatch):
    _patch_engine(monkeypatch, [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")])
    scores = {"a": 0.005, "b": 0.5, "c": None}  # c is unscored -> excluded
    monkeypatch.setattr(server.common, "get_photo_score", lambda p: scores[p.uuid])
    data = (
        TestClient(server.app, base_url="http://127.0.0.1")
        .get("/cleanup/low-quality?threshold=0.01")
        .json()
    )
    assert [p["uuid"] for p in data["photos"]] == ["a"]
    assert data["photos"][0]["verdict"] is None


def test_cleanup_unknown_404(monkeypatch):
    _patch_engine(monkeypatch, [])
    assert (
        TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/bogus").status_code == 404
    )


def test_parse_verdict():
    assert server._parse_verdict("u1\treceipt\t0\tPaid") == (
        "u1",
        {"keep": False, "kind": "receipt", "reason": "Paid"},
    )
    assert server._parse_verdict("u2\tSKIP")[1]["keep"] is True
    assert server._parse_verdict("u3\tERR\tboom") == ("u3", None)
    assert server._parse_verdict("garbage") == ("garbage", None)


def test_commit_files_delete_and_keep_then_hides_them(monkeypatch):
    items = [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    _patch_engine(monkeypatch, items)
    calls = []
    monkeypatch.setattr(
        server.common,
        "add_to_album",
        lambda photos, album, **kw: calls.append(([p.uuid for p in photos], album, kw)),
    )
    client = TestClient(server.app, base_url="http://127.0.0.1")
    r = client.post("/commit", json={"kind": "screenshots", "uuids": ["a"], "keep": ["b"]})
    assert r.json() == {
        "added": 1,
        "album": "Screenshots - Delete Me",
        "kept": 1,
        "keep_album": "Screenshots - Keep",
    }
    assert calls == [
        (["a"], "Screenshots - Delete Me", {"assume_yes": True, "replace": False}),
        (["b"], "Screenshots - Keep", {"assume_yes": True, "replace": False}),
    ]
    remaining = client.get("/cleanup/screenshots").json()["photos"]
    assert [p["uuid"] for p in remaining] == ["c"]


def test_commit_unknown_kind_404(monkeypatch):
    monkeypatch.setattr(server, "_index", lambda: ([], {}))
    r = TestClient(server.app, base_url="http://127.0.0.1").post(
        "/commit", json={"kind": "bogus", "uuids": ["a"]}
    )
    assert r.status_code == 404


def test_commit_no_matching_400(monkeypatch):
    monkeypatch.setattr(server, "_index", lambda: ([], {}))
    monkeypatch.setattr(server.common, "add_to_album", lambda *a, **k: None)
    r = TestClient(server.app, base_url="http://127.0.0.1").post(
        "/commit", json={"kind": "screenshots", "uuids": ["missing"], "keep": ["gone"]}
    )
    assert r.status_code == 400
