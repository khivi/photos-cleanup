# photos-cleanup

Photos Cleanup is a Mac app. It helps you clear unwanted photos from your Photos library.
You review each cleanup pass as a thumbnail grid and mark every photo keep or delete.
When you commit, the app files the photos into albums in Photos.

## Safety

The app never deletes a photo.
Photos you mark delete go into an album for that pass, such as "Screenshots - Delete Me".
Photos you mark keep go into a "Keep" album, such as "Screenshots - Keep". Later runs skip them.
You delete the photos yourself from that album in Photos.
The app skips favorites and photos that are already in your own albums.

## Privacy

Everything runs on your Mac.
The app reads and files photos through PhotoKit, Apple's Photos API.
It finds bursts and low-quality photos with Apple's on-device Vision.
Verdicts for screenshots and paperwork come from Apple's on-device Foundation Models.
It caches thumbnails, analysis and verdicts in `~/Library/Caches/photos-cleanup`.
Delete that folder to clear them.
The app makes no network calls and sends no telemetry.

## Requirements

- macOS 15 or later
- Optional, for AI verdicts: macOS 27 or later with Apple Intelligence on

Without AI verdicts, all passes still work.
Screenshots and Paperwork then start as "keep", and the app says why.

## Install

Install with Homebrew.

```bash
brew install --cask khivi/photos-cleanup/photos-cleanup
```

This installs "Photos Cleanup" in Applications.
To upgrade, run `brew upgrade --cask photos-cleanup`.

Versions up to 0.3.1 were a `photos-cleanup` command that opened a browser UI.
To move from it, run `brew uninstall photos-cleanup`, then install the cask.

To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Permissions

The app needs one macOS permission: Photos access, with Full Access.

1. Open Photos Cleanup. The first time, macOS asks if it may access your Photos.
2. Click Allow Full Access.

To change this later, open System Settings > Privacy & Security > Photos.
If access is off, the app shows an Open Privacy Settings button.

## Usage

1. Open Photos Cleanup. It reads your library and shows every photo.
2. Pick a cleanup pass: Screenshots, Paperwork (receipts, tickets, documents), Bursts (repeated shots of one scene) or Low Quality. Hover a tab to see what it finds.
3. Review the thumbnail grid. Click a photo to switch it between keep and delete.
4. Commit. Photos marked delete go into the pass's "Delete Me" album. Keepers go into its "Keep" album.
5. Open that album in Photos. Check it, then delete the photos there. The To be deleted tab names the albums.

Photos keeps deleted items in Recently Deleted for 30 days.
Restore a photo from there if you change your mind.
Delete it from Recently Deleted to free space at once.

## Albums that protect photos

Passes skip favorites and photos in your own albums.
To make some of your albums not count, list them one per line in `~/Library/Application Support/photos-cleanup/albums_ignore`.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `Photos access is denied.` | Follow the steps in Permissions. |
| `Couldn't load the Photos library: ...` | Open the Photos app once to check the library, then reopen Photos Cleanup. |

### AI verdicts unavailable

The app shows a note when it cannot run AI verdicts.
The note gives the reason. Everything else still works.

- "need macOS 27 or later with Apple Intelligence on": update macOS and turn on Apple Intelligence.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
