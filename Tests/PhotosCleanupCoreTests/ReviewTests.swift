import Foundation
import Testing

@testable import PhotosCleanupCore

private func shots(_ ids: String...) -> [Photo] { ids.map { Photo(uuid: $0, screenshot: true) } }
private let keepV = Verdict(keep: true, kind: "receipt", reason: "r")
private let dropV = Verdict(keep: false, kind: "junk", reason: "r")

extension ReviewModel {
    /// Accept on every section, top to bottom.
    fileprivate func confirmEverySection() async {
        for g in shownGroups { await confirm(g) }
    }
}

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
        #expect(m4.decisions == ["t": .keep])
    }

    @Test func shortVideosStartDeleteAndLongOnesKeep() async throws {
        let short = Photo(uuid: "s", isMovie: true, duration: Passes.accidentalVideoMax - 0.5)
        let edge = Photo(uuid: "e", isMovie: true, duration: Passes.accidentalVideoMax)
        let (c, _) = try await makeCleanup([short, edge, Photo(uuid: "l", isMovie: true, duration: 60)])
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("videos"))
        #expect(m.decisions == ["s": .delete, "e": .keep, "l": .keep])
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

    @Test func deleteKeyTogglesKeepAndRemove() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        m.click("a")
        #expect(m.decisions["a"] == .keep && m.deleteKeyLabel == "Remove")
        m.deleteKey()
        #expect(m.decisions["a"] == .delete && m.touched == ["a"] && m.deleteKeyLabel == "Keep")
        m.deleteKey()
        #expect(m.decisions["a"] == .keep)
        m.mark(["b"], .unsure)
        m.click("b")
        m.deleteKey()  // Unsure isn't Remove: ⌫ marks it Remove
        #expect(m.decisions["b"] == .delete)
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

    @Test func confirmFilesAndUpdatesState() async throws {
        let (c, lib) = try await makeCleanup(
            shots("a", "b", "c"), verdicts: ["b": keepV, "a": dropV],
            judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        await m.confirmEverySection()
        await m.apply()
        let adds = lib.adds.withLock { $0 }
        #expect(adds.map(\.album) == ["Screenshots - Delete Me", "Screenshots - Keep"])
        #expect(adds[0].uuids == ["a"] && Set(adds[1].uuids) == ["b", "c"])
        #expect(m.photos.isEmpty && m.decisions.isEmpty)
        #expect(m.deleted.map(\.id) == ["a"])
        #expect(m.status == "Applied 3 photos to their albums in Photos.")
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
        await m.confirmEverySection()  // into Pending: Photos isn't asked yet
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
                "All", "Screenshots", "Paperwork", "Bursts", "Similar", "Low Quality", "Videos", "Not in Photos Yet",
                "In Delete Me Albums", "Export", "Import",
            ])
        await m.refreshCounts()
        await m.select(.all)
        #expect(m.summary == "2 photos" && badge(m, .all) == 2)
        #expect(badge(m, .deleted) == nil)
        await m.select(.pass("screenshots"))
        #expect(m.summary == "2 photos · keeping 1 · removing 1")
        #expect(m.banner == nil && !m.showsEmptyState)
        await m.confirmEverySection()
        await m.apply()
        #expect(badge(m, .deleted) == 1 && m.showsEmptyState)
        #expect(m.banner == m.status && m.status?.hasPrefix("Applied") == true)
        await m.select(.deleted)
        #expect(
            m.summary == "1 in Delete Me albums" && m.deleteInPhotosLabel == "Delete 1 in Photos…" && !m.showsApply
                && m.banner?.hasPrefix("Nothing is deleted yet") == true)
        #expect(m.banner?.contains("“Screenshots - Delete Me” (1)") == true)
        #expect("\(LibraryError.accessDenied)".hasPrefix("Photos access not granted"))
    }

    @Test func sidebarSectionsAndBadges() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        let titles = m.sidebar.map { $0.items.map(\.title) }
        #expect(m.sidebar.map(\.title) == ["Library", "Cleanup", "Review", "Transfer"])
        #expect(
            titles == [
                ["All"], Passes.all.map(\.title), ["Not in Photos Yet", "In Delete Me Albums"], ["Export", "Import"],
            ])
        #expect(m.sidebar.flatMap(\.items).allSatisfy { $0.badge == nil && !$0.help.isEmpty })  // nothing counted yet
        await m.refreshCounts()
        var badges: [String: Int?] {
            Dictionary(uniqueKeysWithValues: m.sidebar.flatMap(\.items).map { ($0.title, $0.badge) })
        }
        #expect(badges["All"] == 2 && badges["Screenshots"] == 2)
        // A pass that found nothing says 0; an empty queue shows no badge.
        #expect(badges["Bursts"] == 0 && badges["In Delete Me Albums"] == .some(nil))
        await m.select(.pass("screenshots"))
        await m.confirmEverySection()
        await m.apply()
        #expect(badges["In Delete Me Albums"] == 1)
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

    @Test func markingOnePhotoKeepsItSelected() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        let ids = m.displayed.map(\.id)
        m.click(ids[0])
        m.togglePreview()
        m.markSelection(.delete)
        #expect(m.decisions[ids[0]] == .delete && m.selected == [ids[0]] && m.preview?.id == ids[0])
        m.markSelection(.unsure)
        #expect(m.decisions[ids[0]] == .unsure && m.selected == [ids[0]])
        m.onlyDelete = true
        m.click(ids[2])
        m.markSelection(.delete)
        m.markSelection(.keep)  // Show Only Delete hides it now, and nothing else is shown
        #expect(m.decisions[ids[2]] == .keep && m.selected.isEmpty)
        m.onlyDelete = false
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

    @Test func sectionsConfirmInAllAndPassesOnly() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), verdicts: ["a": dropV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.all)
        #expect(m.canConfirm)
        await m.select(.pass("screenshots"))
        #expect(m.canConfirm)
        await m.select(.deleted)
        #expect(!m.canConfirm)
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
        #expect(m.preview?.badge == (m.decision(first) == .keep ? "✓ Keep" : "Remove"))
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
        await m.confirmEverySection()  // confirmed photos leave the selection
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

        m.mark(ids, .keep)
        #expect(m.undoManager.undoActionName == "Keep")
        m.undoManager.undo()
        #expect(m.decisions[ids[0]] == .delete && m.decisions[ids[2]] == .keep && m.touched == Set(ids[0...1]))

        // Confirm is undoable too: the photos come back from Pending. Apply is not.
        await m.confirmEverySection()
        #expect(m.pending.count == 3 && m.photos.isEmpty && lib.adds.withLock { $0 }.isEmpty)
        #expect(m.undoManager.undoActionName == ReviewModel.confirmLabel)
        m.undoManager.undo()
        #expect(m.pending.isEmpty && m.photos.count == 3)
        m.undoManager.redo()
        await m.apply()
        #expect(lib.adds.withLock { $0 }.count == 2 && !m.undoManager.canUndo)

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
        await m.confirmEverySection()  // n joins the list this session
        await m.apply()
        await m.select(.deleted)
        #expect(m.canDeleteInPhotos)
        await m.deleteInPhotos()
        #expect(lib.deletes.withLock { $0 }.flatMap { $0 }.sorted() == ["n", "s", "u"])
        #expect(m.deleted.isEmpty && m.displayed.isEmpty && !m.canDeleteInPhotos)
        #expect(m.summary == "0 in Delete Me albums")
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
        m.mark(m.photos.map(\.id), .delete)
        await m.confirmEverySection()
        await m.apply()
        await m.select(.deleted)
        #expect(m.deleted.map(\.id).sorted() == ["n", "s", "u"])
        #expect(m.deletedAlbum["n"] == "Screenshots - Delete Me")
    }
}

