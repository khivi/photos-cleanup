"""Server tests. The engine's PhotosDB is mocked so these run without a real
Photos library (no TCC / Full Disk Access needed in CI)."""

import json
import socket
import subprocess
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from photos_cleanup import cli, server


class FakePhoto:
    def __init__(self, uuid="x", size=0, deriv=None, albums=(), path="/img.jpg"):
        self.uuid = uuid
        self.albums = list(albums)
        self.original_filename = f"{uuid}.jpg"
        self.width = 100
        self.height = 100
        self.date = None
        self.ismovie = False
        self.original_filesize = size
        self.path_derivatives = deriv or []
        self.path = path


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
    assert data["classify"] == {"pending": 0, "total": 0, "error": None}


def test_cleanup_utility_shows_only_classified_non_pictures(monkeypatch):
    receipt = {"keep": False, "kind": "receipt", "reason": "Paid"}
    picture = {"keep": True, "kind": "picture", "reason": "Not a utility image"}
    _patch_engine(
        monkeypatch,
        [FakePhoto("a"), FakePhoto("b"), FakePhoto("c"), FakePhoto("noimg", path=None)],
        {"a": receipt, "b": picture},  # c not classified yet
    )
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/utility").json()
    assert [p["uuid"] for p in data["photos"]] == ["a"]
    assert data["photos"][0]["verdict"] == receipt


def test_cleanup_clusters_groups_bursts_with_best(monkeypatch):
    t0 = datetime(2024, 1, 1, tzinfo=UTC)
    secs = {"a": 0, "b": 10, "c": 20, "far": 500, "d": 1000, "e": 1010, "f": 1020, "g": 1030}
    photos = [FakePhoto(u) for u in secs]
    for p in photos:
        p.date = t0 + timedelta(seconds=secs[p.uuid])
    photos.append(FakePhoto("filed", albums=["Bursts - Keep"]))
    photos[-1].date = t0 + timedelta(seconds=1040)
    _patch_engine(monkeypatch, photos)
    scores = {"a": 0.1, "b": 0.9, "c": 0.5, "d": 0.2, "e": 0.3, "f": 0.8, "g": None}
    monkeypatch.setattr(server.common, "get_photo_score", lambda p: scores.get(p.uuid))
    monkeypatch.setattr(server, "_feature_prints", lambda ps: {p.uuid: [0.0] for p in ps})
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/clusters").json()
    assert [(g["best"], [p["uuid"] for p in g["photos"]]) for g in data["groups"]] == [
        ("f", ["d", "e", "f", "g"]),  # newest first; unscored g never wins
        ("b", ["a", "b", "c"]),
    ]
    assert data["count"] == 7


def test_cleanup_clusters_splits_bursts_that_look_different(monkeypatch):
    # One 40s burst: two repeats of one shot, then two repeats of another (e.g. labels).
    t0 = datetime(2024, 1, 1, tzinfo=UTC)
    photos = [FakePhoto(u) for u in "abcdefg"]
    for i, p in enumerate(photos):
        p.date = t0 + timedelta(seconds=10 * i)
    _patch_engine(monkeypatch, photos)
    monkeypatch.setattr(server.common, "get_photo_score", lambda p: 0.5)
    # e: a one-off; f, g: utility images (document pages look alike), never grouped.
    prints = {"a": [0.0], "b": [0.1], "c": [2.0], "d": [2.1], "e": [5.0], "f": None, "g": None}
    monkeypatch.setattr(server, "_feature_prints", lambda ps: prints)
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/clusters").json()
    assert [[p["uuid"] for p in g["photos"]] for g in data["groups"]] == [["c", "d"], ["a", "b"]]


def test_cleanup_clusters_shows_none_without_feature_prints(monkeypatch):
    t0 = datetime(2024, 1, 1, tzinfo=UTC)
    photos = [FakePhoto(u) for u in "abc"]
    for i, p in enumerate(photos):
        p.date = t0 + timedelta(seconds=i)
    _patch_engine(monkeypatch, photos)

    def fail(ps):
        raise OSError("swiftc not found")

    monkeypatch.setattr(server, "_feature_prints", fail)
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/clusters").json()
    assert data["groups"] == [] and "swiftc" in data["classify"]["error"]


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


def test_cleanup_skips_already_filed(monkeypatch):
    _patch_engine(
        monkeypatch,
        [
            FakePhoto("a"),
            FakePhoto("b", albums=["Screenshots - Delete Me"]),
            FakePhoto("c", albums=["Screenshots - Keep"]),
            FakePhoto("d", albums=["Low Quality - Review Me"]),  # other pass's album
            FakePhoto("e"),
        ],
    )
    server._committed.add("e")
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/screenshots").json()
    assert sorted(p["uuid"] for p in data["photos"]) == ["a", "d"]


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
    assert server._parse_verdict("u2\tpicture\t1\tNot a utility image")[1]["keep"] is True
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


