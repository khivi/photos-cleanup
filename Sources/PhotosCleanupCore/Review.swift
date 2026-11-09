import Foundation
import Observation

public enum ReviewView: Hashable, Sendable {
    case all
    case pass(String)  // a key from `Passes.all`
    case deleted  // photos waiting in Delete Me albums
    case export  // the backup to a folder or disk
    case importFolders  // old photo folders sorted against the library

    public var passKey: String? { if case .pass(let k) = self { k } else { nil } }
}

public enum Decision: Sendable, Equatable {
    case keep, delete
}

/// The review screen's state over a `Cleanup`: the current view, per-photo decisions, commits and
/// the "To be deleted" list. No timers: the view calls `refresh()` while `progress.pending > 0`.
@MainActor @Observable
public final class ReviewModel {
    public private(set) var view = ReviewView.all
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

    private let cleanup: Cleanup
    private let exporter: Exporter?
    private let importer: Importer?
    private let dir: URL
    private let defaults: UserDefaults
    /// Months marked Done in All, by "2024-03" key, with the photo count when marked.
    public private(set) var reviewedMonths: [String: Int]

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
        reviewedMonths = loadReviewedMonths(dir: dir)
        importBookmarks = loadImportFolders(defaults: defaults)
        importFolder = importFolders.first
    }

    public var best: Set<String> { Set(groups.map(\.best)) }

    /// Show only photos marked Delete (in All, also those already in a Delete Me album). Off on every view change.
    public var onlyDelete = false {
        didSet { pruneSelection() }
    }
    public static let onlyDeleteLabel = "Show Only Delete"
    public var canFilter: Bool { canMark }

    private func shown(_ id: String) -> Bool {
        !onlyDelete || decisions[id] == .delete || (view == .all && deletedAlbum[id] != nil)
    }
    /// `photos` under the filter: what the grid shows.
    public var shownPhotos: [PassPhoto] { photos.filter { shown($0.id) } }
    /// `groups` under the filter, empty groups dropped.
    public var shownGroups: [BurstGroup] {
        guard onlyDelete else { return groups }
        return groups.map { BurstGroup(photos: $0.photos.filter { shown($0.id) }, best: $0.best) }
            .filter { !$0.photos.isEmpty }
    }

    /// Vision's pick of a group, shown with a star in the grouped passes only.
    public func isBest(_ id: String) -> Bool { view.passKey.map(Passes.grouped.contains) == true && best.contains(id) }

    func initialDecision(_ p: PassPhoto) -> Decision {
        switch view {
        case .pass(let k) where Passes.grouped.contains(k):
            return best.contains(p.id) || p.photo.edited ? .keep : .delete
        case .pass(let k) where Passes.verdictKinds.contains(k):
            if let v = p.verdict, !v.keep { return .delete }
            return .keep
        case .pass("videos"): return p.photo.duration < Passes.accidentalVideoMax ? .delete : .keep
        case .pass: return p.photo.edited ? .keep : .delete  // Low Quality: edits are kept
        default: return .keep
        }
    }

    public func decision(_ uuid: String) -> Decision? { decisions[uuid] }

    /// Photos to show: the To be deleted list, or the loaded ones.
    public var displayed: [Photo] { view == .deleted ? deleted : shownPhotos.map(\.photo) }

    public var doomed: [PassPhoto] { photos.filter { decisions[$0.id] == .delete } }
    public var keepers: [PassPhoto] {
        let best = best
        let editsKeep = view.passKey.map { $0 == "low-quality" || Passes.grouped.contains($0) } ?? false
        return photos.filter {
            decisions[$0.id] == .keep
                && (touched.contains($0.id) || $0.verdict != nil || best.contains($0.id)
                    || editsKeep && $0.photo.edited)
        }
    }
    /// The "Move to Albums?" dialog is open. The toolbar button and Photo > Move to Albums both set it.
    public var confirmingMove = false
    /// Move to Albums can run now: the toolbar button and the menu item share this.
    public var canMove: Bool { !loading && !committing && canCommit }
    /// Keep All and Delete All can run now.
    public var canSetAll: Bool { inPass && !loading && !photos.isEmpty }
    public var canCommit: Bool { (inPass || view == .all) && !(doomed.isEmpty && keepers.isEmpty) }
    /// K, ⌫ and the Inspector's picker work: in a pass, and in All (where Keep clears a mark).
    public var canMark: Bool { inPass || view == .all }

    // MARK: Labels (what the screen shows; views only lay them out)

    public static let tabs: [(view: ReviewView, title: String, help: String)] =
        [
            (
                .all, Passes.allTitle,
                "Every photo in your library. Mark photos Delete to move them to “\(Passes.allDeleteAlbum)”."
            )
        ]
        + Passes.all.map { (.pass($0.key), $0.title, Passes.about[$0.key] ?? "") }
        + [
            (.deleted, "To be deleted", "Photos waiting in a Delete Me album. Delete them there in Photos."),
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
        .all: "photo.on.rectangle.angled", .pass("screenshots"): "camera.viewfinder",
        .pass("paperwork"): "doc.text", .pass("bursts"): "square.stack.3d.down.right",
        .pass("similar"): "square.on.square", .pass("low-quality"): "camera.metering.unknown",
        .pass("videos"): "video", .deleted: "trash", .export: "square.and.arrow.up",
        .importFolders: "square.and.arrow.down",
    ]

    public struct SidebarItem: Identifiable, Sendable {
        public let view: ReviewView
        public let title: String
        public let help: String
        /// The SF Symbol before the title, as Photos' own sidebar has.
        public let icon: String
        /// The photo count: nil while unknown. A pass or All shows 0; the other rows show no badge at 0.
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

    /// Library (All), Cleanup (the passes), Review (To be deleted), Transfer (Export, Import), built from `tabs`.
    public var sidebar: [SidebarSection] {
        func item(_ t: (view: ReviewView, title: String, help: String)) -> SidebarItem {
            let n: Int? =
                switch t.view {
                case .all: counts["all"] ?? nil
                case .pass(let k): counts[k] ?? nil
                case .deleted: deleted.count
                case .export: export.destination == nil ? nil : export.pending
                case .importFolders: importScans.values.map(\.newCount).reduce(0, +)
                }
            // A pass waiting on a job shows how far it is: Vision first, then the verdicts. One per row.
            let job: JobProgress? = t.view.passKey.flatMap { k in
                if Self.visionPasses.contains(k) && n == nil && vision.pending > 0 { return vision }
                return verdictPasses.contains(k) && verdictJob.pending > 0 ? verdictJob : nil
            }
            let showsZero = t.view == .all || t.view.passKey != nil
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
            SidebarSection(title: "Library", items: items { $0 == .all }),
            SidebarSection(title: "Cleanup", items: items { $0.passKey != nil }),
            SidebarSection(title: "Review", items: items { $0 == .deleted }),
            SidebarSection(title: "Transfer", items: items { $0 == .export || $0 == .importFolders }),
        ]
    }

    public var inPass: Bool { view.passKey != nil }

    /// "N candidates · M to delete", "N photos" or "N queued for deletion".
    public var summary: String {
        if view == .deleted { return "\(deleted.count.formatted()) queued for deletion" }
        if view == .export { return exportCountsLabel }
        if view == .importFolders { return importSummary }
        if inPass {
            return
                "\(photos.count.formatted()) \(photos.count == 1 ? "candidate" : "candidates") · \(doomed.count.formatted()) to delete"
        }
        let n = "\(photos.count.formatted()) \(photos.count == 1 ? "photo" : "photos")"
        return doomed.isEmpty ? n : "\(n) · \(doomed.count.formatted()) to delete"
    }

    /// Passes whose photos depend on the Vision analysis.
    static let visionPasses: Set<String> = ["paperwork", "bursts", "similar", "low-quality"]

    /// A pass's explanation, then which photos it never suggests.
    public func passNote(_ key: String) -> String {
        let spared = cleanup.keepAlbumPhotos ? "Favorites and photos in your albums are" : "Favorites are"
        return "\(Passes.about[key] ?? "") \(spared) never suggested."
    }

    /// The line above a pass's grid.
    public var passCaption: String? { view.passKey.map(passNote) }

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

    public var showsEmptyState: Bool { (inPass || onlyDelete) && !loading && displayed.isEmpty }
    public var emptyStateLabel: String { onlyDelete ? "Nothing marked Delete." : Self.emptyState }
    public static let emptyState = "Nothing left to review. Photos already filed in this pass’s albums are hidden."

    // MARK: Commit preview (Phase 5 labels)

    /// One album `commit()` will fill, and how many photos go in.
    public struct CommitLine: Sendable, Equatable {
        public var count: Int
        public var album: String
        /// "12 → Bursts - Delete Me"
        public var label: String { "\(count) → \(album)" }
    }

    /// Exactly what `commit()` sends: `doomed` to the Delete Me album, `keepers` to the Keep album.
    public var commitPreview: [CommitLine] {
        if view == .all { return doomed.isEmpty ? [] : [CommitLine(count: doomed.count, album: Passes.allDeleteAlbum)] }
        guard let key = view.passKey, let del = Passes.deleteAlbum(key), let keep = Passes.keepAlbum(key) else {
            return []
        }
        return [CommitLine(count: doomed.count, album: del), CommitLine(count: keepers.count, album: keep)]
            .filter { $0.count > 0 }
    }

    /// Window title: the sidebar item's title.
    public var windowTitle: String { Self.tabs.first { $0.view == view }?.title ?? "" }
    /// Window subtitle: "41 candidates · 12 to delete", "N photos" or "N queued for deletion".
    public var windowSubtitle: String { loading ? "Loading…" : summary }
    public var deleteInPhotosLabel: String { deleting ? "Deleting…" : "Delete in Photos…" }
    /// Delete in Photos can run now: the To be deleted view, not empty.
    public var canDeleteInPhotos: Bool { view == .deleted && !loading && !deleting && !deleted.isEmpty }
    public var moveButtonLabel: String { committing ? "Moving…" : "Move to Albums…" }
    public var inspectorToggleLabel: String { showsInspector ? "Hide Info" : "Show Info" }
    public static let keepAllLabel = "Keep All"
    public static let deleteAllLabel = "Delete All"

    // MARK: Loading

    public func select(_ v: ReviewView) async {
        status = nil
        previewing = false
        onlyDelete = false
        if v == .export || v == .importFolders {
            view = v
            clearSelection()
            undoManager.removeAllActions()
            if v == .export { await refreshExport() }
            return
        }
        if v == .deleted {
            await loadWaiting()
            view = v
            clearSelection()
            undoManager.removeAllActions()
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
                (items, gs, sc, fc, prog) = (
                    Passes.grouped.contains(key) ? Self.flat(r.groups) : r.photos, r.groups, r.scores, r.faces,
                    r.progress
                )
            } else {
                let all = await cleanup.photos
                gs = Self.monthGroups(all)
                items = Self.flat(gs)
            }
            view = v
            clearSelection()
            undoManager.removeAllActions()  // another list: the marks belong to the old one
            photos = items
            groups = gs
            scores = sc
            faces = fc
            progress = prog
            decisions = [:]
            touched = []
            if v != .all { for p in items { decisions[p.id] = initialDecision(p) } }
        } catch {
            self.error = "\(error)"
        }
    }

    static func flat(_ groups: [BurstGroup]) -> [PassPhoto] {
        groups.flatMap { $0.photos.map { PassPhoto(photo: $0) } }
    }

    /// One poll tick while Vision or verdicts run: new candidates merge in, touched choices stay.
    public func refresh() async {
        guard let key = view.passKey, let r = try? await cleanup.pass(key), view.passKey == key else { return }
        scores = r.scores
        faces = r.faces
        if Passes.grouped.contains(key) {  // groups change as more photos are analysed: take them wholesale
            groups = r.groups
            photos = Self.flat(r.groups)
        } else {
            let fresh = Dictionary(r.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let have = Set(photos.map(\.id))
            photos =
                photos.map { p in fresh[p.id].map { PassPhoto(photo: p.photo, verdict: $0.verdict) } ?? p }
                + r.photos.filter { !have.contains($0.id) }
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
        counts = await cleanup.counts()
        vision = await cleanup.visionStatus()
        (verdictJob, verdictPasses) = await cleanup.verdictStatus()
    }

    /// Read once per launch; photos deleted in Photos since then drop out on the next launch.
    private func loadWaiting() async {
        let all = await cleanup.photos
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

    /// Marks `ids` Keep or Delete as the user's choice. In All, Keep clears the mark: photos there are unmarked or Delete.
    public func mark(_ ids: some Collection<String>, _ d: Decision) {
        let inAll = view == .all
        apply(
            Dictionary(
                ids.map { ($0, (inAll && d == .keep ? nil : d, !inAll || d == .delete)) },
                uniquingKeysWith: { a, _ in a }),
            name: d == .keep ? "Keep" : "Delete")
    }

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
    }

    /// Marks the selected photos; only a pass and All have marks. One selected photo: moves on to the next.
    public func markSelection(_ d: Decision) {
        guard canMark else { return }
        let one = selected.count == 1
        let before = order
        let at = anchor.flatMap { before.firstIndex(of: $0) }
        mark(selected, d)
        guard one, let at else { return pruneSelection() }
        let ids = order
        if let a = anchor, ids.contains(a) { return moveSelection(by: 1) }
        // The filter hid the photo: select the one that took its place.
        guard !ids.isEmpty else { return clearSelection() }
        selected = [ids[min(at, ids.count - 1)]]
        anchor = ids[min(at, ids.count - 1)]
    }

    public func setAll(_ d: Decision) {
        guard inPass else { return }  // marking the whole library isn't useful
        apply(
            Dictionary(photos.map { ($0.id, (d, true)) }, uniquingKeysWith: { a, _ in a }),
            name: d == .keep ? "Keep All" : "Delete All")
    }

    // MARK: Selection

    private var order: [String] { displayed.map(\.id) }

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
        let badge: String? = view == .deleted ? "✗ Delete Me" : decision(id).map { $0 == .keep ? "✓ Keep" : "✗ Delete" }
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
        if view == .all {
            if decisions[id] == .delete { target = Passes.allDeleteAlbum }
        } else if let key = view.passKey, let d = decisions[id] {
            if d == .delete {
                target = Passes.deleteAlbum(key)
            } else if keepers.contains(where: { $0.id == id }) {
                target = Passes.keepAlbum(key)
            }
        }
        return Info(
            id: id, date: Self.dateLabel(p.photo, locale: locale, timeZone: timeZone), kind: p.photo.kindLabel,
            verdict: p.verdict.map { "\($0.kind): \($0.reason)" }, score: scoreLine(id),
            albums: p.photo.albums.isEmpty
                ? "In no album"
                : "In \(p.photo.albums.count == 1 ? "album" : "albums"): \(p.photo.albums.sorted().joined(separator: ", "))",
            target: target.map { "→ \($0)" }, decision: canMark ? decisions[id] ?? .keep : nil)
    }

    static func dateLabel(_ p: Photo, locale: Locale, timeZone: TimeZone) -> String {
        let style = Date.FormatStyle(date: .long, time: .shortened, locale: locale, timeZone: timeZone)
        return p.date.map { $0.formatted(style) } ?? "Unknown date"
    }

    /// What VoiceOver reads for a grid cell: "Video, 0:05, May 3, 2014 at 9:00 AM, marked Delete, ★ best pick, junk: blurry".
    public func accessibilityLabel(_ p: PassPhoto, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let mark =
            decision(p.id).map { "marked \($0 == .keep ? "Keep" : "Delete")" }
            ?? (view == .deleted || deletedAlbum[p.id] != nil ? "in Delete Me" : nil)
        return [
            p.photo.kindLabel, p.photo.durationLabel, Self.dateLabel(p.photo, locale: locale, timeZone: timeZone), mark,
            isBest(p.id) ? "★ best pick" : nil, p.verdict.map { "\($0.kind): \($0.reason)" },
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

    /// ⌥↓ / ⌥↑: selects the first photo of the next or previous section (a month in All, a group in a grouped pass).
    public func moveSection(by delta: Int) {
        let gs = shownGroups
        guard view == .all || view.passKey.map(Passes.grouped.contains) == true, !gs.isEmpty else { return }
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
    public var canMoveSection: Bool { view == .all || view.passKey.map(Passes.grouped.contains) == true }

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
            counts = await cleanup.counts()
            deletedNotExported = await exporter?.missing(deleted.map(\.id)) ?? 0
            status =
                "Deleted \(gone.count) \(gone.count == 1 ? "photo" : "photos"). Photos keeps them in Recently Deleted for 30 days."
        } catch {
            status = "\(error)"
        }
    }

    // MARK: Commit

    public func commit() async {
        guard let key = view.passKey ?? (view == .all ? Passes.allKey : nil) else { return }
        let doomed = doomed
        let keep = keepers.map(\.id)
        if doomed.isEmpty && keep.isEmpty { return }
        committing = true
        status = nil
        defer { committing = false }
        do {
            let r = try await cleanup.commit(key, delete: doomed.map(\.id), keep: keep)
            let gone = Set(doomed.map(\.id) + keep)
            let seen = Set(committed.map(\.id))
            committed = doomed.map(\.photo).filter { !seen.contains($0.id) } + committed
            for p in doomed { committedAlbum[p.id] = r.album }
            if inPass {  // All keeps them, badged Delete Me
                photos.removeAll { gone.contains($0.id) }
                groups = groups.map { BurstGroup(photos: $0.photos.filter { !gone.contains($0.id) }, best: $0.best) }
                    .filter { !$0.photos.isEmpty }
            }
            for id in gone { decisions[id] = nil }
            undoManager.removeAllActions()
            touched.subtract(gone)
            pruneSelection()
            var parts: [String] = []
            if r.added > 0 { parts.append("\(r.added) to “\(r.album)”") }
            if r.kept > 0 { parts.append("\(r.kept) to “\(r.keepAlbum)”") }
            status = "Moved \(parts.joined(separator: ", "))."
        } catch {
            status = "\(error)"
        }
    }
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

// MARK: Month sections in All

extension ReviewModel {
    static let unknownMonth = "unknown"

    /// All's sections as `BurstGroup`s whose `best` is the month key ("2024-03", or "unknown" for photos
    /// without a date, last). Months and photos keep the order of `photos`.
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
        order.sort { ($0 == unknownMonth ? 1 : 0) < ($1 == unknownMonth ? 1 : 0) }  // stable: keeps the rest in place
        return order.map { BurstGroup(photos: byMonth[$0]!, best: $0) }
    }

    /// A section header: "October 2026 · 214" in All, the burst's date and count in Bursts.
    public func header(_ g: BurstGroup, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard view == .all else { return g.headerLabel(locale: locale, timeZone: timeZone) }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).year().month(.wide)
        let month = g.photos.compactMap(\.date).first.map { $0.formatted(style) } ?? "Unknown date"
        return "\(month) · \(g.photos.count.formatted(.number.locale(locale)))"
    }

    /// Marked Done, and not grown since.
    public func isDone(_ g: BurstGroup) -> Bool { reviewedMonths[g.best].map { g.photos.count <= $0 } ?? false }

    public func toggleDone(_ g: BurstGroup) {
        if isDone(g) { reviewedMonths[g.best] = nil } else { reviewedMonths[g.best] = g.photos.count }
        do { try saveReviewedMonths(reviewedMonths, dir: dir) } catch { self.error = "\(error)" }
    }
}

// MARK: Burst headers

extension BurstGroup {
    /// "Jan 1, 2024 · 3 photos": the date of the first shot and the count. The date is left out
    /// when no shot has one. Locale and time zone are parameters so tests can pin them.
    public func headerLabel(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let count = "\(photos.count) \(photos.count == 1 ? "photo" : "photos")"
        guard let first = photos.compactMap(\.date).min() else { return count }
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
        return "\(first.formatted(style)) · \(count)"
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

/// Authorizes, loads the library, starts Vision and builds the model on the All view.
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
    await model.select(.all)
    return .loaded(model, uuids: photos.map(\.uuid))
}
