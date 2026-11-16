import Foundation
import Observation

public enum ReviewView: Hashable, Sendable {
    case pass(String)  // a key from `Passes.all`
    case unsure  // photos accepted as Unsure in a pass, by pass
    case deleted  // photos waiting in Delete Me albums
    case export  // the backup to a folder or disk
    case importFolders  // old photo folders sorted against the library
    case pending  // confirmed photos not yet applied to Photos

    public var passKey: String? { if case .pass(let k) = self { k } else { nil } }
}

public enum Decision: Sendable, Equatable {
    /// Unsure: the user can't decide yet. Accepting a section moves it to the Unsure view.
    case keep, delete, unsure

    public var label: String {
        switch self {
        case .keep: "Keep"
        case .delete: "Remove"
        case .unsure: "Unsure"
        }
    }
    public var badge: String {
        switch self {
        case .keep: "✓ Keep"
        case .delete: "Remove"
        case .unsure: "? Unsure"
        }
    }
}

/// The review screen's state over a `Cleanup`: the current view, per-photo decisions, commits and
/// the "In Delete Me Albums" list. No timers: the view calls `refresh()` while `progress.pending > 0`.
@MainActor @Observable
public final class ReviewModel {
    public private(set) var view = ReviewView.pass(Passes.all[0].key)
    public private(set) var photos: [PassPhoto] = []
    /// Grouped passes: one row per group.
    public private(set) var groups: [BurstGroup] = []
    /// Vision aesthetics scores from the pass, for `scoreLine`.
    public private(set) var scores: [String: Double] = [:]
    /// Worst-face qualities, in groups whose ★ faces helped pick, for `scoreLine`.
    public private(set) var faces: [String: Double] = [:]
    public private(set) var decisions: [String: Decision] = [:]
    /// Decided explicitly by the user.
    public private(set) var touched: Set<String> = []
    /// The user's marks in each pass and Unsure, kept when another view opens, so they are still there on return.
    /// In memory only: Pending is what survives a relaunch.
    private var savedMarks: [ReviewView: [String: Decision]] = [:]
    /// The ★ of each group, by the group's key (Vision's pick), where the user picked another.
    private var starred: [String: String] = [:]
    private var savedStars: [ReviewView: [String: String]] = [:]
    /// Confirmed, not yet applied to Photos, by uuid. Saved in `pending`, so it survives relaunch.
    public private(set) var pending: [String: Pending]
    /// Accepted as Unsure: the pass each came from, by uuid. Saved in `unsure`; held out of the passes.
    public private(set) var unsure: [String: String]
    /// Every photo by uuid, read when Pending opens: it lists photos from every pass.
    private var library: [String: Photo] = [:]
    /// Photos this session's commits moved to a Delete Me album, newest first.
    private var committed: [Photo] = []
    private var committedAlbum: [String: String] = [:]
    /// Photos already in a Delete Me album when the library loaded.
    private var loaded: [Photo] = []
    private var loadedAlbum: [String: String] = [:]
    /// Every photo waiting in a Delete Me album: this session's commits, then the loaded ones.
    public var deleted: [Photo] {
        let seen = Set(committed.map(\.id))
        return committed + loaded.filter { !seen.contains($0.id) }
    }
    /// The Delete Me album each photo in `deleted` is in.
    public var deletedAlbum: [String: String] { loadedAlbum.merging(committedAlbum) { _, new in new } }
    public private(set) var progress = JobProgress()
    public private(set) var export = ExportStatus()
    /// Photos in `deleted` the export doesn't hold: Delete in Photos would lose them.
    public private(set) var deletedNotExported = 0
    private var importBookmarks: [FolderBookmark] = []
    private var exportBookmark: FolderBookmark?
    public var importFolders: [URL] { importBookmarks.map(\.url) }
    /// This session's checks, by folder.
    public private(set) var importScans: [URL: ImportScan] = [:]
    /// The folder the Import screen shows.
    public var importFolder: URL?
    /// The folder being checked or sorted, and the check's files done of total.
    public private(set) var importBusy: URL?
    public private(set) var importProgress = (done: 0, total: 0)
    /// The last sort's moves that failed, "from: why".
    public private(set) var importFailures: [String] = []
    public private(set) var counts: [String: Int?] = [:]
    /// The background Vision analysis and verdict queue, refreshed with `counts`.
    public private(set) var vision = JobProgress()
    public private(set) var verdictJob = JobProgress()
    var verdictPasses: Set<String> = []
    public private(set) var loading = false
    public private(set) var committing = false
    public private(set) var deleting = false
    public private(set) var status: String?
    public private(set) var error: String?
    public var verdictsOff: String? { cleanup.verdictsOff }

    /// The photos the user selected in the grid, always among `displayed`.
    public private(set) var selected: Set<String> = []
    /// Where a ⇧-click range starts and arrow keys move from.
    public private(set) var anchor: String?
    /// The large in-window preview of the anchor photo is open.
    public private(set) var previewing = false

