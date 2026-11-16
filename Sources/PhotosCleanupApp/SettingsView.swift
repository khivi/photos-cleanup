import PhotosCleanupCore
import SwiftUI

/// UserDefaults key of "Albums that keep photos safe": true for All my albums, false for Only these. Read at launch.
let keepAlbumPhotosKey = "keepAlbumPhotos"
/// UserDefaults key of Sections; ReviewScreen applies it as it changes.
let sectionsKey = "sections"

/// The Settings window (⌘,). Sections applies at once; the album settings are read when the library loads.
struct SettingsView: View {
    @AppStorage(keepAlbumPhotosKey) private var keepAlbumPhotos = true
    @AppStorage(sectionsKey) private var sections = Period.auto
    @State private var ignored = userIgnoreAlbums()
    @State private var safe = userIgnoreAlbums(file: safeAlbumsFile)
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
            albums
            if let saveError {
                Text("Could not save the album list: \(saveError)").font(.caption).foregroundStyle(.red)
            }
            Text("Album changes apply the next time Photos Cleanup opens.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: keepAlbumPhotos) { selection = nil }
    }

    /// One choice and one list: the albums that don't count, or the only albums that protect.
    private var albums: some View {
        Section("Albums that keep photos safe") {
            Picker("Albums that keep photos safe", selection: $keepAlbumPhotos) {
                Text("All my albums, except these").tag(true)
                Text("Only these albums").tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .accessibilityIdentifier("settings-keep-album-photos")
            Text(
                keepAlbumPhotos
                    ? "A photo in an album you made is never suggested, unless the album is listed here. Apple’s own albums, like Selfies and Recents, don’t count."
                    : "Only photos in these albums are never suggested. Photos in your other albums can be."
            )
            .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                if !keepAlbumPhotos {
                    Label(Passes.keepAlbum, systemImage: "lock").foregroundStyle(.secondary)
                        .help("Photos you kept are always safe.")
                        .selectionDisabled()
                }
                ForEach(list, id: \.self) { Text($0) }
            }
            .frame(height: 120)
            .overlay { if keepAlbumPhotos && list.isEmpty { Text("None").foregroundStyle(.secondary) } }
            HStack {
                TextField("Album name", text: $newName).onSubmit(add)
                    .accessibilityIdentifier("settings-album-name")
                Button("Add", action: add).disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("settings-album-add")
                Button("Remove") {
                    list.removeAll { $0 == selection }
                    selection = nil
                    save()
                }
                .disabled(selection == nil)
                .accessibilityIdentifier("settings-album-remove")
            }
            Text("Favorites and photos you’ve already reviewed are never suggested.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The list the choice shows; each keeps its own, so switching loses neither.
    private var list: [String] {
        get { keepAlbumPhotos ? ignored : safe }
        nonmutating set { if keepAlbumPhotos { ignored = newValue } else { safe = newValue } }
    }

    private var ungrouped: String {
        Passes.all.filter { !Passes.grouped.contains($0.key) }.map(\.title).formatted(.list(type: .and))
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    private func add() {
        guard !trimmed.isEmpty else { return }
        if !list.contains(trimmed) && (keepAlbumPhotos || trimmed != Passes.keepAlbum) { list.append(trimmed) }
        newName = ""
        save()
    }

    private func save() {
        do {
            try saveIgnoreAlbums(list, file: keepAlbumPhotos ? "albums_ignore" : safeAlbumsFile)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
