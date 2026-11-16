import PhotosCleanupCore
import SwiftUI

/// The Overview: what's left in each pass and Unsure, and Start Cleanup. Labels come from `ReviewModel`.
struct OverviewView: View {
    let model: ReviewModel

    var body: some View {
        Form {
            Section {
                Text(model.overviewHeadline).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("overview-headline")
                ForEach(model.overviewNotes, id: \.self) { Text($0).foregroundStyle(.secondary) }
                if let next = model.nextToReview {
                    Button(ReviewModel.startLabel) { Task { await model.select(next) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("start-cleanup")
                }
            }
            Section {
                ForEach(model.overviewRows) { row in
                    Button {
                        Task { await model.select(row.view) }
                    } label: {
                        LabeledContent {
                            if let n = row.count {
                                Text(n.formatted())
                                if let s = row.sections { Text(s) }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        } label: {
                            Text(row.title)
                            if let c = row.caption { Text(c) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("overview-\(row.view.sidebarID)")
                }
            }
        }
        .formStyle(.grouped)
    }
}
