import Foundation
import Testing

@testable import PhotosCleanupCore

@MainActor
@Suite struct LaunchTests {
    private func run(
        _ library: FakeLibrary, settings: LaunchSettings = LaunchSettings(), judge: FakeJudge = FakeJudge()
    ) async -> LaunchResult {
        await launch(
            library: library, judge: judge, settings: settings, cacheDir: tempDir(), dir: tempDir(),
            defaults: freshDefaults())
    }

    @Test func noAccessReportsTheStatus() async {
        guard case .noAccess(let status) = await run(FakeLibrary(status: "denied")) else {
            Issue.record("expected noAccess")
            return
        }
        #expect(status == "denied")
    }

    @Test func failedLoadReportsTheError() async {
        guard case .failed(let message) = await run(FakeLibrary([Photo(uuid: "a")], failsToLoad: true)) else {
            Issue.record("expected failed")
            return
        }
        #expect(message == "\(LibraryError.failed("library unreadable"))")
    }

    @Test func loadedAppliesSettings() async {
        let library = FakeLibrary([Photo(uuid: "a"), Photo(uuid: "b", isMovie: true)])
        let settings = LaunchSettings(showsInspector: true, zoom: 3, aspectFit: true)
        guard case .loaded(let model, let uuids) = await run(library, settings: settings) else {
            Issue.record("expected loaded")
            return
        }
        #expect(Set(uuids) == ["a", "b"])
        #expect(model.view == .all)
        #expect(model.showsInspector && model.aspectFit && model.zoom == 3)
        #expect(model.cellSize == ReviewModel.zoomSizes[3])
    }

    @Test func loadedKeepsDefaultZoomWithoutASavedOne() async {
        guard case .loaded(let model, _) = await run(FakeLibrary([Photo(uuid: "a")])) else {
            Issue.record("expected loaded")
            return
        }
        #expect(model.zoom == 1)
    }
}
