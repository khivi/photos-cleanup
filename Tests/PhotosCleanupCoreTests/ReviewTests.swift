import Foundation
import Testing

@testable import PhotosCleanupCore

private func shots(_ ids: String...) -> [Photo] { ids.map { Photo(uuid: $0, screenshot: true) } }
private let keepV = Verdict(keep: true, kind: "receipt", reason: "r")
private let dropV = Verdict(keep: false, kind: "junk", reason: "r")

@MainActor
@Suite struct ReviewTests {
    @Test func initialDecisionsPerPass() async throws {
        // Screenshots: delete only on a not-keep verdict; unjudged keeps.
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["a": dropV, "b": keepV],
                                           judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        #expect(m.decisions == ["a": .delete, "b": .keep, "c": .keep])

        // Bursts: best keeps, rest delete.
        let burst = dated(["x": 0, "y": 1, "z": 2])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": V(0.1), "y": V(0.9), "z": V(0.2)])
        let m2 = ReviewModel(cleanup: c2)
        await m2.select(.pass("bursts"))
        #expect(m2.decisions == ["x": .delete, "y": .keep, "z": .delete])

        // Low quality: everything starts delete.
        let (c3, _) = try await makeCleanup([Photo(uuid: "q")], vision: ["q": V(-0.9)])
        let m3 = ReviewModel(cleanup: c3)
        await m3.select(.pass("low-quality"))
        #expect(m3.decisions == ["q": .delete])

        // All: no decisions.
        await m3.select(.all)
        #expect(m3.decisions.isEmpty && m3.photos.count == 1)
    }

    @Test func toggleAndSetAll() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        m.toggle("a")
        #expect(m.decisions["a"] == .delete && m.touched == ["a"])
        m.setAll(.keep)
        #expect(m.decisions == ["a": .keep, "b": .keep] && m.touched == ["a", "b"])
    }

    @Test func keepersRule() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["a": keepV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        // a has a verdict, b is untouched without one (not sent), c is touched twice back to keep.
        m.toggle("c"); m.toggle("c")
        #expect(Set(m.keepers.map(\.id)) == ["a", "c"])
        #expect(m.doomed.isEmpty)

        let burst = dated(["x": 0, "y": 1])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": V(0.1), "y": V(0.9)])
        let m2 = ReviewModel(cleanup: c2)
        await m2.select(.pass("bursts"))
        #expect(m2.keepers.map(\.id) == ["y"] && m2.doomed.map(\.id) == ["x"])
    }

    @Test func refreshKeepsTouchedAndFollowsVerdicts() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        #expect(m.decisions == ["a": .keep, "b": .keep])
        m.toggle("a")  // user: delete
        await c.recordVerdict("a", keepV)
        await c.recordVerdict("b", dropV)
        await m.refresh()
        #expect(m.decisions["a"] == .delete)  // touched stays
        #expect(m.decisions["b"] == .delete)  // untouched follows the verdict
        #expect(m.photos[0].verdict == keepV)
    }

    @Test func refreshAppendsNewCandidates() async throws {
        let ps = [Photo(uuid: "a"), Photo(uuid: "b")]
        let lib = FakeLibrary(ps, vision: ["a": V(-0.9), "b": V(-0.8)])
        let (c, _) = try await makeCleanup(ps, vision: ["a": V(-0.9)], library: lib)
        lib.gate.close()  // b stays unanalysed during select
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("low-quality"))
        #expect(m.photos.map(\.id) == ["a"] && m.progress.pending == 1)
        m.toggle("a")  // keep
        lib.gate.open()
        await settle(c)
        await m.refresh()
        #expect(m.photos.map(\.id) == ["a", "b"])
        #expect(m.decisions == ["a": .keep, "b": .delete])
        #expect(m.progress.pending == 0)
    }

    @Test func commitFilesAndUpdatesState() async throws {
        let (c, lib) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["b": keepV, "a": dropV],
                                             judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        await m.commit()
        let adds = lib.adds.withLock { $0 }
        #expect(adds.map(\.album) == ["Screenshots - Delete Me", "Screenshots - Keep"])
        #expect(adds[0].uuids == ["a"] && adds[1].uuids == ["b"])  // c: untouched, no verdict
        #expect(m.photos.map(\.id) == ["c"])
        #expect(m.deleted.map(\.id) == ["a"])
        #expect(m.decisions.keys.sorted() == ["c"])
        #expect(m.status == "Moved 1 to “Screenshots - Delete Me”, 1 to “Screenshots - Keep”.")
        #expect(!m.committing)
        await m.select(.deleted)
        #expect(m.displayed.map(\.id) == ["a"])
    }

    @Test func commitErrorSetsStatus() async throws {
        let lib = FakeLibrary(shots("a"), status: "denied")
        let (c, _) = try await makeCleanup([], judge: FakeJudge(off: "off"), library: lib)
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        m.toggle("a")
        await m.commit()
        #expect(m.status == "\(CleanupError.accessDenied)")
        #expect(m.photos.map(\.id) == ["a"] && m.deleted.isEmpty)
    }

    @Test func labels() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        #expect(ReviewModel.tabs.map(\.title) == ["All", "Screenshots", "Paperwork", "Bursts", "Low Quality", "To be deleted"])
        await m.refreshCounts()
        await m.select(.all)
        #expect(m.summary == "2 photos" && m.tabLabel(.all, "All") == "All (2)")
        #expect(m.tabLabel(.deleted, "To be deleted") == "To be deleted")
        await m.select(.pass("screenshots"))
        #expect(m.summary == "2 candidates · 1 to delete")
        #expect(m.commitLabel == "Commit: 1 delete · 0 keep")
        #expect(m.banner == nil && !m.showsEmptyState)
        await m.commit()
        #expect(m.tabLabel(.deleted, "To be deleted") == "To be deleted (1)")
        #expect(m.banner == m.status && m.status?.hasPrefix("Moved") == true)
        m.setAll(.delete)
        await m.commit()
        #expect(m.showsEmptyState)
        await m.select(.deleted)
        #expect(m.summary == "2 queued for deletion" && m.banner?.hasPrefix("Nothing is deleted yet") == true)
        #expect(m.banner?.contains("“Screenshots - Delete Me” (2)") == true)
        #expect("\(CleanupError.accessDenied)".hasPrefix("Photos access not granted"))
    }

    @Test func deletedListSurvivesRestart() async throws {
        let lib = [
            Photo(uuid: "s", screenshot: true, albums: ["Screenshots - Delete Me"]),
            Photo(uuid: "u", albums: ["Utility - Delete Me"]),
            Photo(uuid: "k", albums: ["Screenshots - Keep"]),
            Photo(uuid: "r", albums: ["Low Quality - Review Me", "Utility - Keep"]),
            Photo(uuid: "n", screenshot: true),
        ]
        let (c, _) = try await makeCleanup(lib, judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.refreshCounts()
        #expect(m.tabLabel(.deleted, "To be deleted") == "To be deleted (2)")
        await m.select(.deleted)
        #expect(Set(m.displayed.map(\.id)) == ["s", "u"])
        #expect(m.deletedAlbum == ["s": "Screenshots - Delete Me", "u": "Utility - Delete Me"])
        #expect(m.banner?.contains("“Screenshots - Delete Me” (1), “Utility - Delete Me” (1)") == true)

        // A session commit of an already-listed photo does not duplicate it.
        await m.select(.pass("screenshots"))
        m.setAll(.delete)
        await m.commit()
        await m.select(.deleted)
        #expect(m.deleted.map(\.id).sorted() == ["n", "s", "u"])
        #expect(m.deletedAlbum["n"] == "Screenshots - Delete Me")
    }
}