@MainActor

@Suite struct ConfirmSectionTests {
    @Test func returnOnEachSectionFilesEveryPhoto() async throws {
        let month = 40 * 86400.0
        let clips = [
            Photo(uuid: "s", date: t0, isMovie: true, duration: 1),
            Photo(uuid: "a", date: t0 + month, isMovie: true, duration: 30),
            Photo(uuid: "b", date: t0 + 2 * month, isMovie: true, duration: 30),
        ]
        let (c, _) = try await makeCleanup(clips)
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("videos"))
        #expect(m.groups.count == 3 && m.summary == "3 photos · keeping 2 · removing 1")
        for n in (1...3).reversed() {
            #expect(m.focusPosition == "Month 1 of \(n)")
            await m.confirm()  // Return: the next month comes up
        }
        #expect(m.photos.isEmpty && m.showsEmptyState && m.emptyStateLabel == ReviewModel.emptyState)
        #expect(m.pending.mapValues(\.keep) == ["s": false, "a": true, "b": true])
        #expect(Set(m.pending.values.map(\.pass)) == ["videos"])
    }

    @Test func confirmFilesOnlyItsSection() async throws {
        let month = 40 * 86400.0
        let clips = [
            Photo(uuid: "a", date: t0, isMovie: true, duration: 30),
            Photo(uuid: "b", date: t0 + month, isMovie: true, duration: 30),
        ]
        let (c, _) = try await makeCleanup(clips)
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("videos"))
        let first = try #require(m.groups.first)
        await m.confirm(first)
        #expect(m.pending.mapValues(\.keep) == ["b": true] && m.photos.map(\.id) == ["a"])  // newest month first
    }

    @Test func unsureStaysWhenItsSectionIsConfirmed() async throws {
        let clips = [
            Photo(uuid: "s", date: t0, isMovie: true, duration: 1),
            Photo(uuid: "a", date: t0 + 1, isMovie: true, duration: 30),
            Photo(uuid: "b", date: t0 + 2, isMovie: true, duration: 30),
        ]
        let (c, _) = try await makeCleanup(clips)
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        await m.select(.pass("videos"))
        m.mark(["b"], .unsure)
        #expect(m.summary == "3 photos · keeping 1 · removing 1 · 1 unsure")
        m.click("b")
        m.togglePreview()
        #expect(m.preview?.badge == "? Unsure" && m.inspectorInfo()?.target == nil)
        m.onlyUnsure = true
        #expect(m.shownPhotos.map(\.id) == ["b"])
        m.onlyDelete = true  // one filter at a time
        #expect(!m.onlyUnsure && m.shownPhotos.map(\.id) == ["s"])
        m.onlyDelete = false
        await m.confirm(m.groups[0])
        #expect(m.pending == ["s": Pending(pass: "videos", keep: false), "a": Pending(pass: "videos", keep: true)])
        #expect(m.photos.map(\.id) == ["b"] && m.decisions == ["b": .unsure])
        #expect(m.showsEmptyState)  // a section left with only Unsure photos isn't shown
        m.onlyUnsure = true
        await m.confirm(m.groups[0])  // only Unsure left: nothing is filed, and the status bar says why
        #expect(
            m.photos.map(\.id) == ["b"]
                && m.status
                    == "Nothing to accept in this month: every photo is Unsure. Mark one with ⌫, or press K to keep them all."
        )
        m.mark(["b"], .keep)

        await m.select(.all)
        m.mark(["b"], .unsure)  // All has Unsure too; s and a wait in Pending, so All leaves them out
        #expect(m.canMarkUnsure && m.photos.map(\.id) == ["b"] && m.summary == "1 photo · 1 unsure")
    }

    @Test func headerCountsAndLabels() async throws {
        let (c, _) = try await makeCleanup([Photo(uuid: "a", screenshot: true)], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        #expect(m.summary == "1 photo · keeping 1 · removing 0" && m.showsHeader && m.windowSubtitle.isEmpty)
        #expect(m.windowTitle == "Screenshots")
        m.mark(["a"], .delete)
        #expect(m.summary == "1 photo · keeping 0 · removing 1")
    }

    @Test func marksSurviveSwitchingViews() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b", "c"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        m.mark(["a"], .delete)
        m.mark(["b"], .keep)
        await m.select(.all)
        m.mark(["a", "c"], .delete)
        await m.select(.pass("videos"))
        await m.select(.pass("screenshots"))
        #expect(m.decisions == ["a": .delete, "b": .keep, "c": .keep] && m.touched == ["a", "b"])
        #expect(m.summary == "3 photos · keeping 2 · removing 1")
        await m.select(.all)
        #expect(m.decisions == ["a": .delete, "c": .delete])
        await m.select(.pass("screenshots"))
        await m.confirm(m.groups[0])  // confirmed photos aren't restored as marks later
        await m.select(.all)
        await m.select(.pass("screenshots"))
        #expect(m.photos.isEmpty && m.touched.isEmpty)
        await m.select(.all)
        #expect(m.decisions.isEmpty)  // all three are in Pending now: their All marks are gone
    }
}

