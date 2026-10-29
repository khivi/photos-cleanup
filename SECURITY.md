# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately.
Open the repository's Security tab and choose "Report a vulnerability".
Do not open a public issue for a vulnerability.

## Supported versions

Only the latest release gets fixes.
Upgrade with `brew upgrade --cask photos-cleanup`.

## Security model

- The app never deletes photos. It only adds photos to albums.
- The app reads the library with its own Photos access, granted in the macOS prompt. It needs no Full Disk Access.
- The release is signed with Developer ID, uses the hardened runtime and is notarized. Its one entitlement is Photos library access.
- The app makes no network calls and opens no network port.
