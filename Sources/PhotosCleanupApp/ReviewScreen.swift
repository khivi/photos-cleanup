import AppKit
import Photos
import PhotosCleanupCore
import SwiftUI

/// The review screen: sidebar, toolbar and grid. Every label and decision comes from `ReviewModel`.
struct ReviewScreen: View {
    let model: ReviewModel
    let thumbnails: Thumbnails
    @State private var position = ScrollPosition(edge: .top)
    @State private var width: CGFloat = 800
    @FocusState private var focused: Bool

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
        @Bindable var model = model
        return NavigationSplitView {
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(model.windowTitle)
                .navigationSubtitle(model.windowSubtitle)
                .toolbar { toolbar }
                .inspector(isPresented: $model.showsInspector) {
                    InspectorView(model: model, thumbnails: thumbnails) { focused = true }
                        .inspectorColumnWidth(min: 220, ideal: 260, max: 400)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .confirmationDialog("Move to Albums?", isPresented: $model.confirmingMove) {
                    Button("Move", role: .destructive) { Task { await model.commit() } }
                } message: {
                    Text(model.commitPreview.map(\.label).joined(separator: "\n"))
                }
        }
        .focusedSceneValue(\.reviewModel, model)
        .onChange(of: model.showsInspector) { UserDefaults.standard.set(model.showsInspector, forKey: inspectorKey) }
        .task(id: pollKey) {
            while model.inPass && model.progress.pending > 0 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await model.refresh()
            }
        }
        .task(id: countsKey) {
            guard !model.loading && !model.committing else { return }
            await model.refreshCounts()
            while model.countsPending && !Task.isCancelled {  // badges appear as the background Vision run finishes
                try? await Task.sleep(for: .seconds(2))
                await model.refreshPassCounts()
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.showsProgress {
            ToolbarItem {
                ProgressView(value: Double(model.progressDone), total: Double(max(model.progressTotal, 1)))
                    .frame(width: 100)
                    .help(
                        "Analysing photos on this Mac: \(model.progressDone.formatted()) of \(model.progressTotal.formatted())"
                    )
            }
        }
        ToolbarItem {
            Button(model.inspectorToggleLabel, systemImage: "info.circle") { model.showsInspector.toggle() }
        }
        if model.inPass {
            ToolbarItemGroup {
                Group {
                    Button(ReviewModel.keepAllLabel, systemImage: "checkmark") { model.setAll(.keep) }
                    Button(ReviewModel.deleteAllLabel, systemImage: "trash") { model.setAll(.delete) }
                }
                .labelStyle(.titleAndIcon)
                .disabled(!model.canSetAll)
            }
        }
        if model.canMark {  // Keep All / Delete All stay pass-only; All has just the move
            ToolbarItem {
                Button(model.moveButtonLabel) { model.confirmingMove = true }
                    .disabled(!model.canMove)
            }
        }
    }

    /// One line under the grid for what used to be banners: after a move, To be deleted's albums, errors.
    @ViewBuilder private var statusBar: some View {
        let lines = [
            model.banner, model.error, model.progressError, model.verdictsOff.map { "\($0). Everything else works." },
        ]
        .compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder private var content: some View {
        if model.showsEmptyState {
            ContentUnavailableView(ReviewModel.emptyState, systemImage: "checkmark.circle")
        } else {
            // One ScrollView for every list: a second one would leave keyboard focus on the old one.
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellMax), spacing: 4)], spacing: 4) {
                    if model.view == .pass("bursts") {
                        ForEach(model.groups, id: \.best) { group in
                            Section {
                                ForEach(group.photos) { cell(PassPhoto(photo: $0)) }
                            } header: {
                                Text(group.headerLabel()).font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }
                        }
                    } else {
                        ForEach(items) { cell($0) }
                    }
                }
                .padding(.horizontal, gridPadding)
            }
            .scrollPosition($position)
            .keyboardSelection(model: model, focused: $focused, width: $width) { move($0) }
            .overlay {  // an overlay, not a swap: the grid stays in the hierarchy and keeps keyboard focus
                if let p = model.preview {
                    PhotoPreview(preview: p, thumbnails: thumbnails).onTapGesture { model.closePreview() }
                }
            }
        }
    }

    /// An arrow key: the model moves the selection, then the grid scrolls it into view.
    private func move(_ key: KeyEquivalent) {
        let step = model.previewing ? 1 : columns  // in the preview, up and down are one photo like left and right
        switch key {
        case .leftArrow: model.moveSelection(by: -1)
        case .rightArrow: model.moveSelection(by: 1)
        case .upArrow: model.moveSelection(by: -step)
        default: model.moveSelection(by: step)
        }
        if let a = model.anchor { position.scrollTo(id: a) }
    }

    private func cell(_ p: PassPhoto) -> some View {
        let mark: PhotoCell.Mark =
            switch model.view {
            case .all: model.decision(p.id).map { .decision($0) } ?? (model.deletedAlbum[p.id] != nil ? .deleteMe : .none)
            case .deleted: .deleteMe
            case .pass: model.decision(p.id).map { .decision($0) } ?? .none
            }
        return PhotoCell(
            photo: p, mark: mark, selected: model.selected.contains(p.id), best: model.isBest(p.id),
            thumbnails: thumbnails,
            onTap: {
                focused = true  // keys go to the grid, not the ScrollView's own arrow scrolling
                let mods = NSEvent.modifierFlags
                model.click(p.id, extend: mods.contains(.shift), toggle: mods.contains(.command))
            }
        )
        .help(model.view == .deleted ? model.deletedAlbum[p.id] ?? "" : "")
    }
}