@Suite struct BurstHeaderTests {
    let us = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!

    @Test func date() {
        let g = BurstGroup(photos: dated(["b": 60, "a": 0, "c": 120]), best: "a")
        #expect(g.dateLabel(locale: us, timeZone: utc) == "Jan 1, 2024")
    }

    @Test func timeZoneShiftsTheDay() {
        let g = BurstGroup(photos: dated(["a": 0, "b": 1]), best: "a")
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(g.dateLabel(locale: us, timeZone: la) == "Dec 31, 2023")
    }

    @Test func undated() {
        #expect(BurstGroup(photos: [Photo(uuid: "a")], best: "a").dateLabel(locale: us, timeZone: utc) == nil)
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
        m.click("a")
        m.click("b", toggle: true)
        #expect(m.inspectorInfo() == nil && m.inspectorPlaceholder == "2 photos selected")

        m.click("a")
        let utc = TimeZone(identifier: "UTC")!
        let i = try #require(m.inspectorInfo(locale: Locale(identifier: "en_US"), timeZone: utc))
        #expect(i.date.hasPrefix("January 1, 1970") && i.kind == "Screenshot")
        #expect(i.verdict == nil && i.albums == "In no album")  // the Why section says it
        #expect(m.why == ReviewModel.Why(id: "a", lines: ["Apple Intelligence suggests removing it: r"]))
        #expect(i.target == "→ \(Passes.deleteAlbum("screenshots")!)" && i.decision == .delete)

        m.click("b")  // unjudged: Confirm files it in Keep
        let j = try #require(m.inspectorInfo())
        #expect(j.albums == "In no album" && j.verdict == nil && j.decision == .keep)
        #expect(j.target == "→ \(Passes.keepAlbum("screenshots")!)")

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
        #expect(label("a").hasPrefix("Screenshot, January 1, 1970") && label("a").hasSuffix(", marked Remove, junk: r"))
        await m.select(.pass("videos"))
        #expect(label("v") == "Video, 0:05, Unknown date, marked Keep")
        await m.select(.all)
        m.mark(["d"], .delete)
        await m.confirmEverySection()
        await m.apply()
        await m.select(.all)  // applied: back in All, in its Delete Me album
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
        #expect(m.decisions.isEmpty && m.canMark && m.focusPosition == nil)
        m.mark(["a", "b"], .delete)
        m.mark(["b"], .keep)  // Keep clears the mark in All
        #expect(m.decisions == ["a": .delete])
        m.undoManager.undo()
        #expect(m.decisions == ["a": .delete, "b": .delete])
        m.undoManager.redo()
        #expect(m.decisions == ["a": .delete])
        m.click("a")
        #expect(m.inspectorInfo()?.target == "→ \(album)" && m.inspectorInfo()?.decision == .delete)
        m.click("c")
        #expect(m.inspectorInfo()?.target == nil && m.inspectorInfo()?.decision == .keep)
        await m.confirmEverySection()
        #expect(m.pending == ["a": Pending(pass: Passes.allKey, keep: false)])
        await m.apply()
        let adds = lib.adds.withLock { $0 }
        #expect(adds.map(\.album) == [album] && adds[0].uuids == ["a"])
        #expect(m.photos.count == 2 && m.decisions.isEmpty)  // it left All when confirmed
        #expect(m.deletedAlbum["a"] == album && m.deleted.map(\.id) == ["a"])
        #expect(m.status == "Applied 1 photo to their albums in Photos.")
        #expect(badge(m, .deleted) == 1 && badge(m, .pending) == nil)
        await m.select(.all)  // applied: back in All, in its Delete Me album
        #expect(m.photos.count == 3 && m.deletedAlbum["a"] == album)
    }

