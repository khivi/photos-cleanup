# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately.
Open the repository's Security tab and choose "Report a vulnerability".
Do not open a public issue for a vulnerability.

## Supported versions

Only the latest release gets fixes.
Upgrade with `brew upgrade photos-cleanup` or `uv tool upgrade macos-photos-cleanup`.

## Security model

- The server binds to 127.0.0.1 only. Other machines cannot reach it.
- A Host-header allowlist (`127.0.0.1`, `localhost`) blocks DNS rebinding.
- The server sets no CORS headers. Other websites cannot read or call the API from your browser.
- The app never deletes photos. It only adds photos to albums.
- The app reads the library with Photos access granted to your terminal.
  Anything that runs in that terminal can read the library too. This is the macOS permission model.
  It needs no Full Disk Access.
- The app makes no network calls.
