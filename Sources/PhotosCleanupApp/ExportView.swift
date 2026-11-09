import AppKit
import PhotosCleanupCore
import SwiftUI

/// The Export status card: destination, counts, progress, failures. Labels come from `ReviewModel`.
struct ExportView: View {
    let model: ReviewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Destination") {
                    HStack {
                        Text(model.exportDestinationLabel).textSelection(.enabled)
                        Spacer()
                        Button("Choose…", action: choose).disabled(model.export.running)
                            .accessibilityIdentifier("export-choose")
                    }
                }
                if let disk = model.exportDiskLabel { LabeledContent("Disk", value: disk) }
                if let last = model.exportLastLabel() { LabeledContent("Status", value: last) }
                LabeledContent("Photos", value: model.exportCountsLabel)
            }
            Section {
                if let p = model.exportProgressLabel {
                    ProgressView(value: model.exportFraction) { Text(p).lineLimit(1).truncationMode(.middle) }
                }
                HStack {
                    Spacer()
                    Button(model.exportButtonLabel) {
                        Task { model.export.running ? await model.stopExport() : await model.startExport() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.export.running && !model.canExport)
                    .accessibilityIdentifier("export-start")
                }
            } footer: {
                Text(
                    "Originals, edits and Live Photo videos go into folders by year and month. Downloads iCloud originals. Never deletes from the destination."
                )
                .foregroundStyle(.secondary)
            }
            if !model.exportFailures.isEmpty {
                Section("Failed: a rerun retries them") {
                    ForEach(model.exportFailures, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
    }

    private func choose() {
        guard let url = pickFolder(prompt: "Export Here") else { return }
        Task { await model.chooseExportDestination(url) }
    }
}