    @Test func kKeepsOnePhotoInAll() async throws {
        let (c, _) = try await makeCleanup(shots("a", "b"), judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.all)
        m.mark(["a", "b"], .delete)
        m.click("a")
        #expect(m.keepKeyLabel == "Keep")
        await m.keepKey()  // clears a's mark; nothing is accepted
        #expect(m.decisions == ["b": .delete] && m.pending.isEmpty)
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
        #expect(m.emptyStateLabel == "Nothing marked Remove.")
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
            == "We recommend removing clips under 2 seconds, which are usually accidental, and keeping the rest."
    )
    #expect(
        m.captionHelp
            == "Your videos, longest first. Clips under 2 seconds are marked Remove: they are usually accidental. Favorites are never suggested."
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
    #expect(m.summary == "\(1200.formatted()) photos · keeping \(199.formatted()) · removing \(1001.formatted())")
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

    @Test func aNumberPicksTheBestWithoutConfirming() async throws {
        let (m, _, _) = try await twoBursts()
        m.undoManager.groupsByEvent = false
        let g = try #require(m.groups.first { $0.photos.count == 3 })
        let other = try #require(m.groups.first { $0.photos.count == 2 })
        let before = other.photos.map { m.decision($0.id) }
        m.click(other.photos[0].id)
        m.pickBest(number: 9)  // the group has 2 photos: nothing happens
        #expect(other.photos.map { m.decision($0.id) } == before && !m.canUndo)
        m.click(g.photos[0].id)
        m.pickBest(number: 3)
        let ids = g.photos.map(\.id)
        #expect(ids.map { m.decision($0) } == [.delete, .delete, .keep] && ids.map(m.isBest) == [false, false, true])
        #expect(m.pending.isEmpty)  // not confirmed: Return does that
        m.undoManager.undo()
        #expect(ids.map { m.decision($0) } == [.keep, .delete, .delete] && ids.map(m.isBest) == [true, false, false])
        m.undoManager.redo()
        #expect(ids.map(m.isBest) == [false, false, true])
        await m.select(.all)
        await m.select(.pass("bursts"))  // the pick survives switching views
        #expect(ids.map(m.isBest) == [false, false, true] && ids.map { m.decision($0) } == [.delete, .delete, .keep])
    }

