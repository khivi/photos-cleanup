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
