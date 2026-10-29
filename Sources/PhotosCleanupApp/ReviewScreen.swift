import PhotosCleanupCore
import SwiftUI

/// The review screen: tabs, toolbar and grid. Every label and decision comes from `ReviewModel`.
struct ReviewScreen: View {
    let model: ReviewModel
    let thumbnails: Thumbnails

    private var pollKey: String { "\(model.view.passKey ?? "")\(model.progress.pending > 0)" }
    private var countsKey: [Bool] { [model.loading, model.committing, model.progress.pending == 0] }

    private var items: [PassPhoto] {
        model.view == .deleted ? model.deleted.map { PassPhoto(photo: $0) } : model.photos
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner {
                Text(banner).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.blue.opacity(0.1))
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).padding(12)
            }
            content
        }
        .task(id: pollKey) {
            while model.inPass && model.progress.pending > 0 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await model.refresh()
            }
        }
        .task(id: countsKey) {
            if !model.loading && !model.committing { await model.refreshCounts() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(ReviewModel.tabs, id: \.view) { tab in
                    Button(model.tabLabel(tab.view, tab.title)) { Task { await model.select(tab.view) } }
                        .buttonStyle(.bordered)
                        .tint(model.view == tab.view ? .accentColor : nil)
                        .disabled(model.view == tab.view || model.loading)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                if model.inPass && !model.loading {
                    Group {
                        Text("Select all:").font(.caption).foregroundStyle(.secondary)
                        Button("✓ Keep") { model.setAll(.keep) }.tint(.green)
                        Button("✗ Delete") { model.setAll(.delete) }.tint(.red)
                    }
                    .disabled(model.photos.isEmpty)
                }
                if let off = model.verdictsOff {
                    Text("\(off). Everything else works.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.showsProgress {
                    ProgressView(value: Double(model.progressDone), total: Double(max(model.progressTotal, 1)))
                        .frame(width: 120)
                        .help("Analysing photos on this Mac; results appear as they arrive")
                    Text("\(model.progressDone.formatted())/\(model.progressTotal.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let e = model.progressError { Text(e).font(.caption).foregroundStyle(.red) }
                Text(model.loading ? "Loading…" : model.summary).fontWeight(.semibold)
                if model.inPass && !model.loading {
                    Button(model.commitLabel) { Task { await model.commit() } }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(model.committing || !model.canCommit)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if model.showsEmptyState {
            Text(ReviewModel.emptyState).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
            Spacer()
        } else if model.view == .pass("bursts") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 4) {
                                ForEach(group.photos) { cell(PassPhoto(photo: $0)).frame(width: cellSize, height: cellSize) }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize), spacing: 4)], spacing: 4) {
                    ForEach(items) { cell($0) }
                }
                .padding(.horizontal)
            }
        }
    }

    private func cell(_ p: PassPhoto) -> some View {
        let mark: PhotoCell.Mark = switch model.view {
        case .all: .none
        case .deleted: .deleteMe
        case .pass: model.decision(p.id).map { .decision($0) } ?? .none
        }
        return PhotoCell(photo: p, mark: mark, thumbnails: thumbnails,
                         onTap: model.inPass ? { model.toggle(p.id) } : nil)
    }
}
