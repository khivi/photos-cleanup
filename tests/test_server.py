"""Server tests. The PhotoKit helper is mocked so these run without a real Photos
library (no Photos access or Swift toolchain needed in CI)."""

import json
import socket
from array import array
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from photos_cleanup import cli, library, server

IDLE = {"pending": 0, "total": 0, "error": None}


class FakePhoto:
    def __init__(self, uuid="x", albums=(), date=None):
        self.uuid = uuid
        self.albums = list(albums)
        self.width = 100
        self.height = 100
        self.date = date
        self.ismovie = False
        self.screenshot = False


def V(score=0.5, utility=False, vec=(0.0,)):
    """One photo's Vision analysis, as server._vision() holds it."""
    return {"print": array("f", vec), "utility": utility, "score": score}


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


def test_photos_returns_all(monkeypatch):
    items = [FakePhoto("a"), FakePhoto("b"), FakePhoto("c")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/photos").json()
    assert data["total"] == 3
    assert [p["uuid"] for p in data["photos"]] == ["a", "b", "c"]


def test_thumb_made_once_cached_and_404(monkeypatch, tmp_path):
    items = [FakePhoto("a")]
    monkeypatch.setattr(server, "_index", lambda: (items, {p.uuid: p for p in items}))
    monkeypatch.setattr(server, "THUMB_DIR", tmp_path)
    calls = []

    def call(req):
        calls.append(req)
        with open(req["path"], "wb") as f:
            f.write(b"\xff\xd8\xff")  # jpeg magic bytes
        return {"ok": True}

    monkeypatch.setattr(library.photokit, "call", call)
    client = TestClient(server.app, base_url="http://127.0.0.1")
    assert client.get("/thumb/a").status_code == 200
    assert client.get("/thumb/a").status_code == 200  # served from the cache
    assert [(c["op"], c["uuid"], c["size"]) for c in calls] == [("image", "a", 340)]
    # Unknown ids never reach the file path, so ../ tricks can't name another file.
    assert client.get("/thumb/missing").status_code == 404
    assert client.get("/thumb/..%2F..%2Fetc%2Fpasswd").status_code == 404


def _patch_engine(monkeypatch, candidates, verdicts=None, vision=None):
    monkeypatch.setattr(server, "_all_photos", lambda: candidates)
    monkeypatch.setattr(server.library, "load_ignore_albums", lambda: frozenset())
    monkeypatch.setattr(
        server.library, "get_candidate_photos", lambda photos, ignore, **kw: candidates
    )
    monkeypatch.setattr(server, "_verdicts", lambda: verdicts or {})
    monkeypatch.setattr(server, "_start_classifier", lambda photos: None)
    monkeypatch.setattr(server, "_committed", set())
    monkeypatch.setattr(server, "_vision", lambda: vision or {})
    monkeypatch.setattr(server, "_start_vision", lambda photos: dict(IDLE))


def test_cleanup_screenshots_attaches_verdicts(monkeypatch):
    verdict = {"keep": False, "kind": "receipt", "reason": "Paid coffee receipt"}
    _patch_engine(monkeypatch, [FakePhoto("a"), FakePhoto("b")], {"a": verdict})
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/screenshots").json()
    assert data["count"] == 2
    assert {p["uuid"]: p["verdict"] for p in data["photos"]} == {"a": verdict, "b": None}
    assert data["classify"] == IDLE


def test_cleanup_utility_shows_only_vision_utility_photos_the_model_kept_as_utility(monkeypatch):
    receipt = {"keep": False, "kind": "receipt", "reason": "Paid"}
    picture = {"keep": True, "kind": "picture", "reason": "Not a utility image"}
    _patch_engine(
        monkeypatch,
        [FakePhoto(u) for u in "abcde"],
        {"a": receipt, "b": picture},  # c not classified yet
        # d: Vision says not utility; e: not analysed yet
        {"a": V(utility=True), "b": V(utility=True), "c": V(utility=True), "d": V()},
    )
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/utility").json()
    assert [p["uuid"] for p in data["photos"]] == ["a"]
    assert data["photos"][0]["verdict"] == receipt


def test_cleanup_utility_shows_vision_progress_before_the_models(monkeypatch):
    _patch_engine(monkeypatch, [FakePhoto("a")])
    monkeypatch.setattr(server, "_start_vision", lambda photos: {**IDLE, "pending": 5, "total": 9})
    monkeypatch.setattr(server, "_classify", {"pending": 1, "total": 1, "error": None})
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/utility").json()
    assert data["classify"] == {"pending": 5, "total": 9, "error": None}


def _dated(uuids_secs: dict[str, int]) -> list[FakePhoto]:
    t0 = datetime(2024, 1, 1, tzinfo=UTC)
    return [FakePhoto(u, date=t0 + timedelta(seconds=s)) for u, s in uuids_secs.items()]


def test_cleanup_clusters_groups_bursts_with_best(monkeypatch):
    photos = _dated({"a": 0, "b": 10, "c": 20, "far": 500, "d": 1000, "e": 1010, "f": 1020})
    photos += [FakePhoto("filed", albums=["Bursts - Keep"], date=photos[-1].date)]
    scores = {"a": 0.1, "b": 0.9, "c": 0.5, "far": 0.5, "d": 0.2, "e": 0.3, "f": 0.8}
    _patch_engine(monkeypatch, photos, vision={u: V(s) for u, s in scores.items()})
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/clusters").json()
    assert [(g["best"], [p["uuid"] for p in g["photos"]]) for g in data["groups"]] == [
        ("f", ["d", "e", "f"]),  # newest first
        ("b", ["a", "b", "c"]),
    ]
    assert data["count"] == 6


def test_cleanup_clusters_splits_bursts_that_look_different(monkeypatch):
    # One 60s burst: two repeats of one shot, then two of another, a one-off (e), two
    # utility images (f, g: document pages look alike to prints) and one not analysed (h).
    photos = _dated({u: 10 * i for i, u in enumerate("abcdefgh")})
    vision = {
        "a": V(vec=(0.0,)),
        "b": V(vec=(0.1,)),
        "c": V(vec=(2.0,)),
        "d": V(vec=(2.1,)),
        "e": V(vec=(5.0,)),
        "f": V(utility=True, vec=(9.0,)),
        "g": V(utility=True, vec=(9.0,)),
    }
    _patch_engine(monkeypatch, photos, vision=vision)
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/clusters").json()
    assert [[p["uuid"] for p in g["photos"]] for g in data["groups"]] == [["c", "d"], ["a", "b"]]


def test_cleanup_low_quality_filters_by_vision_score(monkeypatch):
    vision = {"a": V(-0.9), "b": V(0.5), "edge": V(server.LOW_QUALITY_MAX)}  # c: not analysed
    _patch_engine(monkeypatch, [FakePhoto(u) for u in ("a", "b", "c", "edge")], vision=vision)
    client = TestClient(server.app, base_url="http://127.0.0.1")
    data = client.get("/cleanup/low-quality").json()
    assert [p["uuid"] for p in data["photos"]] == ["a", "edge"]
    assert data["photos"][0]["verdict"] is None
    assert [
        p["uuid"] for p in client.get("/cleanup/low-quality?threshold=0.6").json()["photos"]
    ] == [
        "a",
        "b",
        "edge",
    ]


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
        server,
        "_add_to_album",
        lambda photos, album: calls.append(([p.uuid for p in photos], album)),
    )
    client = TestClient(server.app, base_url="http://127.0.0.1")
    r = client.post("/commit", json={"kind": "screenshots", "uuids": ["a"], "keep": ["b"]})
    assert r.json() == {
        "added": 1,
        "album": "Screenshots - Delete Me",
        "kept": 1,
        "keep_album": "Screenshots - Keep",
    }
    assert calls == [(["a"], "Screenshots - Delete Me"), (["b"], "Screenshots - Keep")]
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
    monkeypatch.setattr(server, "_add_to_album", lambda *a: None)
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
    monkeypatch.setattr(server, "_add_to_album", lambda *a: None)
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