def test_commit_logs_decisions_and_verdict_stats(monkeypatch, tmp_path):
    items = [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    verdicts = {
        "a": {"keep": False, "kind": "receipt", "reason": ""},  # user deletes: agree
        "b": {"keep": False, "kind": "ticket", "reason": ""},  # user keeps: override
    }  # c has no verdict: not logged
    _patch_engine(monkeypatch, items, verdicts)
    monkeypatch.setattr(server, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(server.common, "add_to_album", lambda *a, **k: None)
    client = TestClient(server.app, base_url="http://127.0.0.1")
    assert client.get("/verdict-stats").json() == {}
    client.post("/commit", json={"kind": "screenshots", "uuids": ["a", "c"], "keep": ["b"]})
    client.post("/commit", json={"kind": "low-quality", "uuids": ["a"]})  # not a verdict pass
    rows = [json.loads(line) for line in (tmp_path / "decisions.jsonl").read_text().splitlines()]
    assert [(r["uuid"], r["verdict_keep"], r["decision"]) for r in rows] == [
        ("a", False, "delete"),
        ("b", False, "keep"),
    ]
    assert client.get("/verdict-stats").json() == {"screenshots": {"agree": 1, "total": 2}}


def _main(monkeypatch, *argv):
    monkeypatch.setattr(cli.sys, "argv", ["photos-cleanup", *argv])
    return cli.main()


def test_main_refuses_non_macos(monkeypatch, capsys):
    monkeypatch.setattr(cli.sys, "platform", "linux")
    with pytest.raises(SystemExit) as e:
        _main(monkeypatch)
    assert e.value.code == 1
    assert "macOS only" in capsys.readouterr().err


def test_main_refuses_missing_ui(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli.sys, "platform", "darwin")
    monkeypatch.setattr(cli, "UI_DIR", tmp_path / "ui")
    with pytest.raises(SystemExit) as e:
        _main(monkeypatch)
    assert e.value.code == 1
    assert "pnpm build" in capsys.readouterr().err


def test_check_port_free_returns():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    cli._check_port(port, f"http://127.0.0.1:{port}/", open_browser=False)


def test_check_port_foreign_program_exits_1(capsys):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        s.listen()
        port = s.getsockname()[1]
        with pytest.raises(SystemExit) as e:
            cli._check_port(port, f"http://127.0.0.1:{port}/", open_browser=False)
    assert e.value.code == 1
    assert "in use by another program" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("mac", "swiftc_rc", "expect"),
    [("26.4", 0, "macOS 27"), ("27.0.1", 1, "xcode-select --install"), ("27.0.1", 0, None)],
)
def test_verdicts_unavailable(monkeypatch, mac, swiftc_rc, expect):
    monkeypatch.setattr(cli.platform, "mac_ver", lambda: (mac, ("", "", ""), "arm64"))
    monkeypatch.setattr(cli.shutil, "which", lambda name: "/usr/bin/xcrun")
    monkeypatch.setattr(
        cli.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(a, swiftc_rc)
    )
    why = cli._verdicts_unavailable()
    assert why is None if expect is None else expect in why


def test_verdicts_off_reported_without_spawning(monkeypatch):
    monkeypatch.setattr(server, "_verdicts_off", "needs macOS 27")
    monkeypatch.setattr(server, "_classify", {"pending": 0, "total": 0, "error": None})
    server._start_classifier([FakePhoto("a")])
    assert server._classify == {"pending": 0, "total": 0, "error": "needs macOS 27"}


def test_second_pass_queues_behind_a_running_classifier(monkeypatch):
    import threading

    monkeypatch.setattr(server, "_verdicts", lambda: {})
    monkeypatch.setattr(server, "_classify", {"pending": 0, "total": 0, "error": None})
    monkeypatch.setattr(server, "_queue", [])
    monkeypatch.setattr(server, "_inflight", set())
    monkeypatch.setattr(server, "_classifier", None)
    first_running, release = threading.Event(), threading.Event()
    judged: list[list[str]] = []

    def fake_run(photos):
        judged.append([p.uuid for p in photos])
        first_running.set()
        release.wait(5)
        with server._classify_lock:
            server._inflight.difference_update(p.uuid for p in photos)

    monkeypatch.setattr(server, "_run_classifier", fake_run)
    shots = [FakePhoto("s1", deriv=["x"]), FakePhoto("s2", deriv=["x"])]
    server._start_classifier(shots)  # Screenshots tab
    assert first_running.wait(5)
    server._start_classifier([FakePhoto("u1", deriv=["x"])])  # Utility tab, mid-run
    server._start_classifier(shots)  # Screenshots reopened: already in flight, not re-queued
    assert server._classify["pending"] == 3
    assert server._classify["total"] == 3  # Utility's photo joined the running run's total
    release.set()
    for _ in range(50):
        if server._classifier is None:
            break
        threading.Event().wait(0.1)
    assert judged == [["s1", "s2"], ["u1"]]
    assert server._classifier is None
    server._start_classifier([FakePhoto("u2", deriv=["x"])])  # a new run starts from idle
    assert server._classify["total"] == 1


def test_counts_only_where_known(monkeypatch):
    t0 = datetime(2024, 1, 1, tzinfo=UTC)
    photos = [FakePhoto(u, deriv=["x"]) for u in "abc"]
    for i, p in enumerate(photos):
        p.date = t0 + timedelta(seconds=i)
    _patch_engine(monkeypatch, photos)
    monkeypatch.setattr(server, "_index", lambda: (photos, {p.uuid: p for p in photos}))
    monkeypatch.setattr(server.common, "get_photo_score", lambda p: 0.0)
    monkeypatch.setattr(server, "_prints", {})
    client = TestClient(server.app, base_url="http://127.0.0.1")
    data = client.get("/counts").json()
    assert data == {
        "all": 3,
        "screenshots": 3,
        "low-quality": 3,
        "utility": None,  # not every photo judged yet
        "clusters": None,  # feature prints not computed yet
    }
    pic = {"keep": True, "kind": "picture", "reason": ""}
    doc = {"keep": False, "kind": "receipt", "reason": ""}
    monkeypatch.setattr(server, "_verdicts", lambda: {"a": doc, "b": pic, "c": pic})
    monkeypatch.setattr(server, "_prints", {"a": [0.0], "b": [0.1], "c": [9.0]})
    data = client.get("/counts").json()
    assert data["utility"] == 1 and data["clusters"] == 2
