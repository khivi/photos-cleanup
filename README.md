# photos-cleanup

![Photos Cleanup icon](Sources/PhotosCleanupApp/AppIcon.svg)

Photos Cleanup is a Mac app. It helps you clear unwanted photos from your Photos library.
You review each cleanup pass as a thumbnail grid and mark photos keep or delete.
When you move them to albums, the app files the photos into albums in Photos.

## Safety

The app deletes only photos in Delete Me albums.
It deletes only when you click Delete in Photos…, and only after macOS asks you to confirm.
Photos keeps deleted photos in Recently Deleted for 30 days.
Photos you mark delete go into an album for that pass, such as "Screenshots - Delete Me".
Photos you mark keep go into a "Keep" album, such as "Screenshots - Keep". Later runs skip them.
You can also delete them yourself from that album in Photos.
The app skips favorites and photos that are already in your own albums.
Photos you edited in Photos start as keep in Bursts, Similar and Low Quality.

## Privacy

Everything runs on your Mac.
The app reads and files photos through PhotoKit, Apple's Photos API.
It finds bursts and low-quality photos with Apple's on-device Vision.
Verdicts for screenshots and paperwork come from Apple's on-device Foundation Models.
It caches analysis and verdicts in `~/Library/Caches/photos-cleanup`.
Delete that folder to clear them.
The app makes no network calls and sends no telemetry. When you preview a photo that is stored only in iCloud, Photos downloads it.

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
2. Pick a cleanup pass in the sidebar: Screenshots, Paperwork (receipts, tickets, documents), Bursts (repeated shots of one scene), Similar (the same scene on one day, minutes apart or more), Low Quality or Videos (longest first; clips under 2 seconds start as delete). Hover a pass to see what it finds.
3. Review the grid. Each photo starts with a suggestion; only photos to delete are marked.
4. Select photos and change the marks: K keeps, ⌫ deletes. Space shows the selected photo large. A video plays in the large view, and video cells show their length.
5. Click Move to Albums and confirm. Photos marked delete go into the pass's "Delete Me" album. Keepers go into its "Keep" album.
6. You can also mark photos delete in All. They start unmarked, and Move to Albums sends the marked ones to "All - Delete Me". All has no Keep album. Every pass skips photos in that album. All groups photos by month; the Done switch on a month header remembers you reviewed it, until the month gains photos.
7. Open To be deleted. It lists the photos in the Delete Me albums. Click Delete in Photos… and confirm in the macOS dialog. This deletes every photo in the list. If you cancel, nothing is deleted.

| Key | Action |
| --- | --- |
| Click, ⇧-click, ⌘-click, ⌘A | Select |
| Arrow keys | Move the selection |
| K / ⌫ | Mark the selection keep / delete; with one photo selected, move to the next |
| Space, Esc | Show or close the large preview |
| ⌘I | Show or hide the Info panel |
| ⌘Z / ⇧⌘Z | Undo / redo a mark |
| ⌥⌘D | Show only photos marked delete (in All, also those in a Delete Me album) |
| ⌥↓ / ⌥↑ | Next / previous month in All, or group in Bursts and Similar |

Photos keeps deleted items in Recently Deleted for 30 days.
Restore a photo from there if you change your mind.
Delete it from Recently Deleted to free space at once.

## Duplicates

The app does not look for duplicate copies of a photo. The Photos app does this better: it can merge copies.

1. In Photos, open Utilities > Duplicates in the sidebar. The album appears only after Photos finds duplicates.
2. Click Merge on a set, or select all and merge them at once.
3. Photos keeps the best copy and combines the keywords, captions, favorites and albums of the copies into it. The other copies go to Recently Deleted.

## Albums that protect photos

Passes skip favorites and photos in your own albums.
To change this, open Settings (⌘,):

- Turn off Keep photos in albums to review photos in your own albums too.
- Add albums under Ignored albums to make only those not count.

Changes apply the next time the app opens.

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
