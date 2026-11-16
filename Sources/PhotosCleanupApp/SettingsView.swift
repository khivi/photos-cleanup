import PhotosCleanupCore
import SwiftUI

/// UserDefaults key of the "Keep photos in albums" toggle; ContentView reads it at launch.
let keepAlbumPhotosKey = "keepAlbumPhotos"
/// UserDefaults key of Sections; ReviewScreen applies it as it changes.
let sectionsKey = "sections"

/// The Settings window (⌘,). Sections applies at once; the album settings are read when the library loads.
struct SettingsView: View {
    @AppStorage(keepAlbumPhotosKey) private var keepAlbumPhotos = true
    @AppStorage(sectionsKey) private var sections = Period.auto
    @State private var ignored = userIgnoreAlbums()
    @State private var selection: String?
    @State private var newName = ""
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Picker("Sections", selection: $sections) {
                    ForEach(Period.allCases, id: \.self) { Text($0.title) }
                }
                .accessibilityIdentifier("settings-sections")
                Text(
                    "How \(ungrouped) split into sections to accept. Auto picks month, quarter or year per pass, so a pass has at most \(Period.maxSections) sections."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep photos in albums", isOn: $keepAlbumPhotos)
                    .accessibilityIdentifier("settings-keep-album-photos")
                Text(
                    "On: a photo in one of your own albums is never suggested. Off: it can be. Favorites, videos and photos already filed by a pass are always skipped."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored albums") {
                Text(
                    "Photos in these albums are not protected by being in them (Apple’s smart albums, the Delete Me albums and “\(Passes.keepAlbum)” already are)."
                )
                .font(.caption).foregroundStyle(.secondary)
                List(ignored, id: \.self, selection: $selection) { Text($0) }
                    .frame(height: 120)
                    .overlay { if ignored.isEmpty { Text("None").foregroundStyle(.secondary) } }
                HStack {
                    TextField("Album name", text: $newName).onSubmit(add)
                        .accessibilityIdentifier("settings-album-name")
                    Button("Add", action: add).disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("settings-album-add")
                    Button("Remove") {
                        ignored.removeAll { $0 == selection }
                        selection = nil
                        save()
                    }
                    .disabled(selection == nil)
                    .accessibilityIdentifier("settings-album-remove")
                }
            }
            if let saveError {
                Text("Could not save the ignored albums: \(saveError)").font(.caption).foregroundStyle(.red)
            }
            Text("Album changes apply the next time Photos Cleanup opens.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ungrouped: String {
        Passes.all.filter { !Passes.grouped.contains($0.key) }.map(\.title).formatted(.list(type: .and))
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    private func add() {
        guard !trimmed.isEmpty else { return }
        if !ignored.contains(trimmed) { ignored.append(trimmed) }
        newName = ""
        save()
    }

    private func save() {
        do {
            try saveIgnoreAlbums(ignored)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
