import AppKit
import PhotosCleanupCore
import SwiftUI

/// The Import screen: checked folders on the left, the selected folder's counts and actions on the
/// right. Labels come from `ReviewModel`.
struct ImportView: View {
    let model: ReviewModel
    @State private var confirmingSort = false

    var body: some View {
        @Bindable var model = model
        // Not HSplitView: an AppKit split view inside the window's NavigationSplitView loops on layout and crashes.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.importFolder) {
                    ForEach(model.importFolders) { f in
                        VStack(alignment: .leading) {
                            Text(f.url.lastPathComponent)
                            Text(model.importFolderCounts(f.url)).font(.caption).foregroundStyle(.secondary)
                        }
                        .help(model.importFolderLabel(f.url))
                        .tag(f.url)
                    }
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus") {
                        if let url = pickFolder(prompt: "Add") { Task { await model.addImportFolder(url) } }
                    }
                    Button("Remove", systemImage: "minus") {
                        if let url = model.importFolder { model.removeImportFolder(url) }
                    }
                    .disabled(model.importFolder == nil || model.importBusy != nil)
                    Spacer()
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).padding(6)
            }
            .frame(width: 240)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Both bounds given: the column's min size stops tracking the content, which otherwise feeds
        // NavigationSplitView a new min width per update and trips AppKit's constraint-pass limit.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .confirmationDialog("Sort into Done and Import?", isPresented: $confirmingSort) {
            Button("Sort") { Task { await model.sortImportFolder() } }
        } message: {
            Text(model.importSortPreview + "\n\nFiles move within the folder. Nothing is deleted.")
        }
    }

    @ViewBuilder private var detail: some View {
        if let url = model.importFolder {
            Form {
                Section {
                    LabeledContent("Folder") { Text(model.importFolderLabel(url)).textSelection(.enabled) }
                    LabeledContent("Library exports") {
                        VStack(alignment: .trailing) {
                            ForEach(model.importFolderSkip, id: \.self) { sub in
                                HStack {
                                    Text(sub)
                                    Button("Remove", systemImage: "xmark.circle") {
                                        Task { await model.setLibraryExport(sub, in: url, false) }
                                    }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                }
                            }
                            Button("Add…") { addLibraryExport(in: url) }.disabled(model.importBusy != nil)
                        }
                    }
                    .help("An export of your Photos library: never moved, and its photos never count as new.")
                }
                Section {
                    ForEach(model.importStatusCounts, id: \.status) { LabeledContent($0.status, value: "\($0.count)") }
                    if let p = model.importProgressLabel {
                        ProgressView(value: fraction) { Text(p).lineLimit(1).truncationMode(.middle) }
                    }
                } header: {
                    Text(model.importScan == nil ? "Not checked yet" : "Files")
                }
                Section {
                    HStack {
                        Button("Check Again") { Task { await model.checkImportFolder(url) } }
                            .disabled(!model.canCheckImport)
                        Spacer()
                        Button("Sort into Done and Import…") { confirmingSort = true }
                            .disabled(!model.canSortImport)
                            .keyboardShortcut(.defaultAction)
                    }
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Spacer()
                        Button("Open Import in Photos") { openInPhotos(model.importInbox!) }
                            .disabled(model.importInbox == nil)
                            .help("Photos shows its import window for the Import folder.")
                    }
                } footer: {
                    Text(
                        "Done: already in your library, or a copy of a file that is. Import: to bring into Photos; “Check date” holds files without a camera date, which Photos would date by when the file was copied. After importing, check again: imported files move to Done."
                    )
                    .foregroundStyle(.secondary)
                }
                if !model.importFailures.isEmpty {
                    Section("Not moved") {
                        ForEach(model.importFailures, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("No folders", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a folder of old photos to see which ones aren’t in your library yet.")
            } actions: {
                Button("Add Folder…") {
                    if let url = pickFolder(prompt: "Add") { Task { await model.addImportFolder(url) } }
                }
            }
        }
    }

    private var fraction: Double {
        model.importProgress.total == 0 ? 0 : Double(model.importProgress.done) / Double(model.importProgress.total)
    }

    private func addLibraryExport(in root: URL) {
        guard let sub = pickFolder(prompt: "Mark as Library Export", in: root),
            sub.path.hasPrefix(root.path + "/")
        else { return }
        Task { await model.setLibraryExport(String(sub.path.dropFirst(root.path.count + 1)), in: root, true) }
    }
}

@MainActor func pickFolder(prompt: String, in dir: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.directoryURL = dir
    return panel.runModal() == .OK ? panel.url : nil
}

/// Opening a folder with Photos shows its import window for that folder.
@MainActor func openInPhotos(_ url: URL) {
    guard let photos = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else { return }
    NSWorkspace.shared.open([url], withApplicationAt: photos, configuration: NSWorkspace.OpenConfiguration())
}