extension View {
    /// The grid takes keyboard focus: arrows move the selection, Space toggles the preview, ⌘A selects all. K and ⌫ are menu commands.
    fileprivate func keyboardSelection(
        model: ReviewModel, focused: FocusState<Bool>.Binding, width: Binding<CGFloat>,
        move: @escaping (KeyEquivalent) -> Void
    ) -> some View {
        self
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width.wrappedValue = $0
            }
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onAppear { focused.wrappedValue = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                move(press.key)
                return .handled
            }
            .onKeyPress(.space) {
                model.togglePreview()
                return .handled
            }
            .onKeyPress(.escape) {
                guard model.previewing else { return .ignored }
                model.closePreview()
                return .handled
            }
            .background {
                Button("Select All") { model.selectAll() }.keyboardShortcut("a").hidden()
            }
    }
}

extension FocusedValues {
    @Entry var reviewModel: ReviewModel?
}

/// Edit > Undo and Redo drive the model's UndoManager directly, not the window's.
/// Photo > Keep (K) and Delete (⌫) are menu items because the default Edit > Delete takes ⌫ before
/// the grid sees it. Disabled outside the review window, so they don't steal keys from Settings.
struct ReviewCommands: Commands {
    @FocusedValue(\.reviewModel) private var model

    var body: some Commands {
        CommandMenu("Photo") {
            Group {
                Button("Keep") { model?.markSelection(.keep) }
                    .keyboardShortcut("k", modifiers: [])
                Button("Delete") { model?.markSelection(.delete) }
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .disabled(model?.canMark != true)
            Divider()
            Group {
                Button(ReviewModel.keepAllLabel) { model?.setAll(.keep) }
                    .keyboardShortcut("k", modifiers: [.command, .option])  // ⇧⌘K is often taken by other apps
                Button(ReviewModel.deleteAllLabel) { model?.setAll(.delete) }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            .disabled(model?.canSetAll != true)
            Divider()
            // No shortcut here: the grid's own Space handler toggles the preview, and a bare-Space key equivalent would also catch Space in dialogs.
            Button(model?.inspectorToggleLabel ?? "Show Info") { model?.showsInspector.toggle() }
                .keyboardShortcut("i").disabled(model == nil)
            Button("Preview") { model?.togglePreview() }.disabled(model == nil)
            Button("Move to Albums…") { model?.confirmingMove = true }
                .keyboardShortcut(.return)
                .disabled(model?.canMove != true)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            ForEach(Array(ReviewModel.tabs.prefix(9).enumerated()), id: \.offset) { i, tab in
                Button(tab.title) { if let model { Task { await model.select(tab.view) } } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .disabled(model == nil)
            }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { if let u = model?.undoManager, u.canUndo { u.undo() } }
                .keyboardShortcut("z")
            Button("Redo") { if let u = model?.undoManager, u.canRedo { u.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

let inspectorKey = "showsInspector"

/// The Info panel. Nothing in it takes focus: marking hands focus back to the grid so the arrows keep working.
struct InspectorView: View {
    let model: ReviewModel
    let thumbnails: Thumbnails
    let refocus: () -> Void
    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        if let info = model.inspectorInfo() {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Color.gray.opacity(0.15).frame(height: 200)
                        .overlay { if let image { Image(nsImage: image).resizable().scaledToFit() } }
                        .clipShape(.rect(cornerRadius: 4))
                    Text(info.date).font(.headline)
                    Text(info.kind).foregroundStyle(.secondary)
                    if let v = info.verdict { Text(v) }
                    Text(info.albums).foregroundStyle(.secondary)
                    if let t = info.target { Text(t) }
                    if let d = info.decision {
                        Picker(
                            "Mark",
                            selection: Binding(
                                get: { d },
                                set: {
                                    model.mark([info.id], $0)
                                    refocus()
                                })
                        ) {
                            Text("Keep").tag(Decision.keep)
                            Text("Delete").tag(Decision.delete)
                        }
                        .pickerStyle(.segmented).labelsHidden().focusable(false)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: info.id) {
                image = nil
                if let requestID { thumbnails.cancel(requestID) }
                let id = info.id
                requestID = thumbnails.requestLarge(id, side: 260) { img in
                    if id == model.inspectorInfo()?.id { image = img ?? image }
                }
            }
            .onDisappear { if let requestID { thumbnails.cancel(requestID) } }
        } else {
            Text(model.inspectorPlaceholder).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