    /// Marks register their undo here; Edit > Undo and Redo drive it.
    public let undoManager = UndoManager()
    /// What Undo would undo: UndoManager isn't observable, so the toolbar button reads these.
    public private(set) var undoName: String?
    public var canUndo: Bool { undoName != nil }
    public var undoHelp: String { undoName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo" }
    @ObservationIgnored private var undoObservers: [any NSObjectProtocol] = []

    private let cleanup: Cleanup
    private let exporter: Exporter?
    private let importer: Importer?
    private let dir: URL
    private let defaults: UserDefaults

    public init(
        cleanup: Cleanup, exporter: Exporter? = nil, exportBookmark: FolderBookmark? = nil, importer: Importer? = nil,
        dir: URL = settingsDir, defaults: UserDefaults = .standard
    ) {
        self.exportBookmark = exportBookmark
        self.cleanup = cleanup
        self.exporter = exporter
        self.importer = importer
        self.dir = dir
        self.defaults = defaults
        pending = loadPending(dir: dir).mapValues { Pending(pass: $0.pass, keep: $0.keep) }
        unsure = loadUnsure(dir: dir)
        importBookmarks = loadImportFolders(defaults: defaults)
        importFolder = importFolders.first
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncUndo() }
            }
        }
    }

    private func forgetUndo() {
        undoManager.removeAllActions()
        undoName = nil
    }

    private func syncUndo() { undoName = undoManager.canUndo ? undoManager.undoActionName : nil }

    public var best: Set<String> { Set(groups.map(\.best)) }

    /// Show only photos marked Remove. Off on every view change.
    public var onlyDelete = false { didSet { pruneSelection() } }
    public static let onlyDeleteLabel = "Show Only Remove"
    public var canFilter: Bool { canMark }

    private func shown(_ id: String) -> Bool { !onlyDelete || decisions[id] == .delete }
    /// `photos` under the filter: what the grid shows.
    public var shownPhotos: [PassPhoto] { photos.filter { shown($0.id) } }
    /// `groups` under the filter, empty groups dropped.
    public var shownGroups: [BurstGroup] {
        guard onlyDelete else { return groups }
        return groups.map { BurstGroup(photos: $0.photos.filter { shown($0.id) }, best: $0.best) }
            .filter { !$0.photos.isEmpty }
    }

    /// Vision's pick of a group, shown with a star in the grouped passes only.
    public func isBest(_ id: String) -> Bool {
        isGrouped && groups.contains { (starred[$0.best] ?? $0.best) == id }
    }

    func initialDecision(_ p: PassPhoto) -> Decision {
        switch view {
        case .pass(let k) where Passes.grouped.contains(k):
            return best.contains(p.id) || p.photo.edited ? .keep : .delete
        case .pass(let k) where Passes.verdictKinds.contains(k):
            if let v = p.verdict, !v.keep { return .delete }
            return .keep
        case .pass("videos"): return p.photo.duration < Passes.accidentalVideoMax ? .delete : .keep
        case .pass: return p.photo.edited ? .keep : .delete  // Low Quality: edits are kept
        case .unsure: return .unsure
        default: return .keep
        }
    }

    public func decision(_ uuid: String) -> Decision? { decisions[uuid] }

    /// Photos to show: the To be deleted list, or the loaded ones.
    public var displayed: [Photo] {
        switch view {
        case .deleted: deleted
        case .pending: pendingGroups.flatMap(\.photos)
        default: shownPhotos.map(\.photo)
        }
    }

    public var doomed: [PassPhoto] { photos.filter { decisions[$0.id] == .delete } }
    /// K, ⌫, ? and the Inspector's picker work: in a pass and in Unsure.
    public var canMark: Bool { inPass || view == .unsure }

    // MARK: Labels (what the screen shows; views only lay them out)

    public static let tabs: [(view: ReviewView, title: String, help: String)] =
        Passes.all.map { (.pass($0.key), $0.title, Passes.about[$0.key] ?? "") }
        + [
            (
                .unsure, unsureTitle,
                "Photos you accepted as Unsure (?) in a pass. Keep (K) or Remove (⌫) them here, then accept."
            ),
            (
                .pending, "Not in Photos Yet",
                "Photos you accepted, not yet in their albums. Apply to Photos… adds them; nothing changes in Photos before."
            ),
            (.deleted, "In Delete Me Albums", "Photos waiting in a Delete Me album. Delete them there in Photos."),
            (
                .export, "Export",
                "Copies every photo and video to a folder or disk. Each run copies only what’s new or changed."
            ),
            (
                .importFolders, "Import",
                "Sorts folders of old photos into Done (already in your library) and Import (to bring into Photos)."
            ),
        ]

    // MARK: Sidebar

    /// Each sidebar row's SF Symbol; Photos' own where it has the same row.
    static let icons: [ReviewView: String] = [
        .unsure: "questionmark.circle", .pass("screenshots"): "camera.viewfinder",
        .pass("paperwork"): "doc.text", .pass("bursts"): "square.stack.3d.down.right",
        .pass("similar"): "square.on.square", .pass("low-quality"): "camera.metering.unknown",
        .pass("videos"): "video", .deleted: "trash", .pending: "tray.full", .export: "square.and.arrow.up",
        .importFolders: "square.and.arrow.down",
    ]

    public struct SidebarItem: Identifiable, Sendable {
        public let view: ReviewView
        public let title: String
        public let help: String
        /// The SF Symbol before the title, as Photos' own sidebar has.
        public let icon: String
        /// The photo count: nil while unknown. A pass or Unsure shows 0; the other rows show no badge at 0.
        public let badge: Int?
        /// A running job's fraction done, shown instead of the badge; `help` then also says which job.
        public var progress: Double?
        public var id: ReviewView { view }
    }

    public struct SidebarSection: Identifiable, Sendable {
        public let title: String
        public let items: [SidebarItem]
        public var id: String { title }
    }

    /// Cleanup (the passes, Unsure), Review (Pending, To be deleted), Transfer (Export, Import), built from `tabs`.
    public var sidebar: [SidebarSection] {
        func item(_ t: (view: ReviewView, title: String, help: String)) -> SidebarItem {
            let n: Int? =
                switch t.view {
                case .pass(let k): counts[k] ?? nil
                case .unsure: unsure.count
                case .deleted: deleted.count
                case .pending: pending.count
                case .export: export.destination == nil ? nil : export.pending
                case .importFolders: importScans.values.map(\.newCount).reduce(0, +)
                }
            // A pass waiting on a job shows how far it is: Vision first, then the verdicts. One per row.
            let job: JobProgress? = t.view.passKey.flatMap { k in
                if Self.visionPasses.contains(k) && n == nil && vision.pending > 0 { return vision }
                return verdictPasses.contains(k) && verdictJob.pending > 0 ? verdictJob : nil
            }
            let showsZero = t.view == .unsure || t.view.passKey != nil
            return SidebarItem(
                view: t.view, title: t.title,
                help: [t.view.passKey.map(passNote) ?? t.help, job.map(Self.jobLabel)].compactMap { $0 }.joined(
                    separator: "\n"),
                icon: Self.icons[t.view] ?? "photo",
                badge: n.flatMap { $0 > 0 || showsZero ? $0 : nil },
                progress: t.view == .export && export.running ? exportFraction : job?.fraction)
        }
        func items(_ keep: (ReviewView) -> Bool) -> [SidebarItem] { Self.tabs.filter { keep($0.view) }.map(item) }
        return [
            SidebarSection(title: "Cleanup", items: items { $0.passKey != nil || $0 == .unsure }),
            SidebarSection(title: "Review", items: items { $0 == .pending || $0 == .deleted }),
            SidebarSection(title: "Transfer", items: items { $0 == .export || $0 == .importFolders }),
        ]
    }

    public var inPass: Bool { view.passKey != nil }

    /// "41 photos · keeping 29 · removing 12", "N photos" or "N in Delete Me albums".
    public var summary: String {
        if view == .deleted { return "\(deleted.count.formatted()) in Delete Me albums" }
        if view == .pending { return "\(pending.count.formatted()) to apply to Photos" }
        if view == .export { return exportCountsLabel }
        if view == .importFolders { return importSummary }
        let unsure = photos.count { decisions[$0.id] == .unsure }
        let n = "\(photos.count.formatted()) \(photos.count == 1 ? "photo" : "photos")"
        let keeping = photos.count { decisions[$0.id] == .keep }
        return n + " · keeping \(keeping.formatted()) · removing \(doomed.count.formatted())"
            + (unsure > 0 ? " · \(unsure.formatted()) unsure" : "")
    }

    /// Passes whose photos depend on the Vision analysis.
    static let visionPasses: Set<String> = ["paperwork", "bursts", "similar", "low-quality"]

    /// A pass's explanation, then which photos it never suggests.
    public func passNote(_ key: String) -> String {
        let spared = cleanup.keepAlbumPhotos ? "Favorites and photos in your albums are" : "Favorites are"
        return "\(Passes.about[key] ?? "") \(spared) never suggested."
    }

    /// The line above a pass's grid: what it recommends. `captionHelp`, its tooltip, says how.
    public var passCaption: String? { view.passKey.flatMap { Passes.captions[$0] } }
    public var captionHelp: String? { view.passKey.map(passNote) }

    /// A sidebar ring's tooltip: which job, and how far.
    static func jobLabel(_ j: JobProgress) -> String {
        let what = j.verdicts ? "Checking photos with Apple Intelligence" : "Analysing photos on this Mac"
        return "\(what): \((j.total - j.pending).formatted()) of \(j.total.formatted())"
    }

    /// Vision or the verdicts still have photos to go: the sidebar keeps polling so its rings move.
    public var jobsRunning: Bool { vision.pending > 0 || verdictJob.pending > 0 }

    public var progressError: String? {
        guard !loading, let e = progress.error else { return nil }
        return
            "\(view.passKey.map(Passes.grouped.contains) == true ? "Similarity check unavailable" : "AI verdicts unavailable"): \(e)"
    }

    public var banner: String? {
        guard view == .deleted else { return status }
        if let status { return status }
        let albums = Dictionary(grouping: deleted.compactMap { deletedAlbum[$0.id] }, by: { $0 })
            .sorted { $0.key < $1.key }
            .map { "“\($0.key)” (\($0.value.count))" }
        guard !albums.isEmpty else { return "Nothing is waiting in a Delete Me album." }
        let unexported =
            deletedNotExported == 0
            ? ""
            : " \(deletedNotExported) of them \(deletedNotExported == 1 ? "isn’t" : "aren’t") in your export: run Export first to keep a copy."
        return
            "Nothing is deleted yet. Delete in Photos… deletes every photo in \(albums.joined(separator: ", ")) after macOS asks you to confirm. Photos keeps them in Recently Deleted for 30 days."
            + unexported
    }

    /// A pass shows one section at a time; with none left to show, the empty state.
    public var showsEmptyState: Bool {
        guard !loading else { return false }
        if inPass { return currentGroup == nil }
        return (onlyDelete || view == .pending || view == .unsure) && displayed.isEmpty
    }
    public var emptyStateLabel: String {
        if onlyDelete { return "Nothing marked Remove." }
        if view == .pending { return Self.nothingPending }
        if cleanupComplete { return Self.completeLabel }
        if view == .unsure { return Self.nothingUnsure }
        return Self.emptyState
    }
    public static let nothingPending =
        "Nothing here. Accept photos in a pass; they wait here until Apply to Photos…."
    public static let emptyState = "Nothing left to review. Photos already filed in this pass’s albums are hidden."
    public static let nothingUnsure = "Nothing is Unsure. Photos you accept as Unsure (?) in a pass wait here."
    public static let completeLabel = "Cleanup complete. Every pass and Unsure are empty."
    public static let unsureTitle = "Unsure"

    /// Every pass's count is known and 0, and nothing waits in Unsure.
    public var cleanupComplete: Bool {
        unsure.isEmpty && Passes.all.allSatisfy { (counts[$0.key] ?? nil) == 0 }
    }

    // MARK: Commit preview (Phase 5 labels)

    /// One album Apply to Photos will fill, and how many photos go in.
    public struct CommitLine: Sendable, Equatable {
        public var count: Int
        public var album: String
        /// "12 → Bursts - Delete Me"
        public var label: String { "\(count) → \(album)" }
    }

    /// Window title: the sidebar item's title.
    public var windowTitle: String { Self.tabs.first { $0.view == view }?.title ?? "" }
    /// Window subtitle: "N in Delete Me albums" and the like. A pass and Unsure show their counts in the
    /// header above the grid instead, beside the buttons the counts are about.
    public var windowSubtitle: String { loading ? "Loading…" : showsHeader ? "" : summary }
    /// The header above the grid: counts, the caption, and in a pass Keep All and Accept.
    public var showsHeader: Bool { canMark && !loading && !showsEmptyState }
    public var deleteInPhotosLabel: String { deleting ? "Deleting…" : "Delete \(deleted.count.formatted()) in Photos…" }
    /// Apply counts what waits in Not in Photos Yet; beside the Delete Me albums that number reads as theirs.
    public var showsApply: Bool { !pending.isEmpty && view != .deleted }
    /// Delete in Photos can run now: the To be deleted view, not empty.
    public var canDeleteInPhotos: Bool { view == .deleted && !loading && !deleting && !deleted.isEmpty }
    public var inspectorToggleLabel: String { showsInspector ? "Hide Info" : "Show Info" }
    public static let keepAllLabel = "Keep All"
    public static let focusNote = "Nothing is deleted until you confirm in Photos."
    public static let deleteMeBadge = "✗ Delete Me"
    public static let bestBadge = "★ Best shot"
    /// Above the photos beside a group's ★.
    public var othersLabel: String? {
        switch view.passKey {
        case "bursts": "Other shots from this burst"
        case "similar": "Other shots from this moment"
        default: nil
        }
    }

    // MARK: Loading

    public func select(_ v: ReviewView) async {
        status = nil
        previewing = false
        onlyDelete = false
        if canMark { savedMarks[view] = decisions.filter { touched.contains($0.key) } }
        if isGrouped { savedStars[view] = starred }
        if v == .export || v == .importFolders {
            view = v
            clearSelection()
            forgetUndo()
            if v == .export { await refreshExport() }
            return
        }
        await syncHeld()
        if v == .pending {
            library = Dictionary(await cleanup.photos.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
            view = v
            clearSelection()
            forgetUndo()
            return
        }
        if v == .deleted {
            await loadWaiting()
            view = v
            clearSelection()
            forgetUndo()
            return
        }
        loading = true
        defer { loading = false }
        do {
            var items: [PassPhoto] = []
            var gs: [BurstGroup] = []
            var sc: [String: Double] = [:]
            var fc: [String: Double] = [:]
            var prog = JobProgress()
            if let key = v.passKey {
                let r = try await cleanup.pass(key)
                (sc, fc, prog) = (r.scores, r.faces, r.progress)
                if Passes.grouped.contains(key) {
                    gs = r.groups.map(\.bestFirst)
                    items = Self.flat(gs)
                } else {
                    (items, gs) = Self.byMonth(r.photos)
                }
            } else {
                gs = unsureGroups(await cleanup.photos)
                items = Self.flat(gs)
            }
            view = v
            clearSelection()
            forgetUndo()  // another list: the marks belong to the old one
            photos = items
            groups = gs
            scores = sc
            faces = fc
            progress = prog
            decisions = [:]
            touched = []
            starred = savedStars[v] ?? [:]
            for p in items { decisions[p.id] = initialDecision(p) }
            let ids = Set(items.map(\.id))
            for (id, d) in savedMarks[v] ?? [:] where ids.contains(id) && pending[id] == nil {
                decisions[id] = d
                touched.insert(id)
            }
        } catch {
            self.error = "\(error)"
        }
    }

    static func flat(_ groups: [BurstGroup]) -> [PassPhoto] {
        groups.flatMap { $0.photos.map { PassPhoto(photo: $0) } }
    }

    /// A pass without groups in month sections; its own order (worst first, longest first) holds within a month.
    static func byMonth(_ ps: [PassPhoto]) -> (items: [PassPhoto], groups: [BurstGroup]) {
        let gs = monthGroups(ps.map(\.photo))
        let byID = Dictionary(ps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (gs.flatMap { $0.photos.compactMap { byID[$0.id] } }, gs)
    }

    /// One poll tick while Vision or verdicts run: new candidates merge in, touched choices stay.
    public func refresh() async {
        await syncHeld()
        guard let key = view.passKey, let r = try? await cleanup.pass(key), view.passKey == key else { return }
        scores = r.scores
        faces = r.faces
        if Passes.grouped.contains(key) {  // groups change as more photos are analysed: take them wholesale
            groups = r.groups.map(\.bestFirst)
            photos = Self.flat(groups)
        } else {
            let fresh = Dictionary(r.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let have = Set(photos.map(\.id))
            (photos, groups) = Self.byMonth(
                photos.map { p in fresh[p.id].map { PassPhoto(photo: p.photo, verdict: $0.verdict) } ?? p }
                    + r.photos.filter { !have.contains($0.id) })
        }
        for p in photos where !touched.contains(p.id) { decisions[p.id] = initialDecision(p) }
        progress = r.progress
        pruneSelection()
    }

    public func refreshCounts() async {
        await refreshPassCounts()
        await loadWaiting()
    }

    /// A pass count Vision will still fill in. Paperwork's count waits for its verdicts, which
    /// only start when the pass is opened, so it doesn't count as pending.
    public var countsPending: Bool {
        Passes.all.contains { $0.key != "paperwork" && (counts[$0.key] ?? nil) == nil }
    }

    /// The pass counts alone, cheap enough to poll while Vision runs.
    public func refreshPassCounts() async {
        await syncHeld()
        counts = await cleanup.counts()
        vision = await cleanup.visionStatus()
        (verdictJob, verdictPasses) = await cleanup.verdictStatus()
    }

    /// Read once per launch; photos deleted in Photos since then drop out on the next launch, of Unsure too.
    private func loadWaiting() async {
        let all = await cleanup.photos
        let ids = Set(all.map(\.uuid))
        if unsure.keys.contains(where: { !ids.contains($0) }) {
            unsure = unsure.filter { ids.contains($0.key) }
            saveState()
        }
        loaded = []
        loadedAlbum = [:]
        for p in all {
            if let a = Passes.waitingAlbum(in: p.albums) {
                loaded.append(p)
                loadedAlbum[p.id] = a
            }
        }
        deletedNotExported = await exporter?.missing(deleted.map(\.id)) ?? 0
    }

    // MARK: Deciding

    /// Marks `ids` as the user's choice.
    public func mark(_ ids: some Collection<String>, _ d: Decision) {
        apply(Dictionary(ids.map { ($0, (d, true)) }, uniquingKeysWith: { a, _ in a }), name: d.label)
    }
    /// ? marks Unsure, wherever K and ⌫ mark.
    public var canMarkUnsure: Bool { canMark }

    /// Sets each photo's decision and touched flag, and registers the reverse with the undo manager.
    /// Undo and redo pass through here too, so they register each other. Commits are not undoable.
    private func apply(_ new: [String: (decision: Decision?, touched: Bool)], name: String? = nil) {
        let have = Set(photos.map(\.id))  // a photo that left (committed) has nothing to restore
        let new = new.filter { have.contains($0.key) }
        var old: [String: (decision: Decision?, touched: Bool)] = [:]
        for id in new.keys { old[id] = (decisions[id], touched.contains(id)) }
        for (id, n) in new {
            decisions[id] = n.decision
            if n.touched { touched.insert(id) } else { touched.remove(id) }
        }
        let grouping = !(undoManager.isUndoing || undoManager.isRedoing)
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.apply(old) } }
        if let name { undoManager.setActionName(name) }
        if grouping { undoManager.endUndoGrouping() }
        if grouping { undoName = name ?? "" }
    }

    /// ⌫: toggles the selection between Keep and Remove, or on the Import screen removes the selected
    /// folder from the list (never from disk).
    public var deleteKeyLabel: String {
        view == .importFolders ? "Remove from List" : toggled == .keep ? Decision.keep.label : Decision.delete.label
    }
    public var canDeleteKey: Bool { view == .importFolders ? importFolder != nil && importBusy == nil : canMark }
    public func deleteKey() {
        guard canDeleteKey else { return }
        if view == .importFolders, let url = importFolder { return removeImportFolder(url) }
        markSelection(toggled)
    }
    /// What ⌫ marks: Keep when every selected photo is already Remove.
    private var toggled: Decision {
        !selected.isEmpty && selected.allSatisfy { decisions[$0] == .delete } ? .keep : .delete
    }

    /// K: in a pass, keeps the whole section and accepts it; in Unsure, marks the selection Keep.
    public var keepKeyLabel: String { inPass ? Self.keepAllLabel : Decision.keep.label }
    public var canKeepKey: Bool { inPass ? canConfirm : canMark }
    public func keepKey() async {
        guard canKeepKey else { return }
        if inPass { return await keepAll() }
        markSelection(.keep)
    }

    /// Marks the selected photos; only a pass and Unsure have marks. The selection stays on the photo, unless a filter hides it.
    public func markSelection(_ d: Decision) {
        guard canMark else { return }
        let one = selected.count == 1
        let before = order
        let at = anchor.flatMap { before.firstIndex(of: $0) }
        mark(selected, d)
        guard one, let at else { return pruneSelection() }
        let ids = order
        if let a = anchor, ids.contains(a) { return }  // the selection stays: arrows move it
        // The filter hid the photo: select the one that took its place.
        guard !ids.isEmpty else { return clearSelection() }
        selected = [ids[min(at, ids.count - 1)]]
        anchor = ids[min(at, ids.count - 1)]
    }

    // MARK: Selection

    /// What the arrows, ⇧-click and ⌘A walk: in a pass, the section on screen.
    private var order: [String] {
        inPass ? currentGroup?.photos.map(\.id) ?? [] : displayed.map(\.id)
    }

    /// A click: replaces the selection; ⇧ extends from the anchor to `id`; ⌘ toggles `id`.
    public func click(_ id: String, extend: Bool = false, toggle: Bool = false) {
        if extend, let anchor, let a = order.firstIndex(of: anchor), let i = order.firstIndex(of: id) {
            selected = Set(order[min(a, i)...max(a, i)])
        } else if toggle {
            if selected.remove(id) == nil { selected.insert(id) }
            anchor = id
        } else {
            selected = [id]
            anchor = id
        }
    }

    /// Space: opens the preview of the anchor photo, or closes it. Needs exactly one selected photo.
    public func togglePreview() {
        previewing = !previewing && selected.count == 1 && anchor != nil
    }

    public func closePreview() { previewing = false }

    /// What the preview shows: the anchor photo, its mark badge, the star and the verdict reason.
    public struct Preview: Sendable, Equatable {
        public let id: String
        public let badge: String?
        public let best: Bool
        public let reason: String?
        public let video: Bool
    }

    public var preview: Preview? {
        guard previewing, let id = anchor else { return nil }
        let verdict = photos.first { $0.id == id }?.verdict
        let badge: String? = view == .deleted ? Self.deleteMeBadge : decision(id).map(\.badge)
        return Preview(
            id: id, badge: badge, best: isBest(id), reason: verdict.map { "\($0.kind): \($0.reason)" } ?? scoreLine(id),
            video: displayed.first { $0.id == id }?.isMovie ?? false)
    }

    public func selectAll() { selected = Set(order) }

    // MARK: Inspector

    /// The Info side panel is open. The app persists it.
    public var showsInspector = false

    // MARK: Grid

    /// Thumbnail widths the grid steps through, in points, smallest first.
    public static let zoomSizes: [Double] = [80, 120, 180, 260]
    /// An index into `zoomSizes`; the app persists it, so a stale saved value is clamped on use.
    public var zoom = 1
    private var level: Int { min(max(zoom, 0), Self.zoomSizes.count - 1) }
    public var cellSize: Double { Self.zoomSizes[level] }
    public var canZoomIn: Bool { level < Self.zoomSizes.count - 1 }
    public var canZoomOut: Bool { level > 0 }
    public func zoomIn() { zoom = min(level + 1, Self.zoomSizes.count - 1) }
    public func zoomOut() { zoom = max(level - 1, 0) }

    /// Thumbnails show the whole photo instead of a square crop; the app persists it.
    public var aspectFit = false
    public var aspectToggleLabel: String { aspectFit ? "Show Square Photos" : "Show Whole Photos" }

    public static let showInPhotosLabel = "Show in Photos"

    public var canShowInPhotos: Bool { inspectorInfo() != nil }

    /// Selects the one selected photo in Photos. `run` executes the AppleScript; its error goes to `status`.
    public func showInPhotos(run: (String) async throws -> Void) async {
        guard let id = inspectorInfo()?.id else { return }
        status = nil
        do {
            try await run(
                """
                tell application "Photos"
                    activate
                    spotlight (first media item whose id is "\(id + PhotoKitLibrary.idSuffix)")
                end tell
                """)
        } catch {
            status = "\(error)"
        }
    }

    /// What the Info panel shows for the one selected photo.
    public struct Info: Sendable, Equatable {
        public let id: String
        public let date: String
        public let kind: String
        /// "kind: reason" of the verdict, if there is one.
        public let verdict: String?
        /// Why Vision's score made it a candidate or the ★, from `scoreLine`.
        public let score: String?
        public let albums: String
        /// "→ Screenshots - Delete Me": where Move to Albums puts it; nil when it stays put.
        public let target: String?
        /// The mark, in a pass only.
        public let decision: Decision?
    }

    /// The single selected photo, nil with none or several selected.
    public func inspectorInfo(locale: Locale = .current, timeZone: TimeZone = .current) -> Info? {
        guard selected.count == 1, let id = anchor, selected.contains(id),
            let p = view == .deleted
                ? deleted.first(where: { $0.id == id }).map({ PassPhoto(photo: $0) })
                : photos.first(where: { $0.id == id })
        else { return nil }
        var target: String?
        if let key = origin(id), let d = decisions[id] {
            switch d {
            case .delete: target = Passes.deleteAlbum(key)
            case .keep: target = Passes.keepAlbum(key)
            case .unsure: target = nil  // waits in Unsure
            }
        }
        let explained = why?.id == id  // the Why section already says it
        return Info(
            id: id, date: Self.dateLabel(p.photo, locale: locale, timeZone: timeZone), kind: p.photo.kindLabel,
            verdict: explained ? nil : p.verdict.map { "\($0.kind): \($0.reason)" },
            score: explained ? nil : scoreLine(id),
            albums: p.photo.albums.isEmpty
                ? "In no album"
                : "In \(p.photo.albums.count == 1 ? "album" : "albums"): \(p.photo.albums.sorted().joined(separator: ", "))",
            target: target.map { "→ \($0)" }, decision: canMark ? decisions[id] ?? .keep : nil)
    }

    static func dateLabel(_ p: Photo, locale: Locale, timeZone: TimeZone) -> String {
        let style = Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)
        return p.date.map { $0.formatted(style) } ?? "Unknown date"
    }

    /// What VoiceOver reads for a grid cell: "Video, 0:05, May 3, 2014 at 9:00 AM, marked Remove, ★ best shot, junk: blurry".
    public func accessibilityLabel(_ p: PassPhoto, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let mark =
            decision(p.id).map { "marked \($0.label)" }
            ?? (view == .deleted || deletedAlbum[p.id] != nil ? "in Delete Me" : nil)
        return [
            p.photo.kindLabel, p.photo.durationLabel, Self.dateLabel(p.photo, locale: locale, timeZone: timeZone), mark,
            isBest(p.id) ? "★ best shot" : nil, p.verdict.map { "\($0.kind): \($0.reason)" },
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// "Score -0.82 · Low Quality at -0.75 or below", "Score 0.41 · ★ of 6", "Score 0.12 · ★ scored 0.41";
    /// where faces helped pick, "Score 0.12 · face 0.3 · ★ face 0.8". Nil outside Low Quality and the grouped passes.
    public func scoreLine(_ id: String) -> String? {
        guard let key = view.passKey, let s = scores[id] else { return nil }
        let fmt = { (x: Double) in x.formatted(.number.precision(.fractionLength(2))) }
        if key == "low-quality" { return "Score \(fmt(s)) · Low Quality at \(fmt(Passes.lowQualityMax)) or below" }
        guard Passes.grouped.contains(key), let g = groups.first(where: { $0.photos.contains { $0.id == id } }),
            let best = g.photos.first(where: { $0.id == g.best })
        else { return nil }
        let line = "Score \(fmt(s))" + (faces[id].map { " · face \(fmt($0))" } ?? "")
        if id == g.best { return "\(line) · ★ of \(g.photos.count)\(best.edited ? ", edited" : "")" }
        if best.edited { return "\(line) · ★ is edited" }
        if let f = faces[g.best] { return "\(line) · ★ face \(fmt(f))" }
        return "\(line) · ★ scored \(scores[g.best].map(fmt) ?? "?")"
    }

    public static let whyTitle = "Why this photo?"

    /// The Info panel's "Why this photo?": what the app measured, never a signal it doesn't compute.
    public struct Why: Sendable, Equatable {
        public let id: String
        public let lines: [String]
    }

    /// The selected photo's reasons, if it is a group's ★ or has a verdict; with nothing selected in
    /// Bursts or Similar, the current group's ★.
    public var why: Why? {
        let id = selected.count == 1 ? anchor : selected.isEmpty && isGrouped ? currentStar : nil
        guard inPass, let id, let p = photos.first(where: { $0.id == id }) else { return nil }
        if let v = p.verdict {
            return Why(
                id: id,
                lines: ["Apple Intelligence suggests \(v.keep ? "keeping" : "removing") it: \(v.reason)"])
        }
        guard isBest(id), let g = groups.first(where: { $0.photos.contains { $0.id == id } }) else { return nil }
        let others = g.photos.filter { $0.id != id }
        let fmt = { (x: Double) in x.formatted(.number.precision(.fractionLength(2))) }
        func compare(_ best: String, _ plain: String, _ x: Double?, _ of: [String: Double]) -> String? {
            guard let x else { return nil }
            guard let top = others.compactMap({ of[$0.id] }).max() else { return "\(plain) \(fmt(x))" }
            return x >= top
                ? "\(best) in the group: \(fmt(x)) (next best \(fmt(top)))"
                : "\(plain) \(fmt(x)) (best in the group \(fmt(top)))"
        }
        let lines = [
            starred[g.best] == id && id != g.best ? "You picked it as the best shot." : nil,
            p.photo.edited ? "You edited it in Photos." : nil,
            compare("Best face quality", "Face quality", faces[id], faces),
            compare("Highest Vision aesthetics score", "Vision aesthetics score", scores[id], scores),
        ].compactMap { $0 }
        return lines.isEmpty ? nil : Why(id: id, lines: lines)
    }

    /// The Info panel's text when it has no single photo.
    public var inspectorPlaceholder: String {
        selected.count > 1 ? "\(selected.count) photos selected" : "No photo selected"
    }

    /// An arrow key: selects the photo `delta` places from the anchor (1 is next, a row is the column count).
    public func moveSelection(by delta: Int) {
        let ids = order
        guard !ids.isEmpty else { return }
        let from = anchor.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let id = ids[min(ids.count - 1, max(0, from + delta))]
        selected = [id]
        anchor = id
    }

    /// ⌥↓ / ⌥↑: selects the first photo of the next or previous section (a group in Bursts and Similar, else a month).
    public func moveSection(by delta: Int) {
        let gs = shownGroups
        guard hasSections, !gs.isEmpty else { return }
        let at = anchor.flatMap { a in gs.firstIndex { $0.photos.contains { $0.id == a } } }
        let i = at.map { min(gs.count - 1, max(0, $0 + delta)) } ?? (delta > 0 ? 0 : gs.count - 1)
        let id = gs[i].photos[0].id
        sectionJump = (gs[i].best, id)
        selected = [id]
        anchor = id
    }
    /// The last section jump: the section's key and the photo it selected. The grid scrolls that
    /// section's header to the top when the anchor lands on that photo.
    public private(set) var sectionJump: (key: String, photo: String)?
    public var canMoveSection: Bool { hasSections }

    public func clearSelection() {
        selected = []
        anchor = nil
        previewing = false
    }

    /// Drops photos that left the list (committed, or no longer a candidate).
    private func pruneSelection() {
        let ids = Set(order)
        selected.formIntersection(ids)
        if let a = anchor, !ids.contains(a) { anchor = nil }
        if selected.isEmpty { previewing = false }
    }

    // MARK: Delete

    /// Deletes every photo in the To be deleted list. macOS asks first; a cancel deletes nothing.
    public func deleteInPhotos() async {
        guard canDeleteInPhotos else { return }
        deleting = true
        status = nil
        defer { deleting = false }
        do {
            let gone = Set(try await cleanup.delete(deleted.map(\.id)))
            guard !gone.isEmpty else { return }
            committed.removeAll { gone.contains($0.id) }
            loaded.removeAll { gone.contains($0.id) }
            for id in gone {
                committedAlbum[id] = nil
                loadedAlbum[id] = nil
            }
            clearSelection()
            forgetUndo()  // a confirm's undo would bring back deleted photos
            counts = await cleanup.counts()
            deletedNotExported = await exporter?.missing(deleted.map(\.id)) ?? 0
            status =
                "Deleted \(gone.count) \(gone.count == 1 ? "photo" : "photos"). Photos keeps them in Recently Deleted for 30 days."
        } catch {
            status = "\(error)"
        }
    }

    // MARK: Confirm, Pending and Apply

    /// The state a confirm changes, for its undo.
    struct Snapshot {
        var photos: [PassPhoto], groups: [BurstGroup], decisions: [String: Decision], touched: Set<String>
        var pending: [String: Pending], unsure: [String: String]
    }

    var snapshot: Snapshot {
        Snapshot(
            photos: photos, groups: groups, decisions: decisions, touched: touched, pending: pending, unsure: unsure)
    }

    /// The pass a photo files into: the open pass, or in Unsure the pass it came from.
    func origin(_ id: String) -> String? { view.passKey ?? (view == .unsure ? unsure[id] : nil) }

    /// Moves `doomed` and `keep` to Pending, and in a pass `later` to Unsure. Nothing is written to Photos.
    /// `undoTo` is the state before the caller changed marks for this confirm (a number key).
    func send(
        _ doomed: [String], keep: [String], later: [String] = [], name: String, undoTo: Snapshot? = nil
    ) async -> Bool {
        guard canMark, !(doomed.isEmpty && keep.isEmpty && later.isEmpty) else { return false }
        let before = undoTo ?? snapshot
        for id in doomed { if let key = origin(id) { pending[id] = Pending(pass: key, keep: false) } }
        for id in keep { if let key = origin(id) { pending[id] = Pending(pass: key, keep: true) } }
        for id in doomed + keep { unsure[id] = nil }
        if let key = view.passKey { for id in later { unsure[id] = key } }
        let gone = Set(doomed + keep + later)
        photos.removeAll { gone.contains($0.id) }
        groups = groups.map { BurstGroup(photos: $0.photos.filter { !gone.contains($0.id) }, best: $0.best) }
            .filter { !$0.photos.isEmpty }
        for id in gone { decisions[id] = nil }
        touched.subtract(gone)
        status = nil
        changed(before, name: name)
        return true
    }

    /// Saves what changed since `before` and registers going back to it.
    private func changed(_ before: Snapshot, name: String) {
        saveState()
        pruneSelection()
        let grouping = !(undoManager.isUndoing || undoManager.isRedoing)
        // After an await there is no event's undo group: registering outside one raises.
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.restore(before, name: name) } }
        undoManager.setActionName(name)
        if grouping { undoManager.endUndoGrouping() }
        if grouping { undoName = name }
    }

    /// Undo and redo of a confirm or a send back: only the app's state, so it is instant.
    private func restore(_ s: Snapshot, name: String) {
        let now = snapshot
        (photos, groups, decisions, touched) = (s.photos, s.groups, s.decisions, s.touched)
        (pending, unsure) = (s.pending, s.unsure)
        changed(now, name: name)
    }

    private func saveState() {
        do {
            try savePending(pending.mapValues { ($0.pass, $0.keep) }, dir: dir)
            try saveUnsure(unsure, dir: dir)
        } catch {
            self.error = "\(error)"
        }
    }

    /// Pending and Unsure photos stay out of every pass.
    private func syncHeld() async { await cleanup.hold(Set(pending.keys).union(unsure.keys)) }

    /// Unsure's sections: one per pass, in sidebar order; photos newest first.
    func unsureGroups(_ all: [Photo]) -> [BurstGroup] {
        let byPass = Dictionary(grouping: all.filter { unsure[$0.uuid] != nil }) { unsure[$0.uuid]! }
        return Passes.all.compactMap { p in
            byPass[p.key].map {
                BurstGroup(photos: $0.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, best: p.key)
            }
        }
    }

    /// The album a pending photo goes to. `Passes.allKey` is from before All was removed.
    public func album(_ p: Pending) -> String {
        p.pass == Passes.allKey
            ? Passes.allDeleteAlbum : (p.keep ? Passes.keepAlbum(p.pass) : Passes.deleteAlbum(p.pass)) ?? p.pass
    }

    /// Not in Photos Yet, one section per album: "Bursts - Delete Me". Newest photo first.
    public var pendingGroups: [BurstGroup] {
        Dictionary(grouping: pending.keys) { album(pending[$0]!) }
            .map { album, ids in
                BurstGroup(
                    photos: ids.compactMap { library[$0] }.sorted {
                        ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
                    },
                    best: album)
            }
            .filter { !$0.photos.isEmpty }
            .sorted { $0.best < $1.best }
    }

    /// What Apply to Photos sends, per album.
    public var applyPreview: [CommitLine] {
        Dictionary(grouping: pending.values, by: album).map { CommitLine(count: $0.value.count, album: $0.key) }
            .sorted { $0.album < $1.album }
    }

    public var canApply: Bool { !pending.isEmpty && !loading && !committing }
    public var applyButtonLabel: String {
        committing ? "Applying…" : "Apply \(pending.count.formatted()) to Photos…"
    }
    /// The "Apply to Photos?" dialog is open.
    public var confirmingApply = false
    public static let sendBackLabel = "Send Back to Review"
    public var canSendBack: Bool { view == .pending && !selected.isEmpty && !committing }

    /// Pending photos the user changed their mind about: back to their pass, unmarked.
    public func sendBack() {
        guard canSendBack else { return }
        let before = snapshot
        for id in selected { pending[id] = nil }
        changed(before, name: Self.sendBackLabel)
    }

    /// Writes every pending photo into its album, one batch per pass. Not undoable: the albums are in
    /// Photos now, and nothing is deleted until Delete in Photos….
    public func apply() async {
        guard canApply else { return }
        committing = true
        status = nil
        defer { committing = false }
        let all = Dictionary(await cleanup.photos.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        var failures: [String] = []
        for (key, entries) in Dictionary(grouping: pending, by: \.value.pass).sorted(by: { $0.key < $1.key }) {
            let del = entries.filter { !$0.value.keep }.map(\.key)
            let keep = entries.filter { $0.value.keep }.map(\.key)
            do {
                let r = try await cleanup.commit(key, delete: del, keep: keep)
                let seen = Set(committed.map(\.id))
                committed = del.compactMap { all[$0] }.filter { !seen.contains($0.id) } + committed
                for id in del { committedAlbum[id] = r.album }
                added += r.added + r.kept
            } catch CleanupError.noMatchingPhotos {
                // Deleted in Photos since they were confirmed: nothing left to file.
            } catch {
                failures.append("\(error)")
                continue
            }
            for id in del + keep { pending[id] = nil }
        }
        saveState()
        forgetUndo()  // a confirm's undo can't take photos back out of the albums
        await syncHeld()
        counts = await cleanup.counts()
        deletedNotExported = await exporter?.missing(deleted.map(\.id)) ?? 0
        status =
            failures.isEmpty
            ? "Applied \(added.formatted()) \(added == 1 ? "photo" : "photos") to their albums in Photos."
            : failures.joined(separator: " ")
    }
}

