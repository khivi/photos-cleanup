import Foundation
import Hummingbird
import HummingbirdTesting
import PhotosCleanupCore
import Testing

@testable import PhotosCleanupServer

struct Library: PhotoLibrary {
    var all: [Photo]
    var status = "authorized"
    func authorize() async -> String { status }
    func photos() throws -> [Photo] { all }
    func jpeg(_ uuid: String, maxSide: Int) -> Data? { Data([0xFF, 0xD8, 0xFF]) }
    func vision(_ uuids: [String]) -> [String: VisionResult?] {
        Dictionary(uniqueKeysWithValues: uuids.map { ($0, VisionResult(print: [0], utility: false, score: -0.9)) })
    }
    func add(album: String, uuids: [String]) throws -> Int {
        guard status == "authorized" else { throw LibraryError.accessDenied }
        return uuids.count
    }
}

struct Judge: PhotosCleanupCore.Judge {
    func unavailableReason() -> String? { "off" }
    func judge(_ photo: Photo) async -> Verdict? { nil }
}

func app(_ photos: [Photo] = [], status: String = "authorized") async throws -> some ApplicationProtocol {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-routes-\(UUID().uuidString)")
    let cleanup = Cleanup(library: Library(all: photos, status: status), judge: Judge(), cacheDir: dir,
                          ignoreAlbums: [], verdictsOff: "off")
    try await cleanup.load()
    return Application(router: buildRouter(cleanup: cleanup, uiDir: nil))
}

let localhost: HTTPFields = [:]  // the test client sends authority "localhost" itself

func body(_ r: TestResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(buffer: r.body))) as? [String: Any] ?? [:]
}

@Test func health() async throws {
    try await app().test(.router) { client in
        let r = try await client.execute(uri: "/health", method: .get, headers: localhost)
        #expect(r.status == .ok && body(r)["ok"] as? Bool == true)
    }
}

@Test func onlyLoopbackHostsAreAllowed() {
    // The test clients always send authority "localhost", so the check is tested directly; the
    // middleware applies it to every request.
    #expect(isAllowedHost("127.0.0.1:8765") && isAllowedHost("localhost:8765") && isAllowedHost("localhost"))
    #expect(!isAllowedHost("evil.example") && !isAllowedHost("evil.example:8765") && !isAllowedHost(nil))
    #expect(!isAllowedHost("127.0.0.1.evil.example:8765"))
}

@Test func sendsNoCORSHeaders() async throws {
    try await app().test(.router) { client in
        let r = try await client.execute(uri: "/health", method: .get, headers: [.origin: "https://evil.example"])
        #expect(r.status == .ok)
        #expect(!r.headers.contains { $0.name.canonicalName.hasPrefix("access-control") })
    }
}

@Test func photosAndThumbs() async throws {
    try await app([Photo(uuid: "a", width: 4, height: 3)]).test(.router) { client in
        let r = try await client.execute(uri: "/photos", method: .get, headers: localhost)
        #expect(body(r)["total"] as? Int == 1)
        let p = (body(r)["photos"] as? [[String: Any]])?.first
        #expect(p?["uuid"] as? String == "a" && p?["width"] as? Int == 4 && p?["is_video"] as? Bool == false)
        #expect(p?["date"] is NSNull)
        let thumb = try await client.execute(uri: "/thumb/a", method: .get, headers: localhost)
        #expect(thumb.status == .ok && thumb.headers[.contentType] == "image/jpeg")
        let missing = try await client.execute(uri: "/thumb/missing", method: .get, headers: localhost)
        #expect(missing.status == .notFound)
    }
}

@Test func cleanupShapes() async throws {
    try await app([Photo(uuid: "a", screenshot: true)]).test(.router) { client in
        let shots = body(try await client.execute(uri: "/cleanup/screenshots", method: .get, headers: localhost))
        #expect(shots["kind"] as? String == "screenshots" && shots["count"] as? Int == 1)
        let p = (shots["photos"] as? [[String: Any]])?.first
        #expect(p?["verdict"] is NSNull)
        let classify = shots["classify"] as? [String: Any]
        #expect(classify?["error"] as? String == "off" && classify?["pending"] as? Int == 0)

        let bursts = body(try await client.execute(uri: "/cleanup/bursts", method: .get, headers: localhost))
        #expect(bursts["groups"] is [Any] && bursts["count"] as? Int == 0)

        let bogus = try await client.execute(uri: "/cleanup/bogus", method: .get, headers: localhost)
        #expect(bogus.status == .notFound && body(bogus)["detail"] as? String == "unknown cleanup kind")
    }
}

@Test func countsUseNullForUnknown() async throws {
    try await app().test(.router) { client in
        let c = body(try await client.execute(uri: "/counts", method: .get, headers: localhost))
        #expect(c["all"] as? Int == 0 && c["screenshots"] as? Int == 0)
        #expect(Set(c.keys) == ["all", "screenshots", "utility", "bursts", "low-quality"])
    }
}

func commit(_ client: some TestClientProtocol, _ json: String) async throws -> TestResponse {
    try await client.execute(
        uri: "/commit", method: .post, headers: localhost.merging([.contentType: "application/json"]),
        body: ByteBuffer(string: json))
}

extension HTTPFields {
    func merging(_ other: HTTPFields) -> HTTPFields {
        var out = self
        out.append(contentsOf: other)
        return out
    }
}

@Test func commitShapesAndErrors() async throws {
    try await app([Photo(uuid: "a"), Photo(uuid: "b")]).test(.router) { client in
        let ok = try await commit(client, #"{"kind":"screenshots","uuids":["a"],"keep":["b"]}"#)
        let b = body(ok)
        #expect(b["added"] as? Int == 1 && b["album"] as? String == "Screenshots - Delete Me")
        #expect(b["kept"] as? Int == 1 && b["keep_album"] as? String == "Screenshots - Keep")
        #expect(try await commit(client, #"{"kind":"bogus","uuids":["a"]}"#).status == .notFound)
        #expect(try await commit(client, #"{"kind":"screenshots","uuids":["x"]}"#).status == .badRequest)
    }
    try await app([Photo(uuid: "a")], status: "denied").test(.router) { client in
        let r = try await commit(client, #"{"kind":"screenshots","uuids":["a"]}"#)
        #expect(r.status == .forbidden)
        #expect((body(r)["detail"] as? String)?.contains("Privacy & Security > Photos") == true)
    }
}
