# photos-cleanup

photos-cleanup is a local web app for macOS. It helps you clear unwanted photos from your Photos library.
The `photos-cleanup` command starts a server on your Mac and opens the UI in your browser.
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
The server is one Swift program. It calls these Apple frameworks in-process.
It caches thumbnails, analysis and verdicts in `~/Library/Caches/photos-cleanup`.
Delete that folder to clear them.
The app makes no network calls and sends no telemetry.

## Requirements

- macOS
- The Xcode Command Line Tools, with Swift 6: run `xcode-select --install` (Homebrew already needs them)
- Node and pnpm, only to build the UI from source
- Photos access for your terminal app (see Permissions)
- Optional, for AI verdicts: macOS 27 or later with Apple Intelligence on

Without AI verdicts, all passes still work.
Screenshots then start as "keep", and the UI says why.

## Install

Install with Homebrew.

```bash
brew install khivi/photos-cleanup/photos-cleanup
```

The command is `photos-cleanup`.
To upgrade, run `brew upgrade photos-cleanup`.

To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Permissions

The app needs one macOS permission: Photos access, with Full Access.
macOS grants it to the terminal app that runs `photos-cleanup`.

1. Run `photos-cleanup`. The first time, macOS asks if your terminal may access your Photos.
2. Click Allow Full Access.

To change this later, open System Settings > Privacy & Security > Photos.
If access is off, the app opens this settings pane and names the terminal app.

## Usage

1. Run `photos-cleanup`. Your browser opens at `http://127.0.0.1:8765/`.
2. Pick a cleanup pass. The passes are screenshots, paperwork (receipts, tickets, documents), bursts (repeated shots of one scene), and low quality.
3. Review the thumbnail grid. Mark each photo keep or delete.
4. Commit. Photos marked delete go into the pass's "Delete Me" album. Keepers go into its "Keep" album.
5. Open that album in Photos. Check it, then delete the photos there.

Photos keeps deleted items in Recently Deleted for 30 days.
Restore a photo from there if you change your mind.
Delete it from Recently Deleted to free space at once.

Press Ctrl-C in the terminal to stop the server.

## Options

| Option | Effect |
| --- | --- |
| `--port N` | Listen on port N. The default is 8765. |
| `--no-browser` | Do not open the browser. |
| `--dev` | Start the API only, for `pnpm dev`. Implies `--no-browser`. |
| `--version` | Print the version and exit. |

## Troubleshooting

The app checks your setup at startup. It stops with a message if a check fails.

| Message | Fix |
| --- | --- |
| `the web UI is missing.` | You run a source checkout. Run `pnpm build`, or use `--dev`. Installed builds include the UI. |
| `port N is in use by another program.` | Pick another port with `--port`. |
| `Already running at ...` | The app is already running. It reopens your browser and exits. |
| `can't read your Photos library: Photos access is ...` | Follow the steps in Permissions. |
| `couldn't load the Photos library: ...` | Open the Photos app once to check the library, then run the command again. |

### AI verdicts unavailable

The app prints a note when it cannot run AI verdicts.
The note gives the reason. Everything else still works.

- "need macOS 27 or later with Apple Intelligence on": update macOS and turn on Apple Intelligence.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
