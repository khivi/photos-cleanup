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
}
