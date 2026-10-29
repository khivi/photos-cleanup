import AppKit
import PhotosCleanupCore
import SwiftUI

/// The review screen: sidebar, toolbar and grid. Every label and decision comes from `ReviewModel`.
struct ReviewScreen: View {
    let model: ReviewModel
    let thumbnails: Thumbnails
    @State private var position = ScrollPosition(edge: .top)
    @State private var width: CGFloat = 800
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var windowUndo

    /// The adaptive grid fits as many columns as the width allows.
    private var columns: Int { max(1, Int((width - 2 * gridPadding + 4) / (cellSize + 4))) }
    private let gridPadding: CGFloat = 12

    private var pollKey: String { "\(model.view.passKey ?? "")\(model.progress.pending > 0)" }
    private var countsKey: [Bool] { [model.loading, model.committing, model.progress.pending == 0] }

    private var items: [PassPhoto] {
        model.view == .deleted ? model.deleted.map { PassPhoto(photo: $0) } : model.photos
    }

    private var selection: Binding<ReviewView?> {
        Binding(get: { model.view }, set: { v in if let v, v != model.view { Task { await model.select(v) } } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(model.sidebar) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Text(item.title).badge(item.badge ?? 0).help(item.help).tag(item.view)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
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
        }
        .onChange(of: windowUndo.map(ObjectIdentifier.init), initial: true) {  // Edit > Undo and ⌘Z reach the marks
            if let windowUndo { model.undoManager = windowUndo }
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
            ContentUnavailableView(ReviewModel.emptyState, systemImage: "checkmark.circle")
        } else if model.view == .pass("bursts") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { n, group in
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 4) {
                                    ForEach(group.photos) { cell(PassPhoto(photo: $0)).frame(width: cellSize, height: cellSize) }
                                }
                            }
                            .onChange(of: model.anchor, initial: true) { _, a in
                                if let a, group.photos.contains(where: { $0.id == a }) { proxy.scrollTo(a) }
                            }
                        }
                        .id(n)
                    }
                }
                .padding(.horizontal, gridPadding)
            }
            .scrollPosition($position)
            .keyboardSelection(model: model, focused: $focused, width: $width) { move($0) }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize), spacing: 4)], spacing: 4) {
                    ForEach(items) { cell($0) }
                }
                .padding(.horizontal, gridPadding)
            }
            .scrollPosition($position)
            .keyboardSelection(model: model, focused: $focused, width: $width) { move($0) }
        }
    }

    /// An arrow key: the model moves the selection, then the grid scrolls it into view.
    private func move(_ key: KeyEquivalent) {
        let bursts = model.view == .pass("bursts")  // rows scroll sideways: every arrow steps one photo
        switch key {
        case .leftArrow: model.moveSelection(by: -1)
        case .rightArrow: model.moveSelection(by: 1)
        case .upArrow: model.moveSelection(by: bursts ? -1 : -columns)
        default: model.moveSelection(by: bursts ? 1 : columns)
        }
        guard let a = model.anchor else { return }
        if bursts {
            if let n = model.groups.firstIndex(where: { $0.photos.contains { $0.id == a } }) { position.scrollTo(id: n) }
        } else {
            position.scrollTo(id: a)
        }
    }

    private func cell(_ p: PassPhoto) -> some View {
        let mark: PhotoCell.Mark = switch model.view {
        case .all: .none
        case .deleted: .deleteMe
        case .pass: model.decision(p.id).map { .decision($0) } ?? .none
        }
        return PhotoCell(photo: p, mark: mark, selected: model.selected.contains(p.id), thumbnails: thumbnails,
                         onTap: {
                             let mods = NSEvent.modifierFlags
                             model.click(p.id, extend: mods.contains(.shift), toggle: mods.contains(.command))
                         })
            .help(model.view == .deleted ? model.deletedAlbum[p.id] ?? "" : "")
    }
}

extension View {
    /// The grid takes keyboard focus: arrows move the selection, ⌘A selects all, K keeps and ⌫ deletes it.
    fileprivate func keyboardSelection(model: ReviewModel, focused: FocusState<Bool>.Binding, width: Binding<CGFloat>,
                                       move: @escaping (KeyEquivalent) -> Void) -> some View {
        self
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width.wrappedValue = $0 }
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onAppear { focused.wrappedValue = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                move(press.key)
                return .handled
            }
            .onKeyPress("k") {
                model.markSelection(.keep)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                model.markSelection(.delete)
                return .handled
            }
            .background {
                Button("Select All") { model.selectAll() }.keyboardShortcut("a").hidden()
            }
    }
}