/// A confirmed photo waiting for Apply to Photos: its pass and its mark.
public struct Pending: Sendable, Equatable {
    public var pass: String
    public var keep: Bool
}

extension Photo {
    var kindLabel: String {
        isMovie
            ? (screenRecording ? "Screen recording" : "Video")
            : screenshot ? "Screenshot" : live ? "Live Photo" : "Photo"
    }

    /// The tile's pill for a kind the thumbnail doesn't show: "Live" or "Screen recording".
    public var kindTag: String? { screenRecording ? "Screen recording" : live ? "Live" : nil }
}

// MARK: Sections and Confirm

extension BurstGroup {
    /// The ★ first, the rest in time order: a group's row shows it largest, and 1 is its key.
    var bestFirst: BurstGroup {
        guard let i = photos.firstIndex(where: { $0.id == best }), i > 0 else { return self }
        var ps = photos
        ps.insert(ps.remove(at: i), at: 0)
        return BurstGroup(photos: ps, best: best)
    }
}

extension ReviewModel {
    /// Bursts or Similar: one row per group.
    public var isGrouped: Bool { view.passKey.map(Passes.grouped.contains) == true }
    /// Sections to accept one at a time: groups in Bursts and Similar, months in the other passes, a pass in Unsure.
    public var hasSections: Bool { canMark }

