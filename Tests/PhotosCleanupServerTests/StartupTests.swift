import Foundation
import Hummingbird
import PhotosCleanupCore
import Testing

@testable import PhotosCleanupServer

// MARK: arguments

@Test func parsesDefaults() throws {
    #expect(try parseOptions([]) == Options())
    #expect(Options().port == 8765 && Options().openBrowser && !Options().dev)
}

@Test func parsesPortAndNoBrowser() throws {
    let o = try parseOptions(["--port", "9000", "--no-browser"])
    #expect(o.port == 9000 && !o.openBrowser && !o.dev && o.action == .run)
}

@Test func devImpliesNoBrowser() throws {
    let o = try parseOptions(["--dev"])
    #expect(o.dev && !o.openBrowser)
}

@Test func versionAndHelp() throws {
    #expect(try parseOptions(["--version"]).action == .version)
    #expect(try parseOptions(["-h"]).action == .help)
    #expect(try parseOptions(["--help"]).action == .help)
}

@Test func rejectsBadArguments() {
    #expect(throws: StartupError(message: "unknown option --bogus\n\(usage)")) { try parseOptions(["--bogus"]) }
    #expect(throws: StartupError(message: "--port needs a number")) { try parseOptions(["--port"]) }
    #expect(throws: StartupError(message: "--port needs a number")) { try parseOptions(["--port", "x"]) }
}

// MARK: port

/// A TCP listener on a free loopback port that accepts connections and never answers.
final class SilentListener {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    private(set) var port = 0
    init() {
        var addr = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
            sin_addr: in_addr(s_addr: UInt32(0x7f00_0001).bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = bind(fd, sa, size)
                listen(fd, 8)
                var len = size
                _ = getsockname(fd, sa, &len)
            }
        }
        port = Int(UInt16(bigEndian: addr.sin_port))
    }
    deinit { close(fd) }
}

@Test func freePortIsFree() async {
    let port = SilentListener().port  // the listener is gone again after this line
    #expect(await portState(port: port) == .free)
}

@Test func silentListenerIsForeign() async {
    let listener = SilentListener()
    #expect(await portState(port: listener.port) == .foreign)
}

@Test func ourOwnServerIsOurs() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-startup-\(UUID().uuidString)")
    let cleanup = Cleanup(library: Library(all: []), judge: Judge(), cacheDir: dir, ignoreAlbums: [], verdictsOff: "off")
    let (ports, send) = AsyncStream<Int>.makeStream()
    let app = Application(
        router: buildRouter(cleanup: cleanup, uiDir: nil),
        configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { send.yield($0.localAddress?.port ?? 0) }
    )
    let server = Task { try await app.runService() }
    let port = await ports.first { _ in true } ?? 0
    #expect(port != 0)
    #expect(await portState(port: port) == .ours)
    server.cancel()
    _ = try? await server.value
}

@Test func portOutcomes() {
    #expect(portOutcome(.free, port: 9000) == .proceed)
    #expect(portOutcome(.ours, port: 9000) == .alreadyRunning(url: "http://127.0.0.1:9000/"))
    #expect(portOutcome(.foreign, port: 9000) == .fail("port 9000 is in use by another program. Pick another with --port."))
}

// MARK: Photos access

@Test func authorizedHasNoProblem() {
    #expect(accessProblem(status: "authorized", terminal: "Ghostty") == nil)
}

@Test func deniedNamesStatusAndSettingsPath() throws {
    let message = try #require(accessProblem(status: "denied", terminal: "Ghostty"))
    #expect(message.contains("Photos access is denied"))
    #expect(message.contains("Privacy & Security > Photos"))
    #expect(message.contains("turn on Ghostty"))
}

// MARK: UI directory

private func fakeInstall(withIndex: Bool = true) throws -> (root: URL, binary: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-ui-\(UUID().uuidString)")
    let bundle = root.appendingPathComponent("bin/photos-cleanup_PhotosCleanup.bundle")
    let dist = bundle.appendingPathComponent("Contents/Resources/ui/dist")
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    // Bundle(url:) needs an Info.plist to accept the directory as a bundle.
    try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    try Data().write(to: root.appendingPathComponent("bin/photos-cleanup"))
    if withIndex { try Data("<html></html>".utf8).write(to: dist.appendingPathComponent("index.html")) }
    return (root, root.appendingPathComponent("bin/photos-cleanup"))
}

@Test func findsUIBesideBinary() throws {
    let (root, binary) = try fakeInstall()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try #require(uiDirectory(executable: binary))
    #expect(dir.path.hasSuffix("ui/dist") && FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path))
}

@Test func findsUIThroughSymlinkedBinary() throws {
    let (root, binary) = try fakeInstall()
    defer { try? FileManager.default.removeItem(at: root) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
    let linked = link.appendingPathComponent("photos-cleanup")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: binary)
    #expect(uiDirectory(executable: linked) != nil)
}

@Test func missingUIIsNil() throws {
    let (root, binary) = try fakeInstall(withIndex: false)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(uiDirectory(executable: binary) == nil)  // bundle without index.html
    #expect(uiDirectory(executable: root.appendingPathComponent("elsewhere/photos-cleanup")) == nil)  // no bundle
    #expect(uiDirectory(executable: nil) == nil)
    #expect(uiMissing.contains("pnpm build"))
}