def test_check_library_needs_swift(monkeypatch, capsys):
    monkeypatch.setattr(cli, "_has_swiftc", lambda: False)
    with pytest.raises(SystemExit):
        cli._check_library()
    assert "xcode-select --install" in capsys.readouterr().err


@pytest.mark.parametrize("status", ["denied", "limited", "restricted"])
def test_check_library_needs_full_photos_access(monkeypatch, capsys, status):
    monkeypatch.setattr(cli, "_has_swiftc", lambda: True)
    monkeypatch.setattr(cli.sys.stdin, "isatty", lambda: False)
    monkeypatch.setattr(library.photokit, "call", lambda req: {"status": status})
    with pytest.raises(SystemExit):
        cli._check_library()
    err = capsys.readouterr().err
    assert status in err and "Privacy & Security > Photos" in err


def test_check_library_passes_when_authorized(monkeypatch):
    monkeypatch.setattr(cli, "_has_swiftc", lambda: True)
    monkeypatch.setattr(library.photokit, "call", lambda req: {"status": "authorized"})
    cli._check_library()


@pytest.mark.parametrize(("mac", "expect"), [("26.4", "macOS 27"), ("27.0.1", None)])
def test_verdicts_unavailable(monkeypatch, mac, expect):
    monkeypatch.setattr(cli.platform, "mac_ver", lambda: (mac, ("", "", ""), "arm64"))
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
    shots = [FakePhoto("s1"), FakePhoto("s2")]
    server._start_classifier(shots)  # Screenshots tab
    assert first_running.wait(5)
    server._start_classifier([FakePhoto("u1")])  # Utility tab, mid-run
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
    server._start_classifier([FakePhoto("u2")])  # a new run starts from idle
    assert server._classify["total"] == 1


