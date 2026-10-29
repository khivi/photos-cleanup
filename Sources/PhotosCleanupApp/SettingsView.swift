import PhotosCleanupCore
import SwiftUI

/// UserDefaults key of the "Keep photos in albums" toggle; ContentView reads it at launch.
let keepAlbumPhotosKey = "keepAlbumPhotos"

/// The Settings window (⌘,). Both settings are read when the library loads, so they apply the next time the app opens.
struct SettingsView: View {
    @AppStorage(keepAlbumPhotosKey) private var keepAlbumPhotos = true
    @State private var ignored = userIgnoreAlbums()
    @State private var selection: String?
    @State private var newName = ""
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Keep photos in albums", isOn: $keepAlbumPhotos)
                Text("On: a photo in one of your own albums is never suggested. Off: it can be. Favorites, videos and photos already filed by a pass are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignored albums") {
                Text("Photos in these albums are not protected by being in them (Apple’s smart albums and the Delete Me and Keep albums already are).")
                    .font(.caption).foregroundStyle(.secondary)
                List(ignored, id: \.self, selection: $selection) { Text($0) }
                    .frame(height: 120)
                    .overlay { if ignored.isEmpty { Text("None").foregroundStyle(.secondary) } }
                HStack {
                    TextField("Album name", text: $newName).onSubmit(add)
                    Button("Add", action: add).disabled(trimmed.isEmpty)
                    Button("Remove") {
                        ignored.removeAll { $0 == selection }
                        selection = nil
                        save()
                    }
                    .disabled(selection == nil)
                }
            }
            if let saveError {
                Text("Could not save the ignored albums: \(saveError)").font(.caption).foregroundStyle(.red)
            }
            Text("Changes apply the next time Photos Cleanup opens.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
