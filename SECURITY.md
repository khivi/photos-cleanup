# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately.
Open the repository's Security tab and choose "Report a vulnerability".
Do not open a public issue for a vulnerability.

## Supported versions

Only the latest release gets fixes.
Upgrade with `brew upgrade --cask photos-cleanup`.

## Security model

- The app deletes only photos in Delete Me albums. It deletes only when you click Delete in Photos…, after macOS asks you to confirm. Photos keeps them in Recently Deleted for 30 days. Otherwise the app only adds photos to albums.
- The app reads the library with its own Photos access, granted in the macOS prompt. It needs no Full Disk Access.
- The release is signed with Developer ID, uses the hardened runtime and is notarized. Its one entitlement is Photos library access.
- The app makes no network calls and opens no network port. When you preview a photo that is stored only in iCloud, Photos downloads it.
