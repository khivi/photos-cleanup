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
    private var columns: Int { max(1, Int((width - 2 * gridPadding + 4) / (model.cellSize + 4))) }
    private let gridPadding: CGFloat = 12

    private var pollKey: String { "\(model.view.passKey ?? "")\(model.progress.pending > 0)" }
    private var countsKey: [Bool] { [model.loading, model.committing, model.progress.pending == 0] }

    private var items: [PassPhoto] {
        model.view == .deleted ? model.deleted.map { PassPhoto(photo: $0) } : model.shownPhotos
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
                            HStack {
                                Label(item.title, systemImage: item.icon)
                                if let p = item.progress {
                                    Spacer()
                                    ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
                                        .tint(.accentColor)  // a selected row draws it grey, near-invisible early on
                                }
                            }
                            // The tooltip goes on the row's own content, full width: after .badge it never showed.
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .help(item.help)
                            // A Text badge: .badge(Int) hides 0, and a pass's 0 says it found nothing.
                            .badge(item.progress == nil ? item.badge.map { Text($0.formatted()) } : nil)
                            .tag(item.view)
                            .accessibilityIdentifier(item.view.sidebarID)
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
                        .accessibilityIdentifier("commit-confirm")
                } message: {
                    Text(model.commitPreview.map(\.label).joined(separator: "\n"))
                }
        }
        .focusedSceneValue(\.reviewModel, model)
        .onChange(of: model.anchor) {
            guard let a = model.anchor else { return }
            if let j = model.sectionJump, j.photo == a {
                position.scrollTo(id: sectionID(j.key), anchor: .top)
            } else {
                position.scrollTo(id: a)
            }
        }
        .onChange(of: model.view) { model.showsInspector = savedInspector(model.view) }
        .onChange(of: model.showsInspector) {
            UserDefaults.standard.set(model.showsInspector, forKey: inspectorKey(model.view))
        }
        .onChange(of: model.zoom) {
            UserDefaults.standard.set(model.zoom, forKey: zoomKey)
            thumbnails.setCell(model.cellSize)
        }
        .onChange(of: model.aspectFit) { UserDefaults.standard.set(model.aspectFit, forKey: aspectFitKey) }
        .task(id: pollKey) {
            while model.inPass && model.progress.pending > 0 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                await model.refresh()
            }
        }
        .task(id: model.export.running) {
            while model.export.running && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.pollExport()
            }
        }
        .task(id: model.importBusy) {
            while model.importBusy != nil && !Task.isCancelled {
                await model.pollImport()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task { await model.refreshExport() }  // the Export badge; the photo list read takes a moment
        .task(id: countsKey) {
            guard !model.loading && !model.committing else { return }
            await model.refreshCounts()
            // Badges appear as Vision finishes; rings move while it or the verdicts run, in any view.
            while (model.countsPending || model.jobsRunning) && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.refreshPassCounts()
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if showsGrid {
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus") { model.zoomOut() }.disabled(!model.canZoomOut)
                    .accessibilityIdentifier("zoom-out")
                Button("Zoom In", systemImage: "plus") { model.zoomIn() }.disabled(!model.canZoomIn)
                    .accessibilityIdentifier("zoom-in")
            }
            ToolbarItem {
                @Bindable var model = model
                Toggle(model.aspectToggleLabel, systemImage: "aspectratio", isOn: $model.aspectFit)
                    .help(model.aspectToggleLabel)
                    .accessibilityIdentifier("aspect-toggle")
            }
        }
        ToolbarItem {
            Button(model.inspectorToggleLabel, systemImage: "info.circle") { model.showsInspector.toggle() }
                .accessibilityIdentifier("inspector-toggle")
        }
        if model.canFilter {
            ToolbarItem {
                @Bindable var model = model
                Toggle(
                    ReviewModel.onlyDeleteLabel, systemImage: "line.3.horizontal.decrease.circle",
                    isOn: $model.onlyDelete
                )
                .help(ReviewModel.onlyDeleteLabel)
                .accessibilityIdentifier("only-delete-toggle")
            }
        }
        if model.inPass {
            ToolbarItemGroup {
                Group {
                    Button(ReviewModel.keepAllLabel, systemImage: "checkmark") { model.setAll(.keep) }
                        .accessibilityIdentifier("keep-all")
                    Button(ReviewModel.deleteAllLabel, systemImage: "trash") { model.setAll(.delete) }
                        .accessibilityIdentifier("delete-all")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!model.canSetAll)
            }
        }
        if model.view == .deleted {
            ToolbarItem {
                Button(model.deleteInPhotosLabel, systemImage: "trash") { Task { await model.deleteInPhotos() } }
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canDeleteInPhotos)
                    .accessibilityIdentifier("delete-in-photos")
            }
        }
        if model.canMark {  // Keep All / Delete All stay pass-only; All has just the move
            ToolbarItem {
                Button(model.moveButtonLabel) { model.confirmingMove = true }
                    .disabled(!model.canMove)
                    .accessibilityIdentifier("commit")
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

    /// The window shows a photo grid: not Export, Import or an empty state.
    private var showsGrid: Bool { model.view != .export && model.view != .importFolders && !model.showsEmptyState }

    @ViewBuilder private var content: some View {
        if model.view == .export {
            ExportView(model: model)
        } else if model.view == .importFolders {
            ImportView(model: model)
        } else if model.showsEmptyState {
            ContentUnavailableView(model.emptyStateLabel, systemImage: "checkmark.circle")
        } else {
            // One ScrollView for every list: a second one would leave keyboard focus on the old one.
            ScrollView {
                if let caption = model.passCaption {
                    HStack(alignment: .firstTextBaseline) {
                        Text(caption).lineLimit(model.captionFolded ? 1 : nil)
                            .help(model.captionFolded ? caption : "")
                        Spacer()
                        Button(model.captionToggleLabel) { model.toggleCaption() }
                            .buttonStyle(.link).focusable(false)
                            .accessibilityIdentifier("caption-toggle")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, gridPadding).padding(.top, 8)
                }
                if model.isGrouped {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.shownGroups, id: \.best) { groupRow($0) }
                    }
                    .padding(.horizontal, gridPadding)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: model.cellSize, maximum: model.cellSize * cellGrowth), spacing: 4)
                        ], spacing: 4
                    ) {
                        if model.view == .all {
                            ForEach(model.shownGroups, id: \.best) { group in
                                Section {
                                    ForEach(group.photos) { cell(PassPhoto(photo: $0)) }
                                } header: {
                                    HStack {
                                        Text(model.header(group)).font(.headline)
                                        if model.view == .all {
                                            Toggle(
                                                "Done",
                                                isOn: Binding(
                                                    get: { model.isDone(group) }, set: { _ in model.toggleDone(group) })
                                            )
                                            .accessibilityIdentifier("done-\(group.best)")
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                    .id(sectionID(group.best))
                                }
                            }
                        } else {
                            ForEach(items) { cell($0) }
                        }
                    }
                    .padding(.horizontal, gridPadding)
                }
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

    /// An arrow key: the model moves the selection; `onChange(of: model.anchor)` scrolls it into view.
    private func move(_ key: KeyEquivalent) {
        let step = model.previewing ? 1 : columns  // in the preview, up and down are one photo like left and right
        if model.isGrouped && !model.previewing && (key == .upArrow || key == .downArrow) {
            return model.moveSection(by: key == .upArrow ? -1 : 1)  // one row per group
        }
        switch key {
        case .leftArrow: model.moveSelection(by: -1)
        case .rightArrow: model.moveSelection(by: 1)
        case .upArrow: model.moveSelection(by: -step)
        default: model.moveSelection(by: step)
        }
    }

    /// A grouped pass's row: the ★ at full size, the others smaller beside it. Collapsed, the row
    /// ends in "+N"; expanded, the others wrap onto more rows beside the ★.
    private func groupRow(_ group: BurstGroup) -> some View {
        let big = model.cellSize
        let small = (big * 0.6).rounded()
        let perRow = max(1, Int((width - 2 * gridPadding - big) / (small + 4)))
        let rest = group.photos.dropFirst().map { PassPhoto(photo: $0) }
        let open = model.isExpanded(group)
        let shown = open || rest.count <= perRow ? rest : Array(rest.prefix(perRow - 1))
        let rows = stride(from: 0, to: shown.count, by: perRow).map { Array(shown[$0..<min($0 + perRow, shown.count)]) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.header(group)).font(.headline)
                if model.expanded.contains(group.best) {
                    Button("Show Less") { model.toggleExpanded(group) }.buttonStyle(.link).focusable(false)
                }
            }
            .padding(.top, 8)
            HStack(alignment: .top, spacing: 4) {
                cell(PassPhoto(photo: group.photos[0])).frame(width: big, height: big)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(rows[r]) { cell($0, compact: true).frame(width: small, height: small) }
                            if r == rows.count - 1 && shown.count < rest.count {
                                Button {
                                    model.toggleExpanded(group)
                                } label: {
                                    Text("+\(rest.count - shown.count)").font(.title3.weight(.semibold))
                                        .frame(width: small, height: small)
                                        .background(.gray.opacity(0.15), in: .rect(cornerRadius: 4))
                                }
                                .buttonStyle(.plain).focusable(false)
                                .accessibilityIdentifier("expand-\(group.best)")
                            }
                        }
                    }
                }
            }
        }
        .id(sectionID(group.best))
    }

    private func cell(_ p: PassPhoto, compact: Bool = false) -> some View {
        let mark: PhotoCell.Mark =
            switch model.view {
            case .all:
                model.decision(p.id).map { .decision($0) } ?? (model.deletedAlbum[p.id] != nil ? .deleteMe : .none)
            case .deleted: .deleteMe
            case .pass: model.decision(p.id).map { .decision($0) } ?? .none
            case .export, .importFolders: .none
            }
        return PhotoCell(
            photo: p, mark: mark, selected: model.selected.contains(p.id), best: model.isBest(p.id), compact: compact,
            label: model.accessibilityLabel(p), thumbnails: thumbnails, aspectFit: model.aspectFit,
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

extension ReviewView {
    var sidebarID: String {
        switch self {
        case .all: "tab-all"
        case .pass(let key): "tab-\(key)"
        case .deleted: "tab-deleted"
        case .export: "tab-export"
        case .importFolders: "tab-import"
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
                    .accessibilityIdentifier("mark-keep")
                Button("Delete") { model?.markSelection(.delete) }
                    .keyboardShortcut(.delete, modifiers: [])
                    .accessibilityIdentifier("mark-delete")
            }
            .disabled(model?.canMark != true)
            Divider()
            Group {
                Button(ReviewModel.keepAllLabel) { model?.setAll(.keep) }
                Button(ReviewModel.deleteAllLabel) { model?.setAll(.delete) }
            }
            .disabled(model?.canSetAll != true)
            Divider()
            // No shortcut here: the grid's own Space handler toggles the preview, and a bare-Space key equivalent would also catch Space in dialogs.
            Button(model?.inspectorToggleLabel ?? "Show Info") { model?.showsInspector.toggle() }
                .keyboardShortcut("i").disabled(model == nil)
            Button("Preview") { model?.togglePreview() }.disabled(model == nil)
            Button(model?.deleteInPhotosLabel ?? "Delete in Photos…") { Task { await model?.deleteInPhotos() } }
                .disabled(model?.canDeleteInPhotos != true)
            Button("Move to Albums…") { model?.confirmingMove = true }
                .disabled(model?.canMove != true)
                .accessibilityIdentifier("commit-menu")
            if canShowInPhotos {
                Button(ReviewModel.showInPhotosLabel) { Task { await model?.showInPhotos(run: runAppleScript) } }
                    .keyboardShortcut("r").disabled(model?.canShowInPhotos != true)
            }
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { model?.zoomIn() }
                .keyboardShortcut("+").disabled(model?.canZoomIn != true)
            Button("Zoom Out") { model?.zoomOut() }
                .keyboardShortcut("-").disabled(model?.canZoomOut != true)
            Button(model?.aspectToggleLabel ?? "Show Whole Photos") { model?.aspectFit.toggle() }
                .disabled(model == nil)
            Divider()
            Button(ReviewModel.onlyDeleteLabel) { model?.onlyDelete.toggle() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model?.canFilter != true)
            Button("Next Section") { model?.moveSection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(model?.canMoveSection != true)
            Button("Previous Section") { model?.moveSection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(model?.canMoveSection != true)
            Divider()
            ForEach(ReviewModel.tabs, id: \.title) { tab in
                Button(tab.title) { if let model { Task { await model.select(tab.view) } } }
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
/// The Info panel is open or closed per view; a view never set falls back to the old app-wide setting.
func inspectorKey(_ v: ReviewView) -> String { "\(inspectorKey).\(v.sidebarID)" }
func savedInspector(_ v: ReviewView) -> Bool {
    UserDefaults.standard.object(forKey: inspectorKey(v)) as? Bool ?? UserDefaults.standard.bool(forKey: inspectorKey)
}
let zoomKey = "gridZoom"
let aspectFitKey = "gridAspectFit"

private struct ScriptError: LocalizedError {
    let errorDescription: String?
}

/// Runs AppleScript off the main thread. The first run asks for Automation access to Photos.
private func runAppleScript(_ source: String) async throws {
    try await Task.detached {
        var info: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&info)
        if let info { throw ScriptError(errorDescription: info[NSAppleScript.errorMessage] as? String ?? "\(info)") }
    }.value
}

/// A section header's scroll id. Prefixed: a burst's key is its best photo's id, which its cell already uses.
private func sectionID(_ key: String) -> String { "section-\(key)" }

/// The Info panel. Nothing in it takes focus: marking hands focus back to the grid so the arrows keep working.
struct InspectorView: View {
    let model: ReviewModel
    let thumbnails: Thumbnails
    let refocus: () -> Void

    var body: some View {
        if let info = model.inspectorInfo() {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Color.gray.opacity(0.15).frame(height: 200)
                        .overlay { LargeImage(id: info.id, side: 260, thumbnails: thumbnails) }
                        .clipShape(.rect(cornerRadius: 4))
                    Text(info.date).font(.headline)
                    Text(info.kind).foregroundStyle(.secondary)
                    if let v = info.verdict { Text(v) }
                    if let s = info.score { Text(s) }
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
                    if canShowInPhotos {
                        Button(ReviewModel.showInPhotosLabel) {
                            Task {
                                await model.showInPhotos(run: runAppleScript)
                                refocus()
                            }
                        }
                        .focusable(false)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(model.inspectorPlaceholder).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