    @Test func allSectionsConfirmOnlyTheirDeleteMarks() async throws {
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        let photos = [
            Photo(uuid: "a", date: at("2026-10-20T12:00:00Z")), Photo(uuid: "b", date: at("2026-10-15T12:00:00Z")),
            Photo(uuid: "c", date: at("2024-03-05T12:00:00Z")),
        ]
        let (c, lib) = try await makeCleanup(photos, judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        m.undoManager.groupsByEvent = false  // no run loop here to close the groups
        await m.select(.all)
        #expect(m.groups.count == 2 && m.canConfirm)
        let oct = try #require(m.groups.first { $0.photos.count == 2 })
        await m.confirm(try #require(m.groups.last))  // nothing marked: nothing is filed, and the status bar says why
        #expect(m.pending.isEmpty && m.status == "Nothing to accept in this month: mark photos Remove (⌫) first.")
        m.mark(["c"], .delete)
        m.mark(["a", "c"], .delete)
        await m.confirm(oct)
        #expect(m.pending == ["a": Pending(pass: Passes.allKey, keep: false)])  // b is unmarked: not filed
        #expect(m.photos.map(\.id).sorted() == ["b", "c"])  // a left All, like a pass
        m.undoManager.undo()
        #expect(m.pending.isEmpty && m.photos.count == 3)
        m.undoManager.redo()
        #expect(m.photos.count == 2 && m.decisions == ["c": .delete])
        await m.confirmEverySection()
        #expect(m.pending.keys.sorted() == ["a", "c"] && m.pending.values.allSatisfy { !$0.keep })
        #expect(m.album(m.pending["a"]!) == "All - Delete Me")
        await m.apply()
        #expect(sent(lib) == ["All - Delete Me": ["a", "c"]])
    }

    @Test func passesWithoutGroupsShowMonthsNewestFirstInTheirOwnOrder() async throws {
        let photos = dated(["p1": 0, "p2": 40 * 86_400, "p3": 3_600])
        let (c, _) = try await makeCleanup(photos, vision: ["p1": vr(-0.9), "p2": vr(-0.8), "p3": vr(-0.95)])
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        await m.select(.pass("low-quality"))
        #expect(m.groups.map { $0.photos.map(\.id) } == [["p2"], ["p3", "p1"]])  // worst first within a month
        #expect(m.photos.map(\.id) == ["p2", "p3", "p1"])
        let g = m.groups[0]
        #expect(m.confirmHelp(g) == "Accept this month (Return)" && !m.canPickBest)
        #expect(m.confirmHelp(m.groups[1]) == "Accept this month")
    }

    @Test func theSelectedGroupShowsItsKeyNumbers() async throws {
        let (m, _, _) = try await twoBursts()
        let (a, b) = (m.groups[0], m.groups[1])
        #expect(m.isCurrent(a) && a.photos.map { m.keyNumber($0.id) } == Array(1...a.photos.count))
        #expect(b.photos.allSatisfy { m.keyNumber($0.id) == nil })
        m.click(b.photos[1].id)
        #expect(m.isCurrent(b) && m.keyNumber(b.photos[1].id) == 2 && m.keyNumber(a.photos[0].id) == nil)
        #expect(m.confirmHelp(a) == "Accept this group" && m.confirmHelp(b) == "Accept this group (Return)")
        #expect(m.pickBestHelp(b.photos[1].id).hasSuffix("(2)") && m.canPickBest)
    }

    @Test func confirmOnASectionNeedsNoSelection() async throws {
        let (m, _, _) = try await twoBursts()
        let gs = m.groups
        m.clearSelection()
        await m.confirm(gs[0])
        #expect(Set(m.pending.keys) == Set(gs[0].photos.map(\.id)) && m.groups.map(\.best) == [gs[1].best])
    }

    @Test func aPassShowsOneSectionAndSkipsThoseLeftUnsure() async throws {
        let (m, _, _) = try await twoBursts()
        let (a, b) = (m.groups[0], m.groups[1])
        #expect(m.currentGroup?.best == a.best && m.focusPosition == "Burst 1 of 2")
        m.click(a.photos[0].id)
        m.moveSelection(by: 5)  // the arrows stay in the section on screen
        #expect(m.anchor == a.photos.last?.id)
        m.mark([a.photos[1].id], .unsure)
        await m.confirm()  // the Unsure photo stays; its section is skipped
        #expect(m.groups.count == 2 && m.currentGroup?.best == b.best && m.focusPosition == "Burst 1 of 1")
        m.moveSection(by: -1)
        #expect(m.currentGroup?.best == b.best)
        await m.confirm()
        #expect(m.showsEmptyState && m.emptyStateLabel.contains("1 marked Unsure"))
        m.onlyUnsure = true  // Show Only Unsure brings it back
        #expect(m.currentGroup?.photos.map(\.id) == [a.photos[1].id] && !m.showsEmptyState)
    }

    @Test func kKeepsTheWholeSectionAndAcceptsIt() async throws {
        let (m, _, _) = try await twoBursts()
        m.undoManager.groupsByEvent = false
        let a = m.groups[0]
        #expect(m.keepKeyLabel == ReviewModel.keepAllLabel && m.canKeepKey)
        await m.keepKey()
        #expect(m.pending.keys.sorted() == a.photos.map(\.id).sorted() && m.pending.values.allSatisfy(\.keep))
        #expect(m.groups.count == 1 && m.undoManager.undoActionName == ReviewModel.keepAllLabel)
        m.undoManager.undo()  // one undo: back in the pass, with Vision's marks
        #expect(m.pending.isEmpty && m.groups.count == 2)
        #expect(a.photos.map { m.decision($0.id) } == [.keep, .delete] && m.touched.isEmpty)
    }

    @Test func pickBestThenConfirmFilesOnlyThatPhotoAsKeep() async throws {
        let (m, _, _) = try await twoBursts()
        let gs = m.groups
        let pick = gs[1].photos[1].id
        m.pickBest(pick)
        await m.confirm(gs[1])
        #expect(Set(m.pending.keys) == Set(gs[1].photos.map(\.id)))
        #expect(gs[1].photos.allSatisfy { m.pending[$0.id]?.keep == ($0.id == pick) })
        #expect(m.groups.map(\.best) == [gs[0].best])
    }

    @Test func undoStateFollowsTheLastActionAndClearsAfterUndo() async throws {
        let (m, _, _) = try await twoBursts()
        m.undoManager.groupsByEvent = false  // no run loop here to close the groups
        #expect(!m.canUndo && m.undoHelp == "Nothing to undo")
        await m.confirm()
        #expect(m.canUndo && m.undoName == ReviewModel.confirmLabel && m.undoHelp == "Undo Accept (⌘Z)")
        m.undoManager.undo()
        #expect(!m.canUndo && m.undoHelp == "Nothing to undo")
        m.undoManager.redo()
        #expect(m.canUndo)
    }
}

@MainActor
@Suite struct KeepLanguageTests {
    let en = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!

    /// Two bursts a day apart, newest first: q (★), p and y (★), x, z.
    private func twoBursts() async throws -> ReviewModel {
        let photos = dated(["x": 0, "y": 1, "z": 2, "p": 86_400, "q": 86_401])
        let (c, _) = try await makeCleanup(
            photos, vision: ["x": vr(0.1), "y": vr(0.9), "z": vr(0.2), "p": vr(0.1), "q": vr(0.8)])
        let m = ReviewModel(cleanup: c, dir: tempDir(), defaults: freshDefaults())
        await m.select(.pass("bursts"))
        return m
    }

    @Test func headersCountWhatIsKeptAndRemoved() async throws {
        let m = try await twoBursts()
        #expect(m.summary == "5 photos · keeping 2 · removing 3")
        #expect(
            m.groups.map { m.header($0, locale: en, timeZone: utc) } == [
                "Jan 2, 2024 · keeping 1 · removing 1 similar photo",
                "Jan 1, 2024 · keeping 1 · removing 2 similar photos",
            ])
        m.mark(["x"], .unsure)
        m.mark(["p"], .keep)
        m.onlyDelete = true  // the header counts the whole group, not what the filter shows
        #expect(
            m.shownGroups.map { m.header($0, locale: en, timeZone: utc) } == [
                "Jan 1, 2024 · keeping 1 · removing 1 similar photo · 1 unsure"
            ])
        m.onlyDelete = false
        #expect(m.header(m.groups[0], locale: en, timeZone: utc) == "Jan 2, 2024 · keeping 2")
        #expect(m.othersLabel == "Other shots from this burst")
        await m.select(.all)
        #expect(m.summary == "5 photos" && m.othersLabel == nil)
        m.mark(["x"], .delete)
        #expect(m.summary == "5 photos · removing 1")
    }

