# Privacy policy

Photos Cleanup is a macOS app. It reviews your Photos library and files unwanted photos into "Delete Me" albums.

Effective date: 2026-11-10

## What the app accesses

- The app reads your Photos library through Apple's PhotoKit. You grant this access when macOS asks.
- It reads photos, their dates and their album names.
- Apple's Vision framework and Apple's on-device Foundation Models analyze the photos. Both run on your Mac.
- It reads and writes only the folders you pick for Export and Import.

## What the app stores, and where

- The app stores its settings, your review decisions and analysis caches on your Mac, in its own sandbox container.
- The app keeps bookmarks to the folders you picked, so it can open them again.
- It stores no photo content outside your Photos library, except files you export to a folder you chose.
- You can delete this data by deleting the app's container.

## What leaves your Mac

Nothing. The app has no network code. It has no analytics, no crash reporting and no accounts. It does not track you. It collects no data. The app's privacy manifest declares the same.

Photos itself may download a photo from iCloud when the app asks for a preview or an export. Apple's Photos does this, not the app.

## Changes to your library

- The app adds photos to review albums, such as "Bursts - Delete Me" and "Bursts - Keep".
- The app deletes only photos you flagged, only when you click Delete in Photos…, and only after macOS asks you to confirm.
- Photos keeps deleted photos in Recently Deleted for 30 days. You can restore them there.

## Contact

Open an issue: <https://github.com/khivi/photos-cleanup/issues>
