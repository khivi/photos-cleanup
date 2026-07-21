"""Sidecar tests. The engine's PhotosDB is mocked so these run without a real
Photos library (no TCC / Full Disk Access needed in CI)."""

from fastapi.testclient import TestClient

from sidecar import server


class FakePhoto:
    def __init__(self, size):
        self.original_filesize = size


class FakeDB:
    def photos(self):
        # 1 GiB + unscored(None) + 2 GiB -> count 3, size 3.0 GB
        return [FakePhoto(1024**3), FakePhoto(None), FakePhoto(2 * 1024**3)]


def test_health():
    assert TestClient(server.app).get("/health").json() == {"ok": True}


def test_stats(monkeypatch):
    monkeypatch.setattr(server, "db", lambda: FakeDB())
    data = TestClient(server.app).get("/stats").json()
    assert data["count"] == 3
    assert data["size_gb"] == 3.0