    /// The anchor's section, or the first one to review: where Return, K and 1–9 act, and in a pass the
    /// one section on screen.
    public var currentGroup: BurstGroup? {
        let gs = shownGroups
        return anchor.flatMap { a in gs.first { $0.photos.contains { $0.id == a } } }
            ?? gs.first
    }

    /// "Burst 12 of 847" above a pass's section: where the section on screen is among those left.
    public var focusPosition: String? {
        guard inPass, let g = currentGroup else { return nil }
        let gs = shownGroups
        let unit =
            switch view.passKey {
            case "bursts": "Burst"
            case "similar": "Moment"
            default: "Month"
            }
        guard let i = gs.firstIndex(where: { $0.best == g.best }) else {
            return "\(unit) · \(gs.count.formatted()) left"
        }
        return "\(unit) \((i + 1).formatted()) of \(gs.count.formatted())"
    }

    /// The current group's ★: the user's pick, else Vision's.
    var currentStar: String? { currentGroup.map { starred[$0.best] ?? $0.best } }

    public func isCurrent(_ g: BurstGroup) -> Bool { hasSections && currentGroup?.best == g.best }
    /// The number key that picks this photo as best: its place in the current group, 1–9.
    public func keyNumber(_ id: String) -> Int? {
        guard isGrouped, let i = currentGroup?.photos.firstIndex(where: { $0.id == id }), i < 9 else { return nil }
        return i + 1
    }

