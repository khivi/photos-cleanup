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
        let (c, _) = try await makeCleanup(
            shots("a", "b", "c"), verdicts: ["a": dropV, "b": keepV],
            judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        #expect(m.decisions == ["a": .delete, "b": .keep, "c": .keep])

        // Bursts: best keeps, rest delete.
        let burst = dated(["x": 0, "y": 1, "z": 2])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2)])
        let m2 = ReviewModel(cleanup: c2)
        await m2.select(.pass("bursts"))
        #expect(m2.decisions == ["x": .delete, "y": .keep, "z": .delete])
        #expect(["x", "y", "z"].map(m2.isBest) == [false, true, false])
        await m2.select(.all)
        #expect(!m2.isBest("y"))  // the star is a Bursts-view mark

        // Low quality: everything starts delete.
        let (c3, _) = try await makeCleanup([Photo(uuid: "q")], vision: ["q": vr(-0.9)])
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
        m.mark(["a"], .delete)
        #expect(m.decisions["a"] == .delete && m.touched == ["a"])
        m.setAll(.keep)
        #expect(m.decisions == ["a": .keep, "b": .keep] && m.touched == ["a", "b"])
    }

    @Test func keepersRule() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["a": keepV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        // a has a verdict, b is untouched without one (not sent), c is touched twice back to keep.
        m.mark(["c"], .delete)
        m.mark(["c"], .keep)
        #expect(Set(m.keepers.map(\.id)) == ["a", "c"])
        #expect(m.doomed.isEmpty)

        let burst = dated(["x": 0, "y": 1])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9)])
        let m2 = ReviewModel(cleanup: c2)
        await m2.select(.pass("bursts"))
        #expect(m2.keepers.map(\.id) == ["y"] && m2.doomed.map(\.id) == ["x"])
    }

    @Test func refreshKeepsTouchedAndFollowsVerdicts() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        #expect(m.decisions == ["a": .keep, "b": .keep])
        m.mark(["a"], .delete)  // user: delete
        await c.recordVerdict("a", keepV)
        await c.recordVerdict("b", dropV)
        await m.refresh()
        #expect(m.decisions["a"] == .delete)  // touched stays
        #expect(m.decisions["b"] == .delete)  // untouched follows the verdict
        #expect(m.photos[0].verdict == keepV)
    }

    @Test func refreshAppendsNewCandidates() async throws {
        let ps = [Photo(uuid: "a"), Photo(uuid: "b")]
        let lib = FakeLibrary(ps, vision: ["a": vr(-0.9), "b": vr(-0.8)])
        let (c, _) = try await makeCleanup(ps, vision: ["a": vr(-0.9)], library: lib)
        lib.gate.close()  // b stays unanalysed during select
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("low-quality"))
        #expect(m.photos.map(\.id) == ["a"] && m.progress.pending == 1)
        m.mark(["a"], .keep)  // keep
        lib.gate.open()
        await settle(c)
        await m.refresh()
        #expect(m.photos.map(\.id) == ["a", "b"])
        #expect(m.decisions == ["a": .keep, "b": .delete])
        #expect(m.progress.pending == 0)
    }

    @Test func commitFilesAndUpdatesState() async throws {
        let (c, lib) = try await makeCleanup(
            shots("a", "b", "c"), verdicts: ["b": keepV, "a": dropV],
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
        m.mark(["a"], .delete)
        await m.commit()
        #expect(m.status == "\(LibraryError.accessDenied)")
        #expect(m.photos.map(\.id) == ["a"] && m.deleted.isEmpty)
    }

    @Test func labels() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        #expect(
            ReviewModel.tabs.map(\.title) == [
                "All", "Screenshots", "Paperwork", "Bursts", "Similar", "Low Quality", "To be deleted",
            ])
        await m.refreshCounts()
        await m.select(.all)
        #expect(m.summary == "2 photos" && badge(m, .all) == 2)
        #expect(badge(m, .deleted) == nil)
        await m.select(.pass("screenshots"))
        #expect(m.summary == "2 candidates · 1 to delete")
        #expect(m.commitPreview.map(\.label) == ["1 → Screenshots - Delete Me"])
        #expect(m.banner == nil && !m.showsEmptyState)
        await m.commit()
        #expect(badge(m, .deleted) == 1)
        #expect(m.banner == m.status && m.status?.hasPrefix("Moved") == true)
        m.setAll(.delete)
        await m.commit()
        #expect(m.showsEmptyState)
        await m.select(.deleted)
        #expect(m.summary == "2 queued for deletion" && m.banner?.hasPrefix("Nothing is deleted yet") == true)
        #expect(m.banner?.contains("“Screenshots - Delete Me” (2)") == true)
        #expect("\(LibraryError.accessDenied)".hasPrefix("Photos access not granted"))
    }

    @Test func sidebarSectionsAndBadges() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        let titles = m.sidebar.map { $0.items.map(\.title) }
        #expect(m.sidebar.map(\.title) == ["Library", "Cleanup", "Review"])
        #expect(titles == [["All"], Passes.all.map(\.title), ["To be deleted"]])
        #expect(m.sidebar.flatMap(\.items).allSatisfy { $0.badge == nil && !$0.help.isEmpty })  // nothing counted yet
        await m.refreshCounts()
        var badges: [String: Int?] {
            Dictionary(uniqueKeysWithValues: m.sidebar.flatMap(\.items).map { ($0.title, $0.badge) })
        }
        #expect(badges["All"] == 2 && badges["Screenshots"] == 2)
        #expect(badges["Bursts"] == .some(nil) && badges["To be deleted"] == .some(nil))  // 0 shows no badge
        await m.select(.pass("screenshots"))
        await m.commit()
        #expect(badges["To be deleted"] == 1)
    }

    @Test func selectExtendAndMark() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c", "d"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        let ids = m.displayed.map(\.id)
        m.click(ids[1])
        #expect(m.selected == [ids[1]] && m.anchor == ids[1])
        m.click(ids[3], extend: true)
        #expect(m.selected == Set(ids[1...3]) && m.anchor == ids[1])
        m.click(ids[0], toggle: true)  // ⌘ adds, again removes
        #expect(m.selected == Set(ids[0...3]))
        m.click(ids[0], toggle: true)
        #expect(m.selected == Set(ids[1...3]) && m.anchor == ids[0])
        m.click(ids[2])
        #expect(m.selected == [ids[2]])
        m.selectAll()
        #expect(m.selected == Set(ids))

        m.click(ids[1])
        m.click(ids[2], extend: true)
        m.markSelection(.delete)
        #expect(m.decisions[ids[1]] == .delete && m.decisions[ids[2]] == .delete && m.decisions[ids[0]] == .keep)
        #expect(m.touched == [ids[1], ids[2]])
        m.markSelection(.keep)
        #expect(m.decisions[ids[1]] == .keep && m.decisions[ids[2]] == .keep)
        m.mark([ids[3]], .delete)  // marking one photo
        #expect(m.decisions[ids[3]] == .delete && m.touched.contains(ids[3]))
    }

    @Test func arrowKeysMoveTheSelection() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        let ids = m.displayed.map(\.id)
        m.moveSelection(by: 1)  // nothing selected: first
        #expect(m.selected == [ids[0]])
        m.moveSelection(by: 1)
        m.moveSelection(by: 5)  // clamped
        #expect(m.selected == [ids[2]] && m.anchor == ids[2])
        m.moveSelection(by: -1)
        #expect(m.selected == [ids[1]])
        m.clearSelection()
        m.moveSelection(by: -1)  // nothing selected: last
        #expect(m.selected == [ids[2]])
    }

    @Test func moveDialogOpensOnlyWhenThereIsSomethingToMove() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.all)
        #expect(!m.canMove && !m.canSetAll && !m.confirmingMove)
        await m.select(.pass("screenshots"))
        #expect(m.canSetAll)
        m.setAll(.delete)
        #expect(m.canMove)
        m.confirmingMove = true
        #expect(m.confirmingMove)
    }

    @Test func previewOpensForOnePhotoAndClosesWithTheSelection() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        m.togglePreview()  // nothing selected
        #expect(!m.previewing && m.preview == nil)
        m.selectAll()
        m.togglePreview()  // several selected
        #expect(!m.previewing)
        let first = m.displayed[0].id
        m.click(first)
        m.togglePreview()
        #expect(m.previewing && m.preview?.id == first)
        #expect(m.preview?.badge == (m.decision(first) == .keep ? "✓ Keep" : "✗ Delete"))
        #expect(m.preview?.reason == (m.photos.first { $0.id == first }?.verdict).map { "\($0.kind): \($0.reason)" })
        m.moveSelection(by: 1)  // arrows move the preview along
        #expect(m.previewing && m.preview?.id == m.displayed[1].id)
        m.togglePreview()
        #expect(!m.previewing)
        m.togglePreview()
        m.clearSelection()
        #expect(!m.previewing)
        m.click(first)
        m.togglePreview()
        await m.select(.all)  // a tab change closes it
        #expect(!m.previewing)
    }

    @Test func selectionFollowsTheList() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.all)
        m.selectAll()
        m.markSelection(.delete)  // All marks Delete too
        #expect(m.decisions.count == 3 && m.selected.count == 3)
        await m.select(.pass("screenshots"))  // a tab change clears it
        #expect(m.selected.isEmpty && m.anchor == nil)
        let ids = m.displayed.map(\.id)
        m.click(ids[0])
        m.click(ids[1], toggle: true)
        m.markSelection(.delete)
        await m.commit()  // committed photos leave the selection
        #expect(m.selected.isEmpty && m.anchor == nil)

        await m.select(.pass("screenshots"))
        m.selectAll()
        #expect(m.selected == Set(m.displayed.map(\.id)))
        await m.select(.deleted)
        #expect(m.selected.isEmpty)
    }

    @Test func marksUndoAndRedo() async throws {
        let (c, lib) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        m.undoManager.groupsByEvent = false  // no run loop here to close the groups
        await m.select(.pass("screenshots"))
        let ids = m.displayed.map(\.id)
        m.click(ids[0])
        m.click(ids[1], extend: true)
        m.markSelection(.delete)
        m.mark([ids[2]], .delete)
        #expect(m.decisions.values.allSatisfy { $0 == .delete } && m.touched.count == 3)

        m.undoManager.undo()  // that mark
        #expect(m.decisions[ids[2]] == .keep && !m.touched.contains(ids[2]))
        m.undoManager.undo()  // the selection mark
        #expect(m.decisions.values.allSatisfy { $0 == .keep } && m.touched.isEmpty)
        #expect(!m.undoManager.canUndo && m.undoManager.canRedo)
        m.undoManager.redo()
        #expect(m.decisions[ids[0]] == .delete && m.decisions[ids[1]] == .delete && m.touched == Set(ids[0...1]))

        m.setAll(.keep)
        #expect(m.undoManager.undoActionName == "Keep All")
        m.undoManager.undo()
        #expect(m.decisions[ids[0]] == .delete && m.decisions[ids[2]] == .keep && m.touched == Set(ids[0...1]))

        // The move to albums is not undoable: it clears the stack and undo leaves the albums alone.
        await m.commit()
        #expect(!m.undoManager.canUndo)
        m.undoManager.undo()
        #expect(lib.adds.withLock { $0 }.count == 1 && m.photos.map(\.id) == [ids[2]])

        await m.select(.pass("screenshots"))
        m.mark([ids[2]], .delete)
        await m.select(.all)  // another list: nothing to undo
        #expect(!m.undoManager.canUndo)
    }

    private func waiting() -> [Photo] {
        [
            Photo(uuid: "s", screenshot: true, albums: ["Screenshots - Delete Me"]),
            Photo(uuid: "u", albums: ["Utility - Delete Me"]),
            Photo(uuid: "k", albums: ["Screenshots - Keep"]),
            Photo(uuid: "n", screenshot: true),
        ]
    }

    @Test func deleteInPhotosDeletesOnlyDeleteMePhotos() async throws {
        let (c, lib) = try await makeCleanup(waiting(), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        m.mark(["n"], .delete)
        await m.commit()  // n joins the list this session
        await m.select(.deleted)
        #expect(m.canDeleteInPhotos)
        await m.deleteInPhotos()
        #expect(lib.deletes.withLock { $0 }.flatMap { $0 }.sorted() == ["n", "s", "u"])
        #expect(m.deleted.isEmpty && m.displayed.isEmpty && !m.canDeleteInPhotos)
        #expect(m.summary == "0 queued for deletion")
        #expect(m.status?.hasPrefix("Deleted 3 photos.") == true && m.error == nil)
        await m.refreshCounts()
        #expect(m.deleted.isEmpty)
        #expect(await c.photos.map(\.uuid) == ["k"])
    }

    @Test func cancelledDeleteDeletesNothing() async throws {
        let (c, lib) = try await makeCleanup(waiting(), judge: FakeJudge(off: "off"))
        lib.cancelsDelete.withLock { $0 = true }
        let m = ReviewModel(cleanup: c)
        await m.select(.deleted)
        await m.deleteInPhotos()
        #expect(Set(m.deleted.map(\.id)) == ["s", "u"] && m.canDeleteInPhotos)
        #expect(m.status == nil && m.error == nil)
        #expect(lib.deletes.withLock { $0 }.isEmpty)
    }

    @Test func deleteInPhotosDisabledWhenEmpty() async throws {
        let (c, lib) = try await makeCleanup([Photo(uuid: "n", screenshot: true)], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.deleted)
        #expect(!m.canDeleteInPhotos)
        await m.deleteInPhotos()
        #expect(lib.deletes.withLock { $0 }.isEmpty)
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
        #expect(badge(m, .deleted) == 2)
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
        let (c, lib) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2)])
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
        #expect(m.windowSubtitle == "1 candidate · 0 to delete")
        #expect(m.windowTitle == "Screenshots")
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

