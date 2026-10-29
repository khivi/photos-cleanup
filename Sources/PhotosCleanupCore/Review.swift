import Foundation
import Observation

public enum ReviewView: Hashable, Sendable {
    case all
    case pass(String)  // a key from `Passes.all`
    case deleted  // this session's list; nothing to load

    public var passKey: String? { if case .pass(let k) = self { k } else { nil } }
}

public enum Decision: Sendable, Equatable {
    case keep, delete
}

/// The review screen's state over a `Cleanup`: the current view, per-photo decisions, commits and
/// the session's "To be deleted" list. No timers: the view calls `refresh()` while `progress.pending > 0`.
@MainActor @Observable
public final class ReviewModel {
    public private(set) var view = ReviewView.all
    public private(set) var photos: [PassPhoto] = []
    /// Bursts view: one row per burst.
    public private(set) var groups: [BurstGroup] = []
    public private(set) var decisions: [String: Decision] = [:]
    /// Decided explicitly by the user.
    public private(set) var touched: Set<String> = []
    public private(set) var deleted: [Photo] = []
    public private(set) var progress = JobProgress()
    public private(set) var counts: [String: Int?] = [:]
    public private(set) var loading = false
    public private(set) var committing = false
    public private(set) var status: String?
    public private(set) var error: String?
    public var verdictsOff: String? { cleanup.verdictsOff }

    private let cleanup: Cleanup

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

    /// Photos to show: this session's deleted list, or the loaded ones.
    public var displayed: [Photo] { view == .deleted ? deleted : photos.map(\.photo) }

    public var doomed: [PassPhoto] { photos.filter { decisions[$0.id] == .delete } }
    public var keepers: [PassPhoto] {
        let best = best
        return photos.filter {
            decisions[$0.id] == .keep && (touched.contains($0.id) || $0.verdict != nil || best.contains($0.id))
        }
    }
    public var canCommit: Bool { view.passKey != nil && !(doomed.isEmpty && keepers.isEmpty) }

    // MARK: Loading

    public func select(_ v: ReviewView) async {
        status = nil
        if v == .deleted {
            view = v
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
    }

    public func refreshCounts() async { counts = await cleanup.counts() }

    // MARK: Deciding

    public func toggle(_ uuid: String) {
        touched.insert(uuid)
        decisions[uuid] = decisions[uuid] == .delete ? .keep : .delete
    }

    public func setAll(_ d: Decision) {
        decisions = Dictionary(photos.map { ($0.id, d) }, uniquingKeysWith: { a, _ in a })
        touched = Set(photos.map(\.id))
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
            let seen = Set(deleted.map(\.id))
            deleted = doomed.map(\.photo).filter { !seen.contains($0.id) } + deleted
            photos.removeAll { gone.contains($0.id) }
            groups = groups.map { BurstGroup(photos: $0.photos.filter { !gone.contains($0.id) }, best: $0.best) }
                .filter { !$0.photos.isEmpty }
            for id in gone { decisions[id] = nil }
            touched.subtract(gone)
            var parts: [String] = []
            if r.added > 0 { parts.append("\(r.added) to “\(r.album)”") }
            if r.kept > 0 { parts.append("\(r.kept) to “\(r.keepAlbum)”") }
            status = "Moved \(parts.joined(separator: ", "))."
        } catch {
            status = "\(error)"
        }
    }
}