    /// A section accepts what it shows: a pass files every photo, Unsure its Keep and Remove marks.
    public var canConfirm: Bool { hasSections && !loading && !committing && currentGroup != nil }
    /// Why an Accept filed nothing, in the status bar: the buttons stay enabled, so a click always answers.
    static let nothingToConfirm =
        "Nothing to accept: every photo is still Unsure. Mark them Keep (K) or Remove (⌫) first."
    private func filesSomething(_ g: BurstGroup) -> Bool {
        inPass || g.photos.contains { decisions[$0.id] != .unsure }
    }
    public static let confirmLabel = "Accept"

    /// Return, or a section's Accept button: files the section as marked, then selects the next one.
    public func confirm(_ section: BurstGroup? = nil) async {
        guard canConfirm, let g = section ?? currentGroup else { return }
        await confirm(full(g), name: Self.confirmLabel)
    }

    /// K in a pass: every photo of the current section is kept, then accepted. One undo takes back both.
    public func keepAll() async {
        guard inPass, canConfirm, let g = currentGroup.map(full) else { return }
        let before = snapshot
        for p in g.photos {
            decisions[p.id] = .keep
            touched.insert(p.id)
        }
        await confirm(g, name: Self.keepAllLabel, undoTo: before)
    }

    /// A photo's ☆, or a number key: this photo becomes its group's ★ and Keep, the rest Delete. Not confirmed:
    /// Return or the group's Accept does that.
    public func pickBest(_ id: String) {
        guard isGrouped, let g = groups.first(where: { $0.photos.contains { $0.id == id } }) else { return }
        undoManager.beginUndoGrouping()  // the ★ and the marks undo as one
        setStar(g.best, id)
        apply(
            Dictionary(
                g.photos.map { ($0.id, ($0.id == id ? Decision.keep : .delete, true)) }, uniquingKeysWith: { a, _ in a }
            ),
            name: Self.pickBestLabel)
        undoManager.endUndoGrouping()
    }