@MainActor
@Suite struct InspectorTests {
    @Test func infoFollowsSelection() async throws {
        let when = Date(timeIntervalSince1970: 0)
        let photos = [
            Photo(uuid: "a", date: when, screenshot: true), Photo(uuid: "b", screenshot: true),
            Photo(uuid: "c", albums: ["Trip"]),
        ]
        let (c, _) = try await makeCleanup(photos, verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.pass("screenshots"))
        #expect(m.inspectorInfo() == nil && m.inspectorPlaceholder == "No photo selected")
        m.selectAll()
        #expect(m.inspectorInfo() == nil && m.inspectorPlaceholder == "2 photos selected")

        m.click("a")
        let utc = TimeZone(identifier: "UTC")!
        let i = try #require(m.inspectorInfo(locale: Locale(identifier: "en_US"), timeZone: utc))
        #expect(i.date.hasPrefix("January 1, 1970") && i.kind == "Screenshot")
        #expect(i.verdict == "junk: r" && i.albums == "In no album")
        #expect(i.target == "→ \(Passes.deleteAlbum("screenshots")!)" && i.decision == .delete)

        m.click("b")  // unjudged and untouched: stays put
        let j = try #require(m.inspectorInfo())
        #expect(j.albums == "In no album" && j.verdict == nil && j.target == nil && j.decision == .keep)
        m.mark(["b"], .keep)  // an explicit keep goes to the Keep album
        #expect(m.inspectorInfo()?.target == "→ \(Passes.keepAlbum("screenshots")!)")

        await m.select(.all)
        m.click("c")
        #expect(m.inspectorInfo()?.albums == "In album: Trip" && m.inspectorInfo()?.kind == "Photo")
    }

