#!/usr/bin/env bash
# Freeze the Python sidecar into a standalone binary for Tauri's externalBin.
# osxphotos and its deps ship data files (utitools/osxmetadata) and use dynamic
# imports (bitstring, uvicorn loops/protocols) — hence the collect flags.
set -euo pipefail
cd "$(dirname "$0")/.."

TRIPLE="$(rustc -Vv | sed -n 's/host: //p')"
OUT="src-tauri/binaries/photo-cleanup-sidecar-${TRIPLE}"

uv run pyinstaller --onefile --noconfirm --name photo-cleanup-sidecar \
  --distpath /tmp/pyi-dist --workpath /tmp/pyi-build --specpath /tmp/pyi-spec \
  --collect-all osxphotos \
  --collect-all photoscript \
  --collect-all utitools \
  --collect-all osxmetadata \
  --collect-submodules uvicorn \
  --collect-submodules bitstring \
  sidecar/server.py

mkdir -p src-tauri/binaries
cp /tmp/pyi-dist/photo-cleanup-sidecar "$OUT"
echo "sidecar -> $OUT"
