import Foundation

/// The decisions behind the `photos-cleanup` command's startup checks, kept out of
/// `main.swift` (top-level code, untestable) so they can be tested. `main.swift` only acts on them.

public let usage = """
    usage: photos-cleanup [--port N] [--no-browser] [--dev] [--version]

    Review and clear unwanted photos in your Photos library, in your browser.

      --port N      local port (default: 8765)
      --no-browser  don't open the browser
      --dev         API only, for `pnpm dev` (implies --no-browser)
    """

public struct Options: Equatable {
    public enum Action: Equatable { case run, version, help }
    public var action = Action.run
    public var port = 8765
    public var openBrowser = true
    public var dev = false
}

/// A message for the user; the command prints it after `photos-cleanup: ` and exits 1.
public struct StartupError: Error, Equatable { public let message: String }

public func parseOptions(_ arguments: [String]) throws -> Options {
    var o = Options()
    var args = ArraySlice(arguments)
    while let arg = args.popFirst() {
        switch arg {
        case "--port":
            guard let p = args.popFirst().flatMap(Int.init) else { throw StartupError(message: "--port needs a number") }
            o.port = p
        case "--no-browser": o.openBrowser = false
        case "--dev": (o.dev, o.openBrowser) = (true, false)
        case "--version": return Options(action: .version)
        case "-h", "--help": return Options(action: .help)
        default: throw StartupError(message: "unknown option \(arg)\n\(usage)")
        }
    }
    return o
}

public enum PortState: Equatable { case free, ours, foreign }

/// Asks whatever is on `port`: connection refused is free; our `/health` answer is ours;
/// anything else (no answer, another protocol, other JSON) is foreign.
public func portState(port: Int) async -> PortState {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    req.timeoutInterval = 2
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool] == ["ok": true] ? .ours : .foreign
    } catch let e as URLError where e.code == .cannotConnectToHost {
        return .free
    } catch {
        return .foreign
    }
}

public enum PortOutcome: Equatable {
    case proceed
    case alreadyRunning(url: String)  // print "Already running at <url>", reopen the UI, exit 0
    case fail(String)
}

public func portOutcome(_ state: PortState, port: Int) -> PortOutcome {
    switch state {
    case .free: .proceed
    case .ours: .alreadyRunning(url: "http://127.0.0.1:\(port)/")
    case .foreign: .fail("port \(port) is in use by another program. Pick another with --port.")
    }
}

/// The message for a Photos authorization `status` other than "authorized"; nil when access is fine.
public func accessProblem(status: String, terminal: String) -> String? {
    guard status != "authorized" else { return nil }
    return """
        can't read your Photos library: Photos access is \(status).
          In System Settings > Privacy & Security > Photos, turn on \(terminal)
          with "Full Access", then run photos-cleanup again.
        """
}

public let uiMissing = "the web UI is missing. In a source checkout, run `pnpm build` (or use --dev)."

/// The built UI, shipped in SwiftPM's resource bundle beside the real binary. Found by hand, not
/// via Bundle.module, which traps when the bundle is missing instead of letting the caller explain.
/// Nil when there is no bundle or no `index.html` in it.
public func uiDirectory(executable: URL?) -> URL? {
    let bundle = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("photos-cleanup_PhotosCleanup.bundle")
    let dist = bundle.flatMap { Bundle(url: $0)?.url(forResource: "ui", withExtension: nil) }?
        .appendingPathComponent("dist")
    guard let dist, FileManager.default.fileExists(atPath: dist.appendingPathComponent("index.html").path) else {
        return nil
    }
    return dist
}
