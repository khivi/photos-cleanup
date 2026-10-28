"""`photos-cleanup` entry point: checks the environment, then starts the server.

Kept light so --version, --help and the "macOS only" check work anywhere, fast; the
server module loads only once checks pass.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

UI_DIR = Path(__file__).with_name("ui")
PHOTOS_SETTINGS = "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"


def _version() -> str:
    try:
        return version("macos-photos-cleanup")
    except PackageNotFoundError:
        return "dev"


def _die(msg: str) -> None:
    print(f"photos-cleanup: {msg}", file=sys.stderr)
    raise SystemExit(1)


def _check_port(port: int, url: str, open_browser: bool) -> None:
    """Exit if the port is taken; if it's taken by us, just reopen the UI."""
    with socket.socket() as s:
        if s.connect_ex(("127.0.0.1", port)) != 0:
            return
    try:
        with urllib.request.urlopen(f"{url}health", timeout=2) as r:
            ours = json.load(r) == {"ok": True}
    except (OSError, ValueError):
        ours = False
    if not ours:
        _die(f"port {port} is in use by another program. Pick another with --port.")
    print(f"Already running at {url}")
    if open_browser:
        webbrowser.open(url)
    raise SystemExit(0)


def _has_swiftc() -> bool:
    return bool(shutil.which("xcrun")) and (
        subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True).returncode == 0
    )


def _check_library() -> None:
    """Fail before serving if the Photos library can't be read: needs Swift and Photos access."""
    if not _has_swiftc():
        _die(
            "needs the Xcode Command Line Tools to read your Photos library.\n"
            "  Run: xcode-select --install"
        )
    from photos_cleanup import library

    try:
        print("Checking Photos access (macOS may ask once)…")
        status = library.photokit.call({"op": "auth"})["status"]
    except (library.PhotoKitError, subprocess.CalledProcessError, OSError) as e:
        _die(f"couldn't start the Photos helper: {e}")
    if status != "authorized":
        app_name = os.environ.get("TERM_PROGRAM", "your terminal app")
        if sys.stdin.isatty():
            subprocess.run(["open", PHOTOS_SETTINGS], check=False)
        _die(
            f"can't read your Photos library: Photos access is {status}.\n"
            f"  In System Settings > Privacy & Security > Photos, turn on {app_name}\n"
            '  with "Full Access", then run photos-cleanup again.'
        )


def _verdicts_unavailable() -> str | None:
    """Why screenshot verdicts can't run on this Mac, or None. Not fatal: the passes still work."""
    major = int(platform.mac_ver()[0].split(".")[0] or 0)
    if major < 27:
        return "screenshot verdicts need macOS 27 or later with Apple Intelligence on"
    return None


def main() -> None:
    ap = argparse.ArgumentParser(
        prog="photos-cleanup",
        description="Review and clear unwanted photos in your Photos library, in your browser.",
    )
    ap.add_argument("--port", type=int, default=8765, help="local port (default: 8765)")
    ap.add_argument("--no-browser", action="store_true", help="don't open the browser")
    ap.add_argument(
        "--dev", action="store_true", help="API only, for `pnpm dev` (implies --no-browser)"
    )
    ap.add_argument("--version", action="version", version=f"%(prog)s {_version()}")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # progress lines reach logs and pipes promptly
    open_browser = not (args.no_browser or args.dev)
    url = f"http://127.0.0.1:{args.port}/"

    if sys.platform != "darwin":
        _die("macOS only: it reads the Photos library.")
    if not args.dev and not (UI_DIR / "index.html").is_file():
        _die("the web UI is missing. In a source checkout, run `pnpm build` (or use --dev).")
    _check_port(args.port, url, open_browser)
    _check_library()

    from photos_cleanup import server

    server._verdicts_off = _verdicts_unavailable()
    if server._verdicts_off:
        print(f"Note: {server._verdicts_off}. Everything else works.")
    print("Reading your Photos library…")
    start = time.monotonic()
    try:
        n = len(server._index()[0])
    except Exception as e:
        _die(f"couldn't load the Photos library: {e}")
    print(f"{n:,} photos loaded in {time.monotonic() - start:.1f}s.")
    # Bursts, Low quality and Utility all need the Vision analysis; start it now.
    stills = [p for p in server._index()[0] if not p.ismovie and not p.screenshot]
    progress = server._start_vision(stills)
    if progress["pending"]:
        print(f"Analysing {progress['pending']:,} photos in the background; cached afterwards.")
    print(f"Open {url} — press Ctrl-C to stop.")

    import uvicorn

    if open_browser:
        threading.Timer(1.0, webbrowser.open, args=[url]).start()
    uvicorn.run(server.app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