    @Test func whyThisPhotoNamesOnlyWhatWasMeasured() async throws {
        let m = try await twoBursts()
        // Nothing selected: the current group's ★. No faces in these bursts, so no face line.
        #expect(
            m.why
                == ReviewModel.Why(
                    id: "q", lines: ["Highest Vision aesthetics score in the group: 0.80 (next best 0.10)"]))
        m.click("y")
        #expect(m.why?.lines == ["Highest Vision aesthetics score in the group: 0.90 (next best 0.20)"])
        #expect(m.inspectorInfo()?.score == nil)  // the Why section says it
        m.click("x")
        #expect(m.why == nil && m.inspectorInfo()?.score == m.scoreLine("x") && m.scoreLine("x") != nil)
        m.pickBest("x")
        #expect(
            m.why?.lines == [
                "You picked it as the best shot.", "Vision aesthetics score 0.10 (best in the group 0.90)",
            ])
        m.selectAll()
        #expect(m.why == nil)
    }

    @Test func whyThisPhotoNamesFacesAndEdits() async throws {
        let (c, _) = try await makeCleanup(
            dated(["a": 0, "b": 1]), vision: ["a": vr(0.2, face: 0.8), "b": vr(0.6, face: 0.3)])
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("bursts"))
        #expect(
            m.why
                == ReviewModel.Why(
                    id: "a",
                    lines: [
                        "Best face quality in the group: 0.80 (next best 0.30)",
                        "Vision aesthetics score 0.20 (best in the group 0.60)",
                    ]))

        var burst = dated(["e": 0, "f": 1])
        burst[0].edited = true
        let (c2, _) = try await makeCleanup(burst, vision: ["e": vr(0.1), "f": vr(0.9)])
        let m2 = ReviewModel(cleanup: c2, dir: tempDir())
        await m2.select(.pass("bursts"))
        #expect(
            m2.why?.lines == ["You edited it in Photos.", "Vision aesthetics score 0.10 (best in the group 0.90)"])
        await m2.select(.pass("similar"))
        #expect(m2.othersLabel == "Other shots from this moment")
    }

    @Test func whyThisPhotoGivesTheVerdictReasonAndNothingWithoutOne() async throws {
        let (c, _) = try await makeCleanup(
            shots("k", "n"), verdicts: ["k": keepV], judge: FakeJudge(off: "off"))
        let m = ReviewModel(cleanup: c, dir: tempDir())
        await m.select(.pass("screenshots"))
        #expect(m.why == nil)  // nothing selected outside Bursts and Similar
        m.click("k")
        #expect(m.why?.lines == ["Apple Intelligence suggests keeping it: r"] && m.inspectorInfo()?.verdict == nil)
        m.click("n")
        #expect(m.why == nil && m.inspectorInfo() != nil)
    }
}
