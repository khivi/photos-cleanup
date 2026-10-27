# photos-cleanup

photos-cleanup is a local web app for macOS. It helps you clear unwanted photos from your Photos library.
The `photos-cleanup` command starts a server on your Mac and opens the UI in your browser.
You review each cleanup pass as a thumbnail grid and mark every photo keep or delete.
When you commit, the app files the photos into albums in Photos.

## Safety

The app never deletes a photo.
Photos you mark delete go into an album for that pass, such as "Screenshots - Delete Me". Low-quality photos go to "Low Quality - Review Me".
Photos you mark keep go into a "Keep" album, such as "Screenshots - Keep". Later runs skip them.
You delete the photos yourself from that album in Photos.
The app skips favorites and photos that are already in your own albums.

## Privacy

Everything runs on your Mac.
The app reads your library with [osxphotos](https://github.com/RhetTbull/osxphotos).
Verdicts for screenshots and utility photos come from Apple's on-device Vision and Foundation Models.
A small Swift helper, `photos_cleanup/verdict.swift`, runs them.
The app compiles the helper with `swiftc` on first use.
It caches the helper and the verdicts in `~/Library/Caches/photos-cleanup`.
The app makes no network calls and sends no telemetry.

## Requirements

- macOS
- Python 3.11 or later, for the `uv` and `pipx` installs
- Full Disk Access for your terminal app, so the app can read the library
- Optional, for AI verdicts: macOS 27 or later with Apple Intelligence on, and the Xcode Command Line Tools

Without the optional items, all passes still work.
Screenshots then start as "keep", and the UI says why.

## Install

Use one of these commands.

```bash
brew install khivi/photos-cleanup/photos-cleanup
uv tool install macos-photos-cleanup
pipx install macos-photos-cleanup
```

Warning: the PyPI package is named `macos-photos-cleanup`.
Do not install `photo-cleanup` from PyPI.
It is an unrelated tool that deletes files.

The command is `photos-cleanup`.

To upgrade, run `brew upgrade photos-cleanup` or `uv tool upgrade macos-photos-cleanup`.

## Permissions

The app needs two macOS permissions.

### Full Disk Access

The app needs this to read the Photos library. Grant it to the terminal app that runs `photos-cleanup`.

1. Open System Settings > Privacy & Security > Full Disk Access.
2. Turn on your terminal app.
3. Quit the terminal app and open it again.
4. Run `photos-cleanup` again.

If access is off, the app opens this settings pane and names the terminal app.

### Photos automation

The app writes albums through Photos with AppleScript.
On your first commit, macOS asks if your terminal may control Photos.
Click OK.
To change this later, open System Settings > Privacy & Security > Automation.

## Usage

1. Run `photos-cleanup`. Your browser opens at `http://127.0.0.1:8765/`.
2. Pick a cleanup pass. The passes are screenshots, utility photos (receipts, tickets), and low quality.
3. Review the thumbnail grid. Mark each photo keep or delete.
4. Commit. Photos marked delete go into the pass's "Delete Me" album ("Review Me" for low quality). Keepers go into its "Keep" album.
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
| `macOS only: it reads the Photos library.` | Run the app on a Mac. |
| `the web UI is missing.` | You run a source checkout. Run `pnpm build`, or use `--dev`. Installed packages include the UI. |
| `port N is in use by another program.` | Pick another port with `--port`. |
| `Already running at ...` | The app is already running. It reopens your browser and exits. |
| `no Photos library found.` | Open the Photos app once, then run the command again. |
| `can't read your Photos library: Full Disk Access is off.` | Follow the steps in Permissions. |
| `can't read the Photos library at ...` | Check the path in the message. Make sure the library is not damaged. |
| `couldn't load the Photos library: ...` | The library may be damaged or too new for osxphotos. Run `brew upgrade photos-cleanup` or `uv tool upgrade macos-photos-cleanup`. |

### AI verdicts unavailable

The app prints a note when it cannot run AI verdicts.
The note gives the reason. Everything else still works.

- "need macOS 27 or later with Apple Intelligence on": update macOS and turn on Apple Intelligence.
- "need the Xcode Command Line Tools": run `xcode-select --install`.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
