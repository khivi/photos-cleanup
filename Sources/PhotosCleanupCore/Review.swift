import Foundation
import Observation

public enum ReviewView: Hashable, Sendable {
    case all
    case pass(String)  // a key from `Passes.all`
    case deleted  // photos waiting in Delete Me albums

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
    /// Bursts view: one row per burst.
    public private(set) var groups: [BurstGroup] = []
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
    public private(set) var counts: [String: Int?] = [:]
    public private(set) var loading = false
    public private(set) var committing = false
    public private(set) var status: String?
    public private(set) var error: String?
    public var verdictsOff: String? { cleanup.verdictsOff }

    /// The photos the user selected in the grid, always among `displayed`.
    public private(set) var selected: Set<String> = []
    /// Where a ⇧-click range starts and arrow keys move from.
    public private(set) var anchor: String?

    /// Marks register their undo here. The app swaps in the window's manager so ⌘Z reaches it.
    public var undoManager = UndoManager()

    private let cleanup: Cleanup
    public private(set) var verdictStatRows: [VerdictStatRow] = []

    public init(cleanup: Cleanup) { self.cleanup = cleanup }

    public var best: Set<String> { Set(groups.map(\.best)) }

    func initialDecision(_ p: PassPhoto) -> Decision {
        switch view {
        case .pass("bursts"): return best.contains(p.id) ? .keep : .delete
        case .pass(let k) where Passes.verdictKinds.contains(k):
            if let v = p.verdict, !v.keep { return .delete }
            return .keep
        case .pass: return .delete
        default: return .keep
        }
    }

    public func decision(_ uuid: String) -> Decision? { decisions[uuid] }

    /// Photos to show: the To be deleted list, or the loaded ones.
    public var displayed: [Photo] { view == .deleted ? deleted : photos.map(\.photo) }

    public var doomed: [PassPhoto] { photos.filter { decisions[$0.id] == .delete } }
    public var keepers: [PassPhoto] {
        let best = best
        return photos.filter {
            decisions[$0.id] == .keep && (touched.contains($0.id) || $0.verdict != nil || best.contains($0.id))
        }
    }
    public var canCommit: Bool { view.passKey != nil && !(doomed.isEmpty && keepers.isEmpty) }

    // MARK: Labels (what the screen shows; views only lay them out)

    public static let tabs: [(view: ReviewView, title: String, help: String)] =
        [(.all, "All", "Every photo in your library.")]
        + Passes.all.map { (.pass($0.key), $0.title, Passes.about[$0.key] ?? "") }
        + [(.deleted, "To be deleted", "Photos waiting in a Delete Me album. Delete them there in Photos.")]

    public func tabLabel(_ v: ReviewView, _ title: String) -> String {
        let n: Int? = switch v {
        case .all: counts["all"] ?? nil
        case .pass(let k): counts[k] ?? nil
        case .deleted: deleted.isEmpty ? nil : deleted.count
        }
        return n.map { "\(title) (\($0.formatted()))" } ?? title
    }

    // MARK: Sidebar

    public struct SidebarItem: Identifiable, Sendable {
        public let view: ReviewView
        public let title: String
        public let help: String
        /// The photo count; nil while unknown or at 0, so the row shows no badge.
        public let badge: Int?
        public var id: ReviewView { view }
    }

    public struct SidebarSection: Identifiable, Sendable {
        public let title: String
        public let items: [SidebarItem]
        public var id: String { title }
    }

    /// Library (All), Cleanup (the passes), Review (To be deleted), built from `tabs`.
    public var sidebar: [SidebarSection] {
        func item(_ t: (view: ReviewView, title: String, help: String)) -> SidebarItem {
            let n: Int? = switch t.view {
            case .all: counts["all"] ?? nil
            case .pass(let k): counts[k] ?? nil
            case .deleted: deleted.count
            }
            return SidebarItem(view: t.view, title: t.title, help: t.help, badge: n.flatMap { $0 > 0 ? $0 : nil })
        }
        func items(_ keep: (ReviewView) -> Bool) -> [SidebarItem] { Self.tabs.filter { keep($0.view) }.map(item) }
        return [
            SidebarSection(title: "Library", items: items { $0 == .all }),
            SidebarSection(title: "Cleanup", items: items { $0.passKey != nil }),
            SidebarSection(title: "Review", items: items { $0 == .deleted }),
        ]
    }

    public var inPass: Bool { view.passKey != nil }

    /// "N candidates · M to delete", "N photos" or "N queued for deletion".
    public var summary: String {
        if view == .deleted { return "\(deleted.count) queued for deletion" }
        if inPass { return "\(photos.count) candidates · \(doomed.count) to delete" }
        return "\(photos.count.formatted()) photos"
    }

    public var commitLabel: String {
        committing ? "Moving…" : "Commit: \(doomed.count) delete · \(keepers.count) keep"
    }

    /// Progress text and fraction while Vision or verdicts run in a pass.
    public var progressDone: Int { (progress.total > 0 ? progress.total : progress.pending) - progress.pending }
    public var progressTotal: Int { progress.total > 0 ? progress.total : progress.pending }
    public var showsProgress: Bool { inPass && !loading && progress.pending > 0 }

