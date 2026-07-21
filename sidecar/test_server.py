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
    assert TestClient(server.app).get("/health").json() == {"ok": True}


def test_stats(monkeypatch):
    monkeypatch.setattr(server, "db", lambda: FakeDB())
    data = TestClient(server.app).get("/stats").json()
    assert data["count"] == 3
    assert data["size_gb"] == 3.0


def test_photos_paginates(monkeypatch):
    items = [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    data = TestClient(server.app).get("/photos?offset=1&limit=1").json()
    assert data["total"] == 3
    assert [p["uuid"] for p in data["photos"]] == ["b"]


def test_thumb_serves_and_404(monkeypatch, tmp_path):
    f = tmp_path / "t.jpg"
    f.write_bytes(b"\xff\xd8\xff")  # jpeg magic bytes
    items = [FakePhoto("a", deriv=[str(f)])]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    client = TestClient(server.app)
    assert client.get("/thumb/a").status_code == 200
    assert client.get("/thumb/missing").status_code == 404


def _patch_engine(monkeypatch, candidates):
    monkeypatch.setattr(server, "db", lambda: object())
    monkeypatch.setattr(server.common, "load_ignore_albums", lambda extra=None: frozenset())
    monkeypatch.setattr(
        server.common, "get_candidate_photos", lambda pdb, ignore, **kw: (candidates, {})
    )


def test_cleanup_screenshots(monkeypatch):
    _patch_engine(monkeypatch, [FakePhoto("a"), FakePhoto("b")])
    data = TestClient(server.app).get("/cleanup/screenshots").json()
    assert data["count"] == 2
    assert {p["uuid"] for p in data["photos"]} == {"a", "b"}


def test_cleanup_low_quality_filters_by_score(monkeypatch):
    _patch_engine(monkeypatch, [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")])
    scores = {"a": 0.005, "b": 0.5, "c": None}  # c is unscored -> excluded
    monkeypatch.setattr(server.common, "get_photo_score", lambda p: scores[p.uuid])
    data = TestClient(server.app).get("/cleanup/low-quality?threshold=0.01").json()
    assert [p["uuid"] for p in data["photos"]] == ["a"]


def test_cleanup_unknown_404(monkeypatch):
    _patch_engine(monkeypatch, [])
    assert TestClient(server.app).get("/cleanup/bogus").status_code == 404


def test_commit_adds_to_pass_album(monkeypatch):
    items = [FakePhoto("a"), FakePhoto("b")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    called = {}

    def fake_add(photos, album, dry_run, assume_yes):
        called.update(n=len(photos), album=album, dry_run=dry_run, assume_yes=assume_yes)

    monkeypatch.setattr(server.common, "add_to_album", fake_add)
    r = TestClient(server.app).post("/commit", json={"kind": "screenshots", "uuids": ["a", "b"]})
    assert r.json() == {"added": 2, "album": "Screenshots - Delete Me"}
    assert called == {
        "n": 2,
        "album": "Screenshots - Delete Me",
        "dry_run": False,
        "assume_yes": True,
    }


def test_commit_unknown_kind_404(monkeypatch):
    monkeypatch.setattr(server, "_index", lambda: ([], {}))
    r = TestClient(server.app).post("/commit", json={"kind": "bogus", "uuids": ["a"]})
    assert r.status_code == 404


def test_commit_no_matching_400(monkeypatch):
    monkeypatch.setattr(server, "_index", lambda: ([], {}))
    monkeypatch.setattr(server.common, "add_to_album", lambda *a, **k: None)
    r = TestClient(server.app).post("/commit", json={"kind": "screenshots", "uuids": ["missing"]})
    assert r.status_code == 400