    /// A number key 1–9: picks that photo of the current group.
    public func pickBest(number n: Int) {
        guard let g = currentGroup, g.photos.indices.contains(n - 1) else { return }
        pickBest(g.photos[n - 1].id)
    }

    private func setStar(_ key: String, _ id: String?) {
        let old = starred[key]
        starred[key] = id
        undoManager.registerUndo(withTarget: self) { m in MainActor.assumeIsolated { m.setStar(key, old) } }
    }

    private var sectionUnit: String { isGrouped ? "group" : view == .unsure ? "pass" : "month" }
    /// A section's tooltips name the key only on the current section, where the key acts.
    public func confirmHelp(_ g: BurstGroup) -> String {
        "Accept this \(sectionUnit)" + (inPass ? "" : ": files its Keep and Remove marks; Unsure photos stay")
            + (isCurrent(g) ? " (Return)" : "")
    }
    public var keepAllHelp: String { "Keep every photo in this \(sectionUnit), then accept it (K)" }
    public static let pickBestLabel = "Pick as Best"
    public func pickBestHelp(_ id: String) -> String {
        "Pick as best: keep this photo, mark the rest of the group Remove" + (keyNumber(id).map { " (\($0))" } ?? "")
    }
    public var canPickBest: Bool { isGrouped && !loading && !committing }