    @Test func allStartsUnmarked() async throws {
        let (c, _) = try await makeCleanup(shots("a"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.all)
        m.click("a")
        let i = try #require(m.inspectorInfo())
        #expect(i.decision == .keep && i.target == nil)  // unmarked in All
        #expect(m.inspectorToggleLabel == "Show Info")
        m.showsInspector = true
        #expect(m.inspectorToggleLabel == "Hide Info")
    }

    @Test func marksInAllCommitOnlyDeletesToAllAlbum() async throws {
        let album = Passes.allDeleteAlbum
        let (c, lib) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        m.undoManager.groupsByEvent = false
        await m.select(.all)
        #expect(m.decisions.isEmpty && !m.canSetAll && m.canMark && !m.canCommit)
        m.mark(["a", "b"], .delete)
        m.mark(["b"], .keep)  // Keep clears the mark in All
        #expect(m.decisions == ["a": .delete] && m.keepers.isEmpty)
        m.undoManager.undo()
        #expect(m.decisions == ["a": .delete, "b": .delete])
        m.undoManager.redo()
        #expect(m.decisions == ["a": .delete])
        m.click("a")
        #expect(m.inspectorInfo()?.target == "→ \(album)" && m.inspectorInfo()?.decision == .delete)
        m.click("c")
        #expect(m.inspectorInfo()?.target == nil && m.inspectorInfo()?.decision == .keep)
        m.setAll(.delete)  // no-op in All
        #expect(m.commitPreview == [.init(count: 1, album: album)])
        #expect(m.commitPreview.map(\.label) == ["1 → All - Delete Me"])
        await m.commit()
        let adds = lib.adds.withLock { $0 }
        #expect(adds.map(\.album) == [album] && adds[0].uuids == ["a"])
        #expect(m.photos.count == 3 && m.decisions.isEmpty)  // still in All, now badged via deletedAlbum
        #expect(m.deletedAlbum["a"] == album && m.deleted.map(\.id) == ["a"])
        #expect(m.status == "Moved 1 to “\(album)”.")
        #expect(m.sidebar.last?.items.first?.badge == 1)
    }

    @Test func keepAllIsDisabledInAll() async throws {
        let (c, _) = try await makeCleanup(shots("a"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c)
        await m.select(.all)
        #expect(!m.canSetAll)
        await m.select(.pass("screenshots"))
        #expect(m.canSetAll)
    }
}

@MainActor
private func badge(_ m: ReviewModel, _ v: ReviewView) -> Int? {
    m.sidebar.flatMap(\.items).first { $0.view == v }?.badge
}