@MainActor
@Suite struct CommitPreviewTests {
    @Test func previewMatchesWhatCommitSends() async throws {
        let burst = dated(["x": 0, "y": 1, "z": 2])
        let (c, lib) = try await makeCleanup(burst, vision: ["x": V(0.1), "y": V(0.9), "z": V(0.2)])
        let m = ReviewModel(cleanup: c)
        #expect(m.commitPreview.isEmpty)
        await m.select(.pass("bursts"))
        #expect(m.commitPreview.map(\.label) == ["2 → Bursts - Delete Me", "1 → Bursts - Keep"])
        await m.commit()
        let sent = lib.adds.withLock { $0 }
        #expect(sent.map(\.album) == ["Bursts - Delete Me", "Bursts - Keep"])
        #expect(sent.map(\.uuids.count) == [2, 1])
        #expect(m.commitPreview.isEmpty)
    }

    @Test func emptySideIsOmittedAndLabels() async throws {
        let (c, _) = try await makeCleanup([Photo(uuid: "a", screenshot: true)], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        #expect(m.commitPreview.isEmpty)  // unjudged, untouched: nothing is sent
        #expect(m.windowSubtitle == "1 candidates · 0 to delete")
        m.setAll(.delete)
        #expect(m.commitPreview == [.init(count: 1, album: "Screenshots - Delete Me")])
        #expect(m.moveButtonLabel == "Move to Albums…")
        #expect(ReviewModel.keepAllLabel == "Keep All" && ReviewModel.deleteAllLabel == "Delete All")
    }
}

@Suite struct BurstHeaderTests {
    let us = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!

    @Test func dateAndCount() {
        let g = BurstGroup(photos: dated(["b": 60, "a": 0, "c": 120]), best: "a")
        #expect(g.headerLabel(locale: us, timeZone: utc) == "Jan 1, 2024 · 3 photos")
    }

    @Test func timeZoneShiftsTheDay() {
        let g = BurstGroup(photos: dated(["a": 0, "b": 1]), best: "a")
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(g.headerLabel(locale: us, timeZone: la) == "Dec 31, 2023 · 2 photos")
    }

    @Test func undatedAndSingular() {
        #expect(BurstGroup(photos: [Photo(uuid: "a")], best: "a").headerLabel(locale: us, timeZone: utc) == "1 photo")
    }
}