    /// Confirming means the user looked: in a pass every photo goes to its album, Keep included, and
    /// Unsure ones to the Unsure view.
    /// `undoTo` is the state before the caller changed marks for this accept (K).
    private func confirm(_ section: BurstGroup, name: String, undoTo: Snapshot? = nil) async {
        let before = undoTo ?? snapshot
        guard filesSomething(section) else {
            (decisions, touched) = (before.decisions, before.touched)
            status = Self.nothingToConfirm
            return
        }
        let gs = shownGroups
        let at = gs.firstIndex { $0.best == section.best }
        let next = at.flatMap { $0 + 1 < gs.count ? gs[$0 + 1] : nil }
        let ids = Set(section.photos.map(\.id))
        let mine = photos.filter { ids.contains($0.id) }.map(\.id)
        let marked = { (d: Decision) in mine.filter { self.decisions[$0] == d } }
        let later = inPass ? marked(.unsure) : []
        guard await send(marked(.delete), keep: marked(.keep), later: later, name: name, undoTo: before) else {
            (decisions, touched) = (before.decisions, before.touched)
            return
        }
        if let id = next?.photos.first?.id {
            selected = [id]
            anchor = id
        }
    }

    /// The whole section: Show Only Remove hides its Keep photos, and Accept covers them too.
    private func full(_ g: BurstGroup) -> BurstGroup { groups.first { $0.best == g.best } ?? g }
}

// MARK: Month sections

extension ReviewModel {
    static let unknownMonth = "unknown"

    /// Month sections as `BurstGroup`s whose `best` is the month key ("2024-03", or "unknown" for photos
    /// without a date, last). Newest month first; photos keep the order of `photos`.
    static func monthGroups(_ photos: [Photo], timeZone: TimeZone = .current) -> [BurstGroup] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var order: [String] = []
        var byMonth: [String: [Photo]] = [:]
        for p in photos {
            let key =
                p.date.map { d in
                    let c = cal.dateComponents([.year, .month], from: d)
                    return String(format: "%04d-%02d", c.year!, c.month!)
                } ?? unknownMonth
            if byMonth[key] == nil { order.append(key) }
            byMonth[key, default: []].append(p)
        }
        order.sort { a, b in (a == unknownMonth) != (b == unknownMonth) ? b == unknownMonth : a > b }
        return order.map { BurstGroup(photos: byMonth[$0]!, best: $0) }
    }

    /// A section header: "October 2026 · 214" for a month; in Bursts and Similar
    /// "Jan 1, 2024 · keeping 1 · removing 5 similar photos", counted over the whole group.
    public func header(_ g: BurstGroup, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        if view == .pending { return "\(g.best) · \(g.photos.count.formatted(.number.locale(locale)))" }
        if view == .unsure {
            return "\(Passes.title(g.best) ?? g.best) · \(g.photos.count.formatted(.number.locale(locale)))"
        }
        if isGrouped {
            let marks = full(g).photos.map { decisions[$0.id] }
            let n = { (d: Decision) in marks.count { $0 == d } }
            let fmt = { (x: Int) in x.formatted(.number.locale(locale)) }
            return [
                g.dateLabel(locale: locale, timeZone: timeZone), "keeping \(fmt(n(.keep)))",
                n(.delete) > 0 ? "removing \(fmt(n(.delete))) similar \(n(.delete) == 1 ? "photo" : "photos")" : nil,
                n(.unsure) > 0 ? "\(fmt(n(.unsure))) unsure" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).year().month(.wide)
        let month = g.photos.compactMap(\.date).first.map { $0.formatted(style) } ?? "Unknown date"
        return "\(month) · \(g.photos.count.formatted(.number.locale(locale)))"
    }
}

// MARK: Burst headers

extension BurstGroup {
    /// "Jan 1, 2024": the date of the first shot, nil when no shot has one. Locale and time zone are
    /// parameters so tests can pin them.
    public func dateLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        return photos.compactMap(\.date).min().map { $0.formatted(style) }
    }
}

// MARK: Export

extension ReviewModel {
    /// Rereads the library's photo list, then the export's status and the To be deleted count.
    public func refreshExport() async {
        guard let exporter else { return }
        do { try await exporter.refresh() } catch { self.error = "\(error)" }
        export = await exporter.status
        deletedNotExported = await exporter.missing(deleted.map(\.id))
    }

    /// One poll tick while the export runs. A finished run rereads the list and the To be deleted count.
    public func pollExport() async {
        guard let exporter else { return }
        let wasRunning = export.running
        export = await exporter.status
        if wasRunning && !export.running { await refreshExport() }
    }

    public func setExportDestination(_ url: URL) async {
        guard let exporter else { return }
        await exporter.setDestination(url)
        await refreshExport()
    }

    /// Keeps access to the picked folder across launches and stops access to the previous one.
    public func chooseExportDestination(_ url: URL) async {
        do {
            let folder = try FolderBookmark(url)
            exportBookmark?.release()
            exportBookmark = folder
            saveExportDestination(folder, defaults: defaults)
        } catch {
            self.error = "\(error)"
            return
        }
        await setExportDestination(url)
    }

    public func startExport() async {
        guard canExport, let exporter else { return }
        await exporter.start()
        export = await exporter.status
        export.running = true  // the run's task may not have started yet; the poll corrects it
    }

    public func stopExport() async { await exporter?.stop() }

    public var canExport: Bool { export.destination != nil && export.connected && !export.running }
    public var exportButtonLabel: String { export.running ? "Stop" : "Export Now" }

    public var exportFraction: Double { export.total == 0 ? 0 : Double(export.done) / Double(export.total) }

