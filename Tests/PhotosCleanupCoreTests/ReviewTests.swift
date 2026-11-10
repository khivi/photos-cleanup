import Foundation
import Testing

@testable import PhotosCleanupCore

private func shots(_ ids: String...) -> [Photo] { ids.map { Photo(uuid: $0, screenshot: true) } }
private let keepV = Verdict(keep: true, kind: "receipt", reason: "r")
private let dropV = Verdict(keep: false, kind: "junk", reason: "r")

@MainActor
@Suite struct ReviewTests {
    @Test func editedPhotosStartKeep() async throws {
        let (c, _) = try await makeCleanup(
            [Photo(uuid: "q", edited: true), Photo(uuid: "r")], vision: ["q": vr(-0.9), "r": vr(-0.9)])
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("low-quality"))
        #expect(m.decisions == ["q": .keep, "r": .delete])

        var burst = dated(["x": 0, "y": 1, "z": 2])
        burst[0].edited = true
        burst[2].edited = true
        let (c2, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2)])
        let m2 = ReviewModel(cleanup: c2, dir: tempDir())
        await m2.select(.pass("bursts"))
        #expect(m2.decisions == ["x": .keep, "y": .delete, "z": .keep])
        #expect(["x", "y", "z"].map(m2.isBest) == [false, false, true])

        // Screenshots ignore edits.
        let (c3, _) = try await makeCleanup(
            [Photo(uuid: "s", screenshot: true, edited: true)], verdicts: ["s": dropV], judge: FakeJudge(off: "off"))
        let m3 = ReviewModel(cleanup: c3, dir: tempDir())
        await m3.select(.pass("screenshots"))
        #expect(m3.decisions == ["s": .delete])
        let (c4, _) = try await makeCleanup(
            [Photo(uuid: "t", screenshot: true, edited: true)], judge: FakeJudge(off: "off"))
        let m4 = ReviewModel(cleanup: c4, dir: tempDir())
        await m4.select(.pass("screenshots"))
        #expect(m4.decisions == ["t": .keep] && m4.keepers.isEmpty)  // no verdict: an edit doesn't file it in Keep
    }

    @Test func shortVideosStartDeleteAndLongOnesKeep() async throws {
        let short = Photo(uuid: "s", isMovie: true, duration: Passes.accidentalVideoMax - 0.5)
        let edge = Photo(uuid: "e", isMovie: true, duration: Passes.accidentalVideoMax)
        let (c, _) = try await makeCleanup([short, edge, Photo(uuid: "l", isMovie: true, duration: 60)])
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("videos"))
        #expect(m.decisions == ["s": .delete, "e": .keep, "l": .keep])
        #expect(m.keepers.isEmpty)  // only videos marked Keep by hand are filed; the rest come back
        m.click("l")
        m.togglePreview()
        #expect(m.preview?.video == true)
        #expect(m.inspectorInfo()?.kind == "Video")
    }

    @Test func initialDecisionsPerPass() async throws {
        // Screenshots: delete only on a not-keep verdict; unjudged keeps.
        let (c, _) = try await makeCleanup(
            shots("a", "b", "c"), verdicts: ["a": dropV, "b": keepV],
            judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        #expect(m.decisions == ["a": .delete, "b": .keep, "c": .keep])

        // Bursts: best keeps, rest delete.
        let burst = dated(["x": 0, "y": 1, "z": 2])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2)])
        let m2 = ReviewModel(cleanup: c2, dir: tempDir())
        await m2.select(.pass("bursts"))
        #expect(m2.decisions == ["x": .delete, "y": .keep, "z": .delete])
        #expect(["x", "y", "z"].map(m2.isBest) == [false, true, false])
        await m2.select(.all)
        #expect(!m2.isBest("y"))  // the star is a Bursts-view mark

        // Low quality: everything starts delete.
        let (c3, _) = try await makeCleanup([Photo(uuid: "q")], vision: ["q": vr(-0.9)])
        let m3 = ReviewModel(cleanup: c3, dir: tempDir())
        await m3.select(.pass("low-quality"))
        #expect(m3.decisions == ["q": .delete])

        // All: no decisions.
        await m3.select(.all)
        #expect(m3.decisions.isEmpty && m3.photos.count == 1)
    }

    @Test func toggleAndSetAll() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        m.mark(["a"], .delete)
        #expect(m.decisions["a"] == .delete && m.touched == ["a"])
        m.setAll(.keep)
        #expect(m.decisions == ["a": .keep, "b": .keep] && m.touched == ["a", "b"])
    }

    @Test func keepersRule() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["a": keepV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        // a has a verdict, b is untouched without one (not sent), c is touched twice back to keep.
        m.mark(["c"], .delete)
        m.mark(["c"], .keep)
        #expect(Set(m.keepers.map(\.id)) == ["a", "c"])
        #expect(m.doomed.isEmpty)

        let burst = dated(["x": 0, "y": 1])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9)])
        let m2 = ReviewModel(cleanup: c2, dir: tempDir())
        await m2.select(.pass("bursts"))
        #expect(m2.keepers.map(\.id) == ["y"] && m2.doomed.map(\.id) == ["x"])
    }

    @Test func refreshKeepsTouchedAndFollowsVerdicts() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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

    @Test func scoreLineExplainsLowQualityAndTheStar() async throws {
        let ps = [Photo(uuid: "a"), Photo(uuid: "b"), Photo(uuid: "ok")]
        let (c, _) = try await makeCleanup(ps, vision: ["a": vr(-0.8), "b": vr(-0.95), "ok": vr(0.3)])
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("low-quality"))
        #expect(m.photos.map(\.id) == ["b", "a"])  // worst first
        m.click("a")
        #expect(m.inspectorInfo()?.score == "Score -0.80 · Low Quality at -0.75 or below")
        m.togglePreview()
        #expect(m.preview?.reason == "Score -0.80 · Low Quality at -0.75 or below")

        var burst = dated(["x": 0, "y": 1, "z": 2])
        let (c2, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2)])
        let m2 = ReviewModel(cleanup: c2, dir: tempDir())
        await m2.select(.pass("bursts"))
        #expect(m2.scoreLine("y") == "Score 0.90 · ★ of 3")
        #expect(m2.scoreLine("x") == "Score 0.10 · ★ scored 0.90")

        burst[2].edited = true
        let (c3, _) = try await makeCleanup(burst, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2)])
        let m3 = ReviewModel(cleanup: c3, dir: tempDir())
        await m3.select(.pass("bursts"))
        #expect(m3.scoreLine("z") == "Score 0.20 · ★ of 3, edited")
        #expect(m3.scoreLine("y") == "Score 0.90 · ★ is edited")
    }

    @Test func refreshAppendsNewCandidates() async throws {
        let ps = [Photo(uuid: "a"), Photo(uuid: "b")]
        let lib = FakeLibrary(ps, vision: ["a": vr(-0.9), "b": vr(-0.8)])
        let (c, _) = try await makeCleanup(ps, vision: ["a": vr(-0.9)], library: lib)
        lib.gate.close()  // b stays unanalysed during select
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        await m.commit()
        await m.apply()
        let adds = lib.adds.withLock { $0 }
        #expect(adds.map(\.album) == ["Screenshots - Delete Me", "Screenshots - Keep"])
        #expect(adds[0].uuids == ["a"] && adds[1].uuids == ["b"])  // c: untouched, no verdict
        #expect(m.photos.map(\.id) == ["c"])
        #expect(m.deleted.map(\.id) == ["a"])
        #expect(m.decisions.keys.sorted() == ["c"])
        #expect(m.status == "Applied 2 photos to their albums in Photos.")
        #expect(!m.committing)
        await m.select(.deleted)
        #expect(m.displayed.map(\.id) == ["a"])
    }

    @Test func commitErrorSetsStatus() async throws {
        let lib = FakeLibrary(shots("a"), status: "denied")
        let (c, _) = try await makeCleanup([], judge: FakeJudge(off: "off"), library: lib)
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        m.mark(["a"], .delete)
        await m.commit()  // into Pending: Photos isn't asked yet
        #expect(m.status == nil && m.pending.keys.sorted() == ["a"])
        await m.apply()
        #expect(m.status == "\(LibraryError.accessDenied)")
        #expect(m.pending.keys.sorted() == ["a"] && m.deleted.isEmpty)  // kept for the next Apply
    }

    @Test func labels() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        #expect(
            ReviewModel.tabs.map(\.title) == [
                "All", "Screenshots", "Paperwork", "Bursts", "Similar", "Low Quality", "Videos", "Pending",
                "To be deleted", "Export", "Import",
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
        await m.apply()
        #expect(badge(m, .deleted) == 1)
        #expect(m.banner == m.status && m.status?.hasPrefix("Applied") == true)
        m.setAll(.delete)
        await m.commit()
        await m.apply()
        #expect(m.showsEmptyState)
        await m.select(.deleted)
        #expect(m.summary == "2 queued for deletion" && m.banner?.hasPrefix("Nothing is deleted yet") == true)
        #expect(m.banner?.contains("“Screenshots - Delete Me” (2)") == true)
        #expect("\(LibraryError.accessDenied)".hasPrefix("Photos access not granted"))
    }

    @Test func sidebarSectionsAndBadges() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        let titles = m.sidebar.map { $0.items.map(\.title) }
        #expect(m.sidebar.map(\.title) == ["Library", "Cleanup", "Review", "Transfer"])
        #expect(titles == [["All"], Passes.all.map(\.title), ["Pending", "To be deleted"], ["Export", "Import"]])
        #expect(m.sidebar.flatMap(\.items).allSatisfy { $0.badge == nil && !$0.help.isEmpty })  // nothing counted yet
        await m.refreshCounts()
        var badges: [String: Int?] {
            Dictionary(uniqueKeysWithValues: m.sidebar.flatMap(\.items).map { ($0.title, $0.badge) })
        }
        #expect(badges["All"] == 2 && badges["Screenshots"] == 2)
        // A pass that found nothing says 0; an empty queue shows no badge.
        #expect(badges["Bursts"] == 0 && badges["To be deleted"] == .some(nil))
        await m.select(.pass("screenshots"))
        await m.commit()
        await m.apply()
        #expect(badges["To be deleted"] == 1)
    }

    @Test func selectExtendAndMark() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c", "d"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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

    @Test func markingOnePhotoMovesToTheNext() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        let ids = m.displayed.map(\.id)
        m.click(ids[0])
        m.togglePreview()
        m.markSelection(.delete)
        #expect(m.decisions[ids[0]] == .delete && m.selected == [ids[1]] && m.preview?.id == ids[1])
        m.click(ids[2])
        m.markSelection(.delete)  // the last photo stays selected
        #expect(m.decisions[ids[2]] == .delete && m.selected == [ids[2]])
        m.click(ids[0])
        m.click(ids[1], toggle: true)
        m.markSelection(.keep)  // several selected: no move
        #expect(m.selected == [ids[0], ids[1]])
    }

    @Test func arrowKeysMoveTheSelection() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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

    @Test func confirmAllIsEnabledOnlyWhenThereIsSomethingToMove() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.all)
        #expect(!m.canMove && !m.canSetAll && m.confirmAllHelp == "Nothing to confirm")
        await m.select(.pass("screenshots"))
        #expect(m.canSetAll)
        m.setAll(.delete)
        #expect(m.canMove && m.confirmAllHelp == "To Pending:\n2 → Screenshots - Delete Me")
    }

    @Test func previewOpensForOnePhotoAndClosesWithTheSelection() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        await m.apply()
        #expect(m.selected.isEmpty && m.anchor == nil)

        await m.select(.pass("screenshots"))
        m.selectAll()
        #expect(m.selected == Set(m.displayed.map(\.id)))
        await m.select(.deleted)
        #expect(m.selected.isEmpty)
    }

    @Test func marksUndoAndRedo() async throws {
        let (c, lib) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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

        // Confirm All is undoable too: the photos come back from Pending. Apply is not.
        await m.commit()
        #expect(m.pending.count == 2 && m.photos.map(\.id) == [ids[2]] && lib.adds.withLock { $0 }.isEmpty)
        #expect(m.undoManager.undoActionName == "Confirm All")
        m.undoManager.undo()
        #expect(m.pending.isEmpty && m.photos.count == 3)
        m.undoManager.redo()
        await m.apply()
        #expect(lib.adds.withLock { $0 }.count == 1 && !m.undoManager.canUndo)

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
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        m.mark(["n"], .delete)
        await m.commit()  // n joins the list this session
        await m.apply()
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
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.deleted)
        await m.deleteInPhotos()
        #expect(Set(m.deleted.map(\.id)) == ["s", "u"] && m.canDeleteInPhotos)
        #expect(m.status == nil && m.error == nil)
        #expect(lib.deletes.withLock { $0 }.isEmpty)
    }

    @Test func deleteInPhotosDisabledWhenEmpty() async throws {
        let (c, lib) = try await makeCleanup([Photo(uuid: "n", screenshot: true)], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        await m.apply()
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
        let m = ReviewModel(cleanup: c, dir: tempDir())
        #expect(m.commitPreview.isEmpty)
        await m.select(.pass("bursts"))
        #expect(m.commitPreview.map(\.label) == ["2 → Bursts - Delete Me", "1 → Bursts - Keep"])
        await m.commit()
        await m.apply()
        let sent = lib.adds.withLock { $0 }
        #expect(sent.map(\.album) == ["Bursts - Delete Me", "Bursts - Keep"])
        #expect(sent.map(\.uuids.count) == [2, 1])
        #expect(m.commitPreview.isEmpty)
    }

    @Test func emptySideIsOmittedAndLabels() async throws {
        let (c, _) = try await makeCleanup([Photo(uuid: "a", screenshot: true)], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        #expect(m.commitPreview.isEmpty)  // unjudged, untouched: nothing is sent
        #expect(m.windowSubtitle == "1 candidate · 0 to delete")
        #expect(m.windowTitle == "Screenshots")
        m.setAll(.delete)
        #expect(m.commitPreview == [.init(count: 1, album: "Screenshots - Delete Me")])
        #expect(m.moveButtonLabel == "Confirm All")
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
    @Test func showInPhotosNeedsExactlyOneSelected() async throws {
        let (c, _) = try await makeCleanup([Photo(uuid: "a", screenshot: true), Photo(uuid: "b", screenshot: true)])
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        #expect(!m.canShowInPhotos)
        m.selectAll()
        #expect(!m.canShowInPhotos)
        m.click("a")
        #expect(m.canShowInPhotos)
        var script = ""
        await m.showInPhotos { script = $0 }
        #expect(script.contains("\"a/L0/001\""))
        await m.showInPhotos { _ in throw CocoaError(.fileNoSuchFile) }
        #expect(m.status != nil)
    }

    @Test func infoFollowsSelection() async throws {
        let when = Date(timeIntervalSince1970: 0)
        let photos = [
            Photo(uuid: "a", date: when, screenshot: true), Photo(uuid: "b", screenshot: true),
            Photo(uuid: "c", albums: ["Trip"]),
        ]
        let (c, _) = try await makeCleanup(photos, verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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

    @Test func accessibilityLabelReadsKindDateAndMark() async throws {
        let photos = [
            Photo(uuid: "a", date: Date(timeIntervalSince1970: 0), screenshot: true),
            Photo(uuid: "v", isMovie: true, duration: 5), Photo(uuid: "d"),
        ]
        let (c, _) = try await makeCleanup(photos, verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        let en = Locale(identifier: "en_US")
        let utc = TimeZone(identifier: "UTC")!
        func label(_ id: String) -> String {
            m.accessibilityLabel(m.photos.first { $0.id == id }!, locale: en, timeZone: utc)
        }
        await m.select(.pass("screenshots"))
        #expect(label("a").hasPrefix("Screenshot, January 1, 1970") && label("a").hasSuffix(", marked Delete, junk: r"))
        await m.select(.pass("videos"))
        #expect(label("v") == "Video, 0:05, Unknown date, marked Keep")
        await m.select(.all)
        m.mark(["d"], .delete)
        await m.commit()
        await m.apply()
        #expect(label("d") == "Photo, Unknown date, in Delete Me")
    }

    @Test func allStartsUnmarked() async throws {
        let (c, _) = try await makeCleanup(shots("a"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        let m = ReviewModel(cleanup: c, dir: tempDir())
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
        await m.apply()
        let adds = lib.adds.withLock { $0 }
        #expect(adds.map(\.album) == [album] && adds[0].uuids == ["a"])
        #expect(m.photos.count == 3 && m.decisions.isEmpty)  // still in All, now badged via deletedAlbum
        #expect(m.deletedAlbum["a"] == album && m.deleted.map(\.id) == ["a"])
        #expect(m.status == "Applied 1 photo to their albums in Photos.")
        #expect(badge(m, .deleted) == 1 && badge(m, .pending) == nil)
    }

    @Test func keepAllIsDisabledInAll() async throws {
        let (c, _) = try await makeCleanup(shots("a"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.all)
        #expect(!m.canSetAll)
        await m.select(.pass("screenshots"))
        #expect(m.canSetAll)
    }

    @Test func onlyDeleteFiltersEveryView() async throws {
        let (c, _) = try await makeCleanup(
            shots("a", "b", "c"), verdicts: ["a": dropV, "c": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        m.undoManager.groupsByEvent = false  // no run loop here to close the groups
        await m.select(.pass("screenshots"))
        let ids = m.displayed.map(\.id)
        let doomed = ids.filter { m.decision($0) == .delete }
        #expect(doomed.count == 2)
        m.click(ids.first { m.decision($0) != .delete }!)
        m.onlyDelete = true
        #expect(m.displayed.map(\.id) == doomed && m.selected.isEmpty)  // the hidden photo leaves the selection
        m.click(doomed[0])
        m.markSelection(.keep)  // hidden now: the next one takes its place
        #expect(m.displayed.map(\.id) == [doomed[1]] && m.selected == [doomed[1]])
        m.markSelection(.keep)
        #expect(m.displayed.isEmpty && m.selected.isEmpty && m.showsEmptyState)
        #expect(m.emptyStateLabel == "Nothing marked Delete.")
        m.undoManager.undo()
        #expect(m.displayed.map(\.id) == [doomed[1]])

        await m.select(.all)  // a view change turns it off
        #expect(!m.onlyDelete && m.displayed.count == 3)
        m.onlyDelete = true
        #expect(m.displayed.isEmpty)  // All starts unmarked
        m.onlyDelete = false
        m.click(ids[1])
        m.markSelection(.delete)
        m.onlyDelete = true
        #expect(m.displayed.map(\.id) == [ids[1]])
    }

    @Test func sectionsMoveMonthToMonth() async throws {
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        let photos = [
            Photo(uuid: "a", date: at("2026-10-20T12:00:00Z")), Photo(uuid: "b", date: at("2026-10-15T12:00:00Z")),
            Photo(uuid: "c", date: at("2026-08-05T12:00:00Z")), Photo(uuid: "d", date: at("2024-03-05T12:00:00Z")),
        ]
        let (c, _) = try await makeCleanup(photos, judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.all)
        let firsts = m.groups.map { $0.photos[0].id }
        #expect(m.canMoveSection && firsts.count == 3)
        m.moveSection(by: 1)  // nothing selected: the first section
        #expect(m.selected == [firsts[0]])
        m.click(m.groups[0].photos[1].id)  // from inside a section
        m.moveSection(by: 1)
        #expect(m.selected == [firsts[1]])
        // The grid puts this section's header on top.
        #expect(m.sectionJump?.key == m.groups[1].best && m.sectionJump?.photo == firsts[1])
        m.moveSection(by: 5)  // clamped
        #expect(m.anchor == firsts[2])
        m.moveSection(by: -1)
        #expect(m.anchor == firsts[1])
        await m.select(.pass("low-quality"))
        #expect(m.canMoveSection)  // months there too
        await m.select(.deleted)
        #expect(!m.canMoveSection)
    }

    @Test func allGroupsByMonth() async throws {
        let utc = TimeZone(identifier: "UTC")!
        let en = Locale(identifier: "en_US")
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        let photos = [
            Photo(uuid: "u"), Photo(uuid: "a", date: at("2026-10-20T12:00:00Z")),
            Photo(uuid: "b", date: at("2026-10-15T12:00:00Z")), Photo(uuid: "c", date: at("2024-03-05T12:00:00Z")),
        ]
        let (c, _) = try await makeCleanup(photos, judge: FakeJudge(off: "off"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = ReviewModel(cleanup: c, dir: dir)
        await m.select(.all)

        let gs = ReviewModel.monthGroups(photos, timeZone: utc)
        #expect(gs.map(\.best) == ["2026-10", "2024-03", "unknown"])
        #expect(
            gs.map { m.header($0, locale: en, timeZone: utc) } == [
                "October 2026 · 2", "March 2024 · 1", "Unknown date · 1",
            ])
        #expect(m.photos.map(\.id) == m.groups.flatMap(\.photos).map(\.id))  // arrow order is the display order

    }
}

@MainActor
private func badge(_ m: ReviewModel, _ v: ReviewView) -> Int? {
    m.sidebar.flatMap(\.items).first { $0.view == v }?.badge
}

@MainActor @Test func sidebarShowsTheVisionRunOnPassesWaitingForIt() async throws {
    let photos = [Photo(uuid: "a", date: t0), Photo(uuid: "b", date: t0 + 5), Photo(uuid: "s", screenshot: true)]
    let lib = FakeLibrary(photos, vision: ["a": vr(0.5, [0]), "b": vr(0.5, [0])])
    lib.gate.close()
    let (c, _) = try await makeCleanup(photos, library: lib)
    await c.startVision(photos.filter { !$0.screenshot })
    let m = ReviewModel(cleanup: c, dir: tempDir())
    await m.refreshCounts()
    func row(_ title: String) -> ReviewModel.SidebarItem? {
        m.sidebar.flatMap(\.items).first { $0.title == title }
    }
    for pass in ["Paperwork", "Bursts", "Similar", "Low Quality"] { #expect(row(pass)?.progress == 0, "\(pass)") }
    #expect(row("Screenshots")?.progress == nil)  // needs no Vision: its badge shows
    #expect(row("Screenshots")?.badge == 1)

    lib.gate.open()
    await settle(c)
    await m.refreshPassCounts()
    #expect(row("Bursts")?.progress == nil)
    #expect(row("Bursts")?.badge == 2)
}

@MainActor @Test func sidebarRingNamesItsJobOnTheQueuedPassOnly() async throws {
    let photos = [Photo(uuid: "p", date: t0), Photo(uuid: "s", screenshot: true)]
    let lib = FakeLibrary(photos, vision: ["p": vr(0.5, utility: true, [0])])
    lib.gate.close()
    let judge = FakeJudge(["s": Verdict(keep: false, kind: "notes", reason: "")])
    judge.gate.close()
    let (c, _) = try await makeCleanup(photos, judge: judge, library: lib)
    await c.startVision([photos[0]])
    let m = ReviewModel(cleanup: c, dir: tempDir())
    func row(_ title: String) -> ReviewModel.SidebarItem? { m.sidebar.flatMap(\.items).first { $0.title == title } }

    await m.select(.pass("screenshots"))  // queues s for a verdict
    await m.refreshPassCounts()
    #expect(m.jobsRunning)
    #expect(row("Paperwork")?.help == m.passNote("paperwork") + "\nAnalysing photos on this Mac: 0 of 1")
    #expect(row("Screenshots")?.progress == 0)
    #expect(row("Screenshots")?.help == m.passNote("screenshots") + "\nChecking photos with Apple Intelligence: 0 of 1")

    lib.gate.open()  // Vision done; only Screenshots has photos in the verdict queue
    for _ in 0..<500 where await c.visionRunning { try? await Task.sleep(for: .milliseconds(10)) }
    await m.refreshPassCounts()
    #expect(row("Paperwork")?.progress == nil)
    #expect(row("Screenshots")?.progress == 0)

    judge.gate.open()
    await settle(c)
    await m.refreshPassCounts()
    #expect(!m.jobsRunning)
    #expect(
        row("Screenshots")?.progress == nil
            && row("Screenshots")?.help == m.passNote("screenshots"))
}

@Test func tilesSayLivePhotoAndScreenRecording() {
    let photos = [
        Photo(uuid: "live", live: true), Photo(uuid: "plain"),
        Photo(uuid: "rec", isMovie: true, duration: 30, screenRecording: true),
    ]
    #expect(photos.map(\.kindTag) == ["Live", nil, "Screen recording"])
    #expect(photos.map(\.kindLabel) == ["Live Photo", "Photo", "Screen recording"])
}

@MainActor @Test func passesExplainTheirMarksInPlainWords() async throws {
    let (c, _) = try await makeCleanup([], keepAlbumPhotos: false)
    let m = ReviewModel(cleanup: c, dir: tempDir())
    #expect(m.passCaption == nil)  // All has no caption
    await m.select(.pass("videos"))
    #expect(
        m.passCaption
            == "Your videos, longest first. Clips under 2 seconds are marked to delete: they are usually accidental. Favorites are never suggested."
    )
    let (c2, _) = try await makeCleanup([])
    let m2 = ReviewModel(cleanup: c2, dir: tempDir())
    #expect(m2.passNote("bursts").hasSuffix("Favorites and photos in your albums are never suggested."))
    #expect(m2.sidebar.flatMap(\.items).first { $0.title == "Bursts" }?.help == m2.passNote("bursts"))
}

@MainActor @Test func zoomStepsThroughTheSizesAndStopsAtBothEnds() async throws {
    let (c, _) = try await makeCleanup([])
    let m = ReviewModel(cleanup: c, dir: tempDir())
    #expect(m.cellSize == 120 && m.canZoomIn && m.canZoomOut)
    m.zoomOut()
    #expect(m.cellSize == 80 && !m.canZoomOut)
    m.zoomOut()
    #expect(m.cellSize == 80)
    for _ in 0..<5 { m.zoomIn() }
    #expect(m.cellSize == 260 && !m.canZoomIn)
    m.zoom = 99  // a stale saved value
    #expect(m.cellSize == 260)

    #expect(m.aspectToggleLabel == "Show Whole Photos")
    m.aspectFit = true
    #expect(m.aspectToggleLabel == "Show Square Photos")
}

@MainActor @Test func subtitleCountsHaveThousandsSeparators() async throws {
    let clips = (0..<1200).map {
        Photo(uuid: "v\($0)", date: t0 + Double($0), isMovie: true, duration: $0 < 1001 ? 1 : 30)
    }
    let (c, _) = try await makeCleanup(clips)
    let m = ReviewModel(cleanup: c, dir: tempDir())
    await m.select(.pass("videos"))
    #expect(m.summary == "\(1200.formatted()) candidates · \(1001.formatted()) to delete")
    #expect(m.summary.contains(1200.formatted()) && 1200.formatted() != "1200")  // the separator shows
    await m.select(.all)
    #expect(m.summary == "\(1200.formatted()) photos")
}

@MainActor
@Suite struct ConfirmTests {
    /// Two bursts a day apart: x, y (★), z and p, q (★).
    private func twoBursts(dir: URL = tempDir()) async throws -> (ReviewModel, FakeLibrary, Cleanup) {
        let photos = dated(["x": 0, "y": 1, "z": 2, "p": 86_400, "q": 86_401])
        let (c, lib) = try await makeCleanup(
            photos, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2), "p": vr(0.1), "q": vr(0.8)])
        let m = ReviewModel(cleanup: c, dir: dir, defaults: freshDefaults())
        await m.select(.pass("bursts"))
        return (m, lib, c)
    }

    private func sent(_ lib: FakeLibrary) -> [String: Set<String>] {
        Dictionary(lib.adds.withLock { $0 }.map { ($0.album, Set($0.uuids)) }, uniquingKeysWith: { $0.union($1) })
    }

    @Test func theBestPhotoLeadsItsGroup() async throws {
        let (m, _, _) = try await twoBursts()
        #expect(m.groups.map { $0.photos.map(\.id) }.sorted { $0[0] < $1[0] } == [["q", "p"], ["y", "x", "z"]])
        #expect(m.photos.map(\.id) == m.groups.flatMap(\.photos).map(\.id))  // arrow order is the display order
    }

    @Test func confirmMovesTheGroupToPendingWithoutTouchingPhotos() async throws {
        let (m, lib, _) = try await twoBursts()
        let (first, second) = (m.groups[0], m.groups[1])
        m.click(first.photos[0].id)
        await m.confirm()
        #expect(lib.adds.withLock { $0 }.isEmpty)
        #expect(m.groups.map(\.best) == [second.best] && m.anchor == second.photos[0].id)
        let best = first.photos[0].id
        #expect(m.pending[best] == Pending(pass: "bursts", keep: true) && m.pending.count == first.photos.count)
        #expect(m.applyButtonLabel == "Apply \(first.photos.count) to Photos…")

        m.undoManager.undo()
        #expect(m.groups.count == 2 && m.pending.isEmpty && m.decision(best) == .keep)
        m.undoManager.redo()
        #expect(m.groups.count == 1 && m.pending.count == first.photos.count)
    }

    @Test func applyFilesEveryPendingPhotoAndEmptiesPending() async throws {
        let (m, lib, _) = try await twoBursts()
        let g = m.groups[0]
        await m.confirm(g)
        let ids = g.photos.map(\.id)
        #expect(m.applyPreview.map(\.label) == ["\(ids.count - 1) → Bursts - Delete Me", "1 → Bursts - Keep"])
        await m.apply()
        #expect(sent(lib) == ["Bursts - Delete Me": Set(ids.dropFirst()), "Bursts - Keep": [ids[0]]])
        #expect(m.pending.isEmpty && !m.undoManager.canUndo)
        #expect(Set(m.deleted.map(\.id)) == Set(ids.dropFirst()))  // To be deleted lists them now
    }

    @Test func pendingSurvivesRelaunchAndStaysOutOfThePass() async throws {
        let dir = tempDir()
        let (m, _, c) = try await twoBursts(dir: dir)
        let g = m.groups[0]
        await m.confirm(g)
        let again = ReviewModel(cleanup: c, dir: dir, defaults: freshDefaults())
        await again.select(.pass("bursts"))
        #expect(again.pending.count == g.photos.count && again.groups.map(\.best) == [m.groups[0].best])
        await again.select(.pending)
        #expect(again.pendingGroups.flatMap(\.photos).count == g.photos.count)
        again.click(g.photos[0].id)
        again.sendBack()
        #expect(again.pending.count == g.photos.count - 1 && loadPending(dir: dir).count == g.photos.count - 1)
        again.selectAll()
        again.sendBack()  // a burst needs two shots to come back as a group
        #expect(again.pending.isEmpty)
        await again.select(.pass("bursts"))
        #expect(Set(again.photos.map(\.id)).isSuperset(of: g.photos.map(\.id)))  // back to review
    }

    @Test func aNumberKeepsOnlyThatPhotoThenConfirms() async throws {
        let (m, _, _) = try await twoBursts()
        let g = try #require(m.groups.first { $0.photos.count == 3 })
        let other = try #require(m.groups.first { $0.photos.count == 2 })
        m.click(other.photos[0].id)
        await m.confirm(keeping: 8)  // the group has 2 photos: nothing happens
        #expect(m.pending.isEmpty)
        m.click(g.photos[0].id)
        await m.confirm(keeping: 2)
        let ids = g.photos.map(\.id)
        #expect(ids.map { m.pending[$0]?.keep } == [false, false, true])
        m.undoManager.undo()
        #expect(ids.map { m.decision($0) } == [.keep, .delete, .delete])  // the marks before the number key
    }

    @Test func confirmUpToHereCoversWholeGroupsThroughTheSelectedOne() async throws {
        let photos = dated(["a": 0, "b": 1, "c": 86_400, "d": 86_401, "e": 172_800, "f": 172_801])
        let (c, _) = try await makeCleanup(
            photos, vision: ["a": vr(0.9), "b": vr(0.1), "c": vr(0.9), "d": vr(0.1), "e": vr(0.9), "f": vr(0.1)])
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        await m.select(.pass("bursts"))
        let gs = m.groups
        m.onlyDelete = true  // the filter hides the ★s; Confirm still takes them, as Keep
        m.click(gs[1].photos[1].id)
        await m.confirmUpToHere()
        #expect(Set(m.pending.keys) == Set((gs[0].photos + gs[1].photos).map(\.id)))
        #expect(m.pending[gs[0].photos[0].id]?.keep == true)
        #expect(m.groups.map(\.best) == [gs[2].best] && m.anchor == gs[2].photos[1].id)
        m.undoManager.undo()
        #expect(m.groups.count == 3 && m.pending.isEmpty)
    }

    @Test func allBrowsesAndItsDeleteMarksGoThroughConfirmAll() async throws {
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        let photos = [
            Photo(uuid: "a", date: at("2026-10-20T12:00:00Z")), Photo(uuid: "b", date: at("2026-10-15T12:00:00Z")),
            Photo(uuid: "c", date: at("2024-03-05T12:00:00Z")),
        ]
        let (c, lib) = try await makeCleanup(photos, judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        await m.select(.all)
        #expect(m.groups.count == 2 && !m.canConfirm)
        let oct = try #require(m.groups.first { $0.photos.count == 2 })
        m.mark(["a"], .delete)
        await m.confirm(oct)
        await m.confirmUpToHere(oct)
        #expect(m.pending.isEmpty && m.decisions["a"] == .delete && m.groups.count == 2)
        await m.commit()
        #expect(
            m.pending == ["a": Pending(pass: Passes.allKey, keep: false)]
                && m.album(m.pending["a"]!) == "All - Delete Me")
        await m.apply()
        #expect(sent(lib) == ["All - Delete Me": ["a"]])
    }

    @Test func passesWithoutGroupsShowMonthsNewestFirstInTheirOwnOrder() async throws {
        let photos = dated(["p1": 0, "p2": 40 * 86_400, "p3": 3_600])
        let (c, _) = try await makeCleanup(photos, vision: ["p1": vr(-0.9), "p2": vr(-0.8), "p3": vr(-0.95)])
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        await m.select(.pass("low-quality"))
        #expect(m.groups.map { $0.photos.map(\.id) } == [["p2"], ["p3", "p1"]])  // worst first within a month
        #expect(m.photos.map(\.id) == ["p2", "p3", "p1"])
        let g = m.groups[0]
        #expect(m.confirmHelp(g) == "Confirm this month (Return)" && !m.canKeepOnly)
        #expect(m.confirmHelp(m.groups[1]) == "Confirm this month")
    }

    @Test func aGroupHoldingTheAnchorIsExpanded() async throws {
        let (m, _, _) = try await twoBursts()
        let (a, b) = (m.groups[0], m.groups[1])
        m.click(a.photos[1].id)
        #expect(m.isExpanded(a) && !m.isExpanded(b))
        m.toggleExpanded(b)
        #expect(m.isExpanded(b))
        m.toggleExpanded(b)
        #expect(!m.isExpanded(b))
    }

    @Test func theSelectedGroupShowsItsKeyNumbers() async throws {
        let (m, _, _) = try await twoBursts()
        let (a, b) = (m.groups[0], m.groups[1])
        #expect(m.isCurrent(a) && a.photos.map { m.keyNumber($0.id) } == Array(1...a.photos.count))
        #expect(b.photos.allSatisfy { m.keyNumber($0.id) == nil })
        m.click(b.photos[1].id)
        #expect(m.isCurrent(b) && m.keyNumber(b.photos[1].id) == 2 && m.keyNumber(a.photos[0].id) == nil)
        #expect(m.confirmHelp(a) == "Confirm this group" && m.confirmHelp(b) == "Confirm this group (Return)")
        #expect(m.keepOnlyHelp(b.photos[1].id).hasSuffix("(2)") && m.canKeepOnly)
        #expect(m.confirmUpToHereHelp(b).hasSuffix("(⇧Return)"))
    }

    @Test func confirmUpToHereOnASectionNeedsNoSelection() async throws {
        let (m, _, _) = try await twoBursts()
        let gs = m.groups
        m.clearSelection()
        await m.confirmUpToHere(gs[0])
        #expect(Set(m.pending.keys) == Set(gs[0].photos.map(\.id)) && m.groups.map(\.best) == [gs[1].best])
    }

    @Test func keepOnlyConfirmsItsGroupWithOnlyThatPhotoKept() async throws {
        let (m, _, _) = try await twoBursts()
        let gs = m.groups
        let pick = gs[1].photos[1].id
        await m.keepOnly(pick)
        #expect(Set(m.pending.keys) == Set(gs[1].photos.map(\.id)))
        #expect(gs[1].photos.allSatisfy { m.pending[$0.id]?.keep == ($0.id == pick) })
        #expect(m.groups.map(\.best) == [gs[0].best])
    }

    @Test func undoStateFollowsTheLastActionAndClearsAfterUndo() async throws {
        let (m, _, _) = try await twoBursts()
        m.undoManager.groupsByEvent = false  // no run loop here to close the groups
        #expect(!m.canUndo && m.undoHelp == "Nothing to undo")
        await m.confirm()
        #expect(m.canUndo && m.undoName == ReviewModel.confirmLabel && m.undoHelp == "Undo Confirm (⌘Z)")
        m.undoManager.undo()
        #expect(!m.canUndo && m.undoHelp == "Nothing to undo")
        m.undoManager.redo()
        #expect(m.canUndo)
    }

    @Test func theCaptionFoldsPerPassAndStaysFolded() async throws {
        let photos = dated(["x": 0, "y": 1])
        let (c, _) = try await makeCleanup(photos, vision: ["x": vr(0.1), "y": vr(0.9)])
        let defaults = freshDefaults()
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: defaults)
        await m.select(.pass("bursts"))
        #expect(!m.captionFolded)
        m.toggleCaption()
        #expect(m.captionFolded && m.captionToggleLabel == "Show More")
        await m.select(.pass("similar"))
        #expect(!m.captionFolded)
        let again = ReviewModel(cleanup: c, dir: tempDir(), defaults: defaults)
        await again.select(.pass("bursts"))
        #expect(again.captionFolded)
    }
}