    public var progressError: String? {
        guard !loading, let e = progress.error else { return nil }
        return "\(view == .pass("bursts") ? "Similarity check unavailable" : "AI verdicts unavailable"): \(e)"
    }

    public var banner: String? {
        guard view == .deleted else { return status }
        let albums = Dictionary(grouping: deleted.compactMap { deletedAlbum[$0.id] }, by: { $0 })
            .sorted { $0.key < $1.key }
            .map { "“\($0.key)” (\($0.value.count))" }
        guard !albums.isEmpty else { return "Nothing is waiting in a Delete Me album." }
        return "Nothing is deleted yet. In Photos, open \(albums.joined(separator: ", ")), select all, and delete."
    }

    public var showsEmptyState: Bool { inPass && !loading && displayed.isEmpty }
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
        guard let key = view.passKey, let del = Passes.deleteAlbum(key), let keep = Passes.keepAlbum(key) else {
            return []
        }
        return [CommitLine(count: doomed.count, album: del), CommitLine(count: keepers.count, album: keep)]
            .filter { $0.count > 0 }
    }

    /// Window subtitle: "41 candidates · 12 to delete", "N photos" or "N queued for deletion".
    public var windowSubtitle: String { summary }
    public var moveButtonLabel: String { committing ? "Moving…" : "Move to Albums…" }
    public static let keepAllLabel = "Keep All"
    public static let deleteAllLabel = "Delete All"

    // MARK: Loading

    public func select(_ v: ReviewView) async {
        status = nil
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
            var prog = JobProgress()
            if let key = v.passKey {
                let r = try await cleanup.pass(key)
                (items, gs, prog) = (key == "bursts" ? Self.flat(r.groups) : r.photos, r.groups, r.progress)
            } else {
                items = await cleanup.photos.map { PassPhoto(photo: $0) }
            }
            view = v
            clearSelection()
            undoManager.removeAllActions()  // another list: the marks belong to the old one
            photos = items
            groups = gs
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
        if key == "bursts" {  // groups change as more photos are analysed: take them wholesale
            groups = r.groups
            photos = Self.flat(r.groups)
        } else {
            let fresh = Dictionary(r.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let have = Set(photos.map(\.id))
            photos = photos.map { p in fresh[p.id].map { PassPhoto(photo: p.photo, verdict: $0.verdict) } ?? p }
                + r.photos.filter { !have.contains($0.id) }
        }
        for p in photos where !touched.contains(p.id) { decisions[p.id] = initialDecision(p) }
        progress = r.progress
        pruneSelection()
    }

    public func refreshCounts() async {
        counts = await cleanup.counts()
        await loadWaiting()
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
    }

    // MARK: Deciding

    /// Marks `ids` Keep or Delete as the user's choice.
    public func mark(_ ids: some Collection<String>, _ d: Decision) {
        apply(Dictionary(ids.map { ($0, (d, true)) }, uniquingKeysWith: { a, _ in a }), name: d == .keep ? "Keep" : "Delete")
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

    /// Flips one photo.
    public func toggle(_ uuid: String) { mark([uuid], decisions[uuid] == .delete ? .keep : .delete) }

    /// Marks the selected photos; only a pass has decisions.
    public func markSelection(_ d: Decision) {
        guard inPass else { return }
        mark(selected, d)
    }

    public func setAll(_ d: Decision) {
        apply(Dictionary(photos.map { ($0.id, (d, true)) }, uniquingKeysWith: { a, _ in a }), name: d == .keep ? "Keep All" : "Delete All")
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

    public func selectAll() { selected = Set(order) }

    /// An arrow key: selects the photo `delta` places from the anchor (1 is next, a row is the column count).
    public func moveSelection(by delta: Int) {
        let ids = order
        guard !ids.isEmpty else { return }
        let from = anchor.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let id = ids[min(ids.count - 1, max(0, from + delta))]
        selected = [id]
        anchor = id
    }

    public func clearSelection() {
        selected = []
        anchor = nil
    }

    /// Drops photos that left the list (committed, or no longer a candidate).
    private func pruneSelection() {
        let ids = Set(order)
        selected.formIntersection(ids)
        if let a = anchor, !ids.contains(a) { anchor = nil }
    }

    // MARK: Commit

    public func commit() async {
        guard let key = view.passKey else { return }
        let doomed = doomed, keep = keepers.map(\.id)
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
            photos.removeAll { gone.contains($0.id) }
            groups = groups.map { BurstGroup(photos: $0.photos.filter { !gone.contains($0.id) }, best: $0.best) }
                .filter { !$0.photos.isEmpty }
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

// MARK: Verdict stats

/// One pass's agreement between the model's verdicts and the user's committed choices.
public struct VerdictStatRow: Sendable, Equatable, Identifiable {
    public var key: String
    public var title: String
    public var agree: Int
    public var total: Int
    public var id: String { key }
    /// "12 of 14 agree"
    public var label: String { "\(agree) of \(total) agree" }
}

extension ReviewModel {
    /// Reads the decisions log: one row per pass that has entries, in pass order.
    public func refreshVerdictStats() async {
        let stats = await cleanup.verdictStats()
        verdictStatRows = Passes.all.compactMap { p in
            stats[p.key].map { VerdictStatRow(key: p.key, title: p.title, agree: $0.agree, total: $0.total) }
        }
    }
}