def test_vision_job_analyses_caches_and_reports_progress(monkeypatch, tmp_path):
    import threading

    monkeypatch.setattr(server, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(server, "_vision_queue", [])
    monkeypatch.setattr(server, "_vision_state", dict(IDLE))
    monkeypatch.setattr(server, "_vision_thread", None)
    server._vision.cache_clear()
    release = threading.Event()
    seen: list[list[str]] = []
    b64 = "AAAAAA=="  # one Float32 zero

    def call(req):
        release.wait(5)
        seen.append(req["uuids"])
        return {
            "results": [
                {"uuid": "a", "print": b64, "ptype": 1, "utility": False, "score": -0.9},
                {"uuid": "b", "error": "no local image"},
            ]
        }

    monkeypatch.setattr(library.photokit, "call", call)
    try:
        progress = server._start_vision([FakePhoto("a"), FakePhoto("b")])
        assert progress == {"pending": 2, "total": 2, "error": None}
        assert server._start_vision([FakePhoto("a")])["pending"] == 2  # already queued
        release.set()
        for _ in range(50):
            if server._vision_thread is None:
                break
            threading.Event().wait(0.1)
        assert seen == [["a", "b"]]
        assert server._vision()["a"]["score"] == -0.9 and server._vision()["b"] is None
        server._vision.cache_clear()  # a restart reads the disk cache, nothing re-analysed
        assert set(server._vision()) == {"a", "b"}
        assert server._start_vision([FakePhoto("a"), FakePhoto("b")])["pending"] == 0
    finally:
        server._vision.cache_clear()


def test_counts_only_where_known(monkeypatch):
    photos = _dated({"a": 0, "b": 1, "c": 2})
    vision: dict = {}
    _patch_engine(monkeypatch, photos)
    monkeypatch.setattr(server, "_vision", lambda: vision)
    monkeypatch.setattr(server, "_index", lambda: (photos, {p.uuid: p for p in photos}))
    client = TestClient(server.app, base_url="http://127.0.0.1")
    assert client.get("/counts").json() == {
        "all": 3,
        "screenshots": 3,
        "low-quality": None,  # the Vision analysis hasn't run yet
        "utility": None,
        "clusters": None,
    }
    vision.update(a=V(-0.9, utility=True, vec=(0.0,)), b=V(0.5, vec=(0.1,)), c=V(0.5, vec=(0.2,)))
    assert client.get("/counts").json()["utility"] is None  # analysed, not yet judged
    pic = {"keep": True, "kind": "picture", "reason": ""}
    doc = {"keep": False, "kind": "receipt", "reason": ""}
    monkeypatch.setattr(server, "_verdicts", lambda: {"a": doc, "b": pic, "c": pic})
    data = client.get("/counts").json()
    assert data["utility"] == 1 and data["clusters"] == 2 and data["low-quality"] == 1


def test_utility_never_preselects_a_misread_screenshot_for_delete(monkeypatch):
    photos = [FakePhoto(u) for u in "ab"]
    shot = {"keep": False, "kind": "screenshot", "reason": "A hand with a ring"}
    receipt = {"keep": False, "kind": "receipt", "reason": "Coffee receipt"}
    vision = {"a": V(utility=True), "b": V(utility=True)}
    _patch_engine(monkeypatch, photos, {"a": shot, "b": receipt}, vision)
    client = TestClient(server.app, base_url="http://127.0.0.1")
    got = {p["uuid"]: p["verdict"]["keep"] for p in client.get("/cleanup/utility").json()["photos"]}
    assert got == {"a": True, "b": False}
    shots = client.get("/cleanup/screenshots").json()["photos"]  # the Screenshots pass is untouched
    assert {p["uuid"]: p["verdict"]["keep"] for p in shots} == {"a": False, "b": False}


def test_add_to_album_asks_the_photokit_helper(monkeypatch):
    seen = []
    monkeypatch.setattr(
        library.photokit, "call", lambda req: seen.append(req) or {"added": 2, "skipped": 0}
    )
    server._add_to_album([FakePhoto("a"), FakePhoto("b")], "X - Delete Me")
    assert seen == [{"op": "add", "album": "X - Delete Me", "uuids": ["a", "b"]}]


def test_add_to_album_reports_photos_access_off(monkeypatch):
    def denied(req):
        raise library.PhotoKitError("Photos access not granted")

    monkeypatch.setattr(library.photokit, "call", denied)
    with pytest.raises(server.HTTPException) as e:
        server._add_to_album([FakePhoto("a")], "X")
    assert e.value.status_code == 403 and "Privacy & Security > Photos" in e.value.detail


def test_load_photos_from_the_helper(monkeypatch):
    row = {"uuid": "u", "date": 1700000000.5, "w": 4, "h": 3, "shot": True, "live": False}
    row |= {"movie": False, "fav": True, "albums": ["Trip"]}
    undated = {**row, "uuid": "v", "date": None}
    monkeypatch.setattr(library.photokit, "call", lambda req: {"photos": [row, undated]})
    p, q = library.load_photos()
    assert (p.uuid, p.width, p.screenshot, p.favorite, p.albums) == ("u", 4, True, True, ["Trip"])
    assert p.date == datetime.fromtimestamp(1700000000.5, UTC) and q.date is None


def test_candidate_filter():
    class P:
        def __init__(
            self, uuid, screenshot=False, ismovie=False, favorite=False, albums=(), year=2024
        ):
            self.uuid, self.screenshot, self.ismovie, self.favorite = (
                uuid,
                screenshot,
                ismovie,
                favorite,
            )
            self.albums = list(albums)
            self.date = datetime(year, 1, 1) if year else None

    photos = [
        P("plain"),
        P("shot", screenshot=True),
        P("movie", ismovie=True),
        P("fav", favorite=True),
        P("mine", albums=["Trip to Goa"]),  # the user's own album protects it
        P("smart", albums=["Selfies"]),  # Apple's smart album doesn't
        P("filed", albums=["Screenshots - Delete Me"]),  # nor does a review album
        P("undated", year=None),
        P("old", year=1990),
    ]
    ignore = library.load_ignore_albums()
    uuids = lambda ps: [p.uuid for p in ps]  # noqa: E731
    assert uuids(library.get_candidate_photos(photos, ignore)) == [
        "plain",
        "smart",
        "filed",
        "undated",
        "old",
    ]
    assert uuids(library.get_candidate_photos(photos, ignore, only_screenshots=True)) == ["shot"]
    dated = library.get_candidate_photos(photos, ignore, require_valid_date=True)
    assert uuids(dated) == ["plain", "smart", "filed"]


def test_vision_batch_in_progress_is_not_queued_twice(monkeypatch, tmp_path):
    import threading

    monkeypatch.setattr(server, "CACHE_DIR", tmp_path)
    monkeypatch.setattr(server, "_vision_queue", [])
    monkeypatch.setattr(server, "_vision_state", dict(IDLE))
    monkeypatch.setattr(server, "_vision_thread", None)
    server._vision.cache_clear()
    started, release = threading.Event(), threading.Event()
    calls = []

    def call(req):
        calls.append(req["uuids"])
        started.set()
        release.wait(5)
        return {"results": [{"uuid": u, "error": "x"} for u in req["uuids"]]}

    monkeypatch.setattr(library.photokit, "call", call)
    try:
        server._start_vision([FakePhoto("a")])
        assert started.wait(5)
        # A poll while "a" is being analysed: not queued again, total unchanged.
        assert server._start_vision([FakePhoto("a")]) == {"pending": 1, "total": 1, "error": None}
        release.set()
        for _ in range(50):
            if server._vision_thread is None:
                break
            threading.Event().wait(0.1)
        assert calls == [["a"]]
    finally:
        server._vision.cache_clear()


def test_low_quality_files_into_delete_me_and_its_old_album_still_counts(monkeypatch):
    assert server.ALBUMS["low-quality"] == "Low Quality - Delete Me"
    old = FakePhoto("old", albums=["Low Quality - Review Me"])  # filed before the rename
    new = FakePhoto("new", albums=["Low Quality - Delete Me"])
    _patch_engine(
        monkeypatch, [old, new, FakePhoto("a")], vision={u: V(-0.9) for u in ("old", "new", "a")}
    )
    data = TestClient(server.app, base_url="http://127.0.0.1").get("/cleanup/low-quality").json()
    assert [p["uuid"] for p in data["photos"]] == ["a"]