    /// "~/Backups/Photos", or what to do when there is none.
    public var exportDestinationLabel: String {
        export.destination.map(pathLabel) ?? "No destination. Choose a folder or disk."
    }

    /// "1.2 TB free", "Not connected", or nil with no destination.
    public var exportDiskLabel: String? {
        guard export.destination != nil else { return nil }
        guard export.connected else { return "Not connected. Plug in the disk to export." }
        return export.freeBytes.map { "\($0.formatted(.byteCount(style: .file))) free" }
    }

    public func exportLastLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard export.destination != nil, export.connected else { return nil }
        let style = Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)
        return export.lastExport.map { "Last export \($0.formatted(style))" } ?? "Never exported"
    }

    /// "27,898 in export · 112 to copy".
    public var exportCountsLabel: String {
        guard export.destination != nil else { return "No destination" }
        return "\(export.exported.formatted()) in export · \(export.pending.formatted()) to copy"
    }

    /// "92 of 112 · 2024/05/IMG_4410" while running.
    public var exportProgressLabel: String? {
        guard export.running else { return nil }
        return "\(export.done.formatted()) of \(export.total.formatted())\(export.current.map { " · \($0)" } ?? "")"
    }

    /// The last run's failures, "2024/05/IMG_0001: reason", sorted; a rerun retries them.
    public var exportFailures: [String] { export.failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" } }
}

// MARK: Import

extension ImportScan {
    /// Photos and videos not in the library: the ones Import/ holds, or will after the sort.
    public var newCount: Int { rows.count { $0.status.isNew && !Self.isSkipped($0.rel, skip) } }
}

extension ReviewModel {
    public func addImportFolder(_ url: URL) async {
        if !importFolders.contains(url) {
            do {
                importBookmarks.append(try FolderBookmark(url))
                saveImportFolders(importBookmarks, defaults: defaults)
            } catch {
                self.error = "\(error)"
                return
            }
        }
        importFolder = url
        await checkImportFolder(url)
    }

    public func removeImportFolder(_ url: URL) {
        for folder in importBookmarks where folder.url == url { folder.release() }
        importBookmarks.removeAll { $0.url == url }
        importScans[url] = nil
        if importFolder == url { importFolder = importFolders.first }
        saveImportFolders(importBookmarks, defaults: defaults)
    }

    /// The folder can't be found: deleted, or its drive is unplugged. Remove it by hand.
    public func isMissing(_ url: URL) -> Bool { importBookmarks.contains { $0.url == url && $0.missing } }

    public func checkImportFolder(_ url: URL) async {
        guard let importer, importBusy == nil, importFolders.contains(url), !isMissing(url) else { return }
        importBusy = url
        importProgress = (0, 0)
        defer { importBusy = nil }
        do {
            importScans[url] = try await importer.scan(url)
        } catch {
            status = "\(error)"
        }
    }

    /// One poll tick while a check runs.
    public func pollImport() async {
        guard let importer else { return }
        importProgress = (await importer.done, await importer.total)
    }

    /// Makes the selected folder's moves, then checks it again.
    public func sortImportFolder() async {
        guard canSortImport, let url = importFolder, let scan = importScans[url] else { return }
        importBusy = url
        let failed = await Task.detached { scan.apply() }.value
        importFailures = failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        importBusy = nil
        status = "Moved \(scan.moves.count - failed.count) of \(scan.moves.count) files."
        await checkImportFolder(url)
    }

    public var importScan: ImportScan? { importFolder.flatMap { importScans[$0] } }
    public var canSortImport: Bool { importBusy == nil && !(importScan?.moves.isEmpty ?? true) }
    public var canCheckImport: Bool { importBusy == nil && importFolder.map { !isMissing($0) } ?? false }
    public var importChecking: Bool { importBusy != nil && importBusy == importFolder }

    /// "~/Pictures/Old Laptop".
    public func pathLabel(_ url: URL) -> String {
        // Under the sandbox homeDirectoryForCurrentUser is the container.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// "341 new · 12,804 in library", or "Not checked".
    public func importFolderCounts(_ url: URL) -> String {
        if isMissing(url) { return "Not found" }
        guard let s = importScans[url] else { return "Not checked" }
        let inLib = s.rows.count { $0.status.isInLibrary }
        return "\(s.newCount.formatted()) new · \(inLib.formatted()) in library"
    }

    /// "Checking 1,840 of 5,002 files…".
    public var importProgressLabel: String? {
        guard importChecking else { return nil }
        let (d, t) = importProgress
        return t == 0 ? "Reading the library…" : "Checking \(d.formatted()) of \(t.formatted()) files…"
    }

    /// Each status with files in the scan, in `ImportStatus` order: ("in library", 12804).
    public var importStatusCounts: [(status: String, count: Int)] {
        guard let s = importScan else { return [] }
        return ImportStatus.allCases.map { ($0.rawValue, s.count($0)) }.filter { $0.1 > 0 }
    }

    /// The confirmation's text: what the sort moves where.
    public var importSortPreview: String {
        guard let s = importScan else { return "" }
        var lines = ["\(s.toDone.formatted()) → Done", "\(s.toImport.formatted()) → Import"]
        if s.fromDone > 0 { lines.append("\(s.fromDone.formatted()) of them from Done: not in your library") }
        if s.toRemoved > 0 { lines.append("\(s.toRemoved.formatted()) → Removed: removed from your library since") }
        return lines.joined(separator: "\n")
    }

    public var importSummary: String {
        guard let s = importScan else { return importFolders.isEmpty ? "No folders" : "Not checked" }
        return "\(s.newCount.formatted()) new · \(s.moves.count.formatted()) to move"
    }

    /// The selected folder's Import/ folder, if it exists: what to bring into Photos.
    public var importInbox: URL? {
        guard let url = importFolder?.appending(path: "Import") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// The saved settings the app applies at launch.
public struct LaunchSettings: Sendable {
    public var ignoreAlbums: Set<String>
    public var keepAlbumPhotos = true
    public var exportFolder: FolderBookmark?
    public var showsInspector = false
    public var zoom: Int?
    public var aspectFit = false

    public init(
        ignoreAlbums: Set<String> = [], keepAlbumPhotos: Bool = true, exportFolder: FolderBookmark? = nil,
        showsInspector: Bool = false, zoom: Int? = nil, aspectFit: Bool = false
    ) {
        self.ignoreAlbums = ignoreAlbums
        self.keepAlbumPhotos = keepAlbumPhotos
        self.exportFolder = exportFolder
        self.showsInspector = showsInspector
        self.zoom = zoom
        self.aspectFit = aspectFit
    }
}

public enum LaunchResult {
    case noAccess(String)
    case failed(String)
    case loaded(ReviewModel, uuids: [String])
}

/// Authorizes, loads the library, starts Vision and builds the model on the first pass.
@MainActor
public func launch(
    library: PhotoLibrary, judge: Judge, settings: LaunchSettings, cacheDir: URL,
    dir: URL = settingsDir, defaults: UserDefaults = .standard
) async -> LaunchResult {
    let status = await library.authorize()
    guard status == "authorized" else { return .noAccess(status) }
    let cleanup = Cleanup(
        library: library, judge: judge, cacheDir: cacheDir, ignoreAlbums: settings.ignoreAlbums,
        keepAlbumPhotos: settings.keepAlbumPhotos, verdictsOff: judge.unavailableReason())
    do { try await cleanup.load() } catch { return .failed("\(error)") }
    let photos = await cleanup.photos
    print("Loaded: \(photos.count) photos, \(memoryLabel())")
    fflush(stdout)
    await cleanup.startVision(photos.filter { !$0.isMovie && !$0.screenshot })
    let model = ReviewModel(
        cleanup: cleanup, exporter: Exporter(library: library, destination: settings.exportFolder?.url),
        exportBookmark: settings.exportFolder, importer: Importer(library: library), dir: dir, defaults: defaults)
    model.showsInspector = settings.showsInspector
    model.zoom = settings.zoom ?? model.zoom
    model.aspectFit = settings.aspectFit
    await model.select(.pass(Passes.all[0].key))
    return .loaded(model, uuids: photos.map(\.uuid))
}
