import Foundation
import Hummingbird
import PhotosCleanupCore

/// The HTTP API over Core. Same origin only: no CORS headers, so other websites can't call it.
public func buildRouter(cleanup: Cleanup, uiDir: URL?) -> Router<BasicRequestContext> {
    let router = Router()
    router.add(middleware: HostAllowlist())
    if let uiDir {
        router.add(middleware: FileMiddleware(uiDir.path, searchForIndexHtml: true))
    }

    router.get("health") { _, _ in json(["ok": true]) }

    router.get("photos") { _, _ in
        let photos = await cleanup.photos
        return json(["total": photos.count, "photos": photos.map(meta)])
    }

    router.get("thumb/:uuid") { _, ctx in
        let uuid = try ctx.parameters.require("uuid")
        guard let file = await cleanup.thumbnail(uuid), let data = try? Data(contentsOf: file) else {
            throw HTTPError(.notFound)
        }
        return Response(
            status: .ok, headers: [.contentType: "image/jpeg"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    router.get("counts") { _, _ in
        json(await cleanup.counts().mapValues { $0.map { $0 as Any } ?? NSNull() })
    }

    router.get("cleanup/:kind") { req, ctx in
        let kind = try ctx.parameters.require("kind")
        let threshold = req.uri.queryParameters["threshold"].flatMap { Double(String($0)) }
        let result: PassResult
        do {
            result = try await cleanup.pass(kind, threshold: threshold ?? Passes.lowQualityMax)
        } catch CleanupError.unknownPass {
            return detail("unknown cleanup kind", .notFound)
        }
        let progress = progressJSON(result.progress)
        if kind == "bursts" {
            let groups = result.groups.map { g in ["photos": g.photos.map(meta), "best": g.best] as [String: Any] }
            let count = result.groups.reduce(0) { $0 + $1.photos.count }
            return json(["kind": kind, "count": count, "groups": groups, "classify": progress])
        }
        let photos = result.photos.map { p in
            meta(p.photo).merging(["verdict": p.verdict.map(verdictJSON) ?? NSNull()]) { $1 }
        }
        return json(["kind": kind, "count": photos.count, "photos": photos, "classify": progress])
    }

    struct CommitRequest: Decodable {
        var kind: String
        var uuids: [String]?
        var keep: [String]?
    }

    router.post("commit") { req, ctx in
        let body = try await req.decode(as: CommitRequest.self, context: ctx)
        do {
            let c = try await cleanup.commit(body.kind, delete: body.uuids ?? [], keep: body.keep ?? [])
            return json(["added": c.added, "album": c.album, "kept": c.kept, "keep_album": c.keepAlbum])
        } catch let e as CleanupError {
            switch e {
            case .unknownPass: return detail("unknown cleanup kind", .notFound)
            case .noMatchingPhotos: return detail("no matching photos", .badRequest)
            case .accessDenied:
                return detail(
                    "Photos access is off. Turn it on for your terminal app in System Settings "
                        + "> Privacy & Security > Photos, then commit again.", .forbidden)
            case .failed(let why): return detail("Adding to album failed: \(why)", .internalServerError)
            }
        }
    }

    router.get("verdict-stats") { _, _ in
        json(await cleanup.verdictStats().mapValues { ["agree": $0.agree, "total": $0.total] })
    }
    return router
}

/// Blocks DNS rebinding: an attacker domain resolved to 127.0.0.1 would otherwise be same-origin.
struct HostAllowlist<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response)
        async throws -> Response
    {
        guard isAllowedHost(request.head.authority) else { return detail("Invalid host header", .badRequest) }
        return try await next(request, context)
    }
}

/// The request's Host (its authority), without the port, must be the loopback name we serve.
func isAllowedHost(_ authority: String?) -> Bool {
    guard let host = authority?.split(separator: ":").first else { return false }
    return ["127.0.0.1", "localhost"].contains(String(host))
}

func meta(_ p: Photo) -> [String: Any] {
    [
        "uuid": p.uuid, "width": p.width, "height": p.height, "is_video": p.isMovie,
        "date": p.date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
    ]
}

func verdictJSON(_ v: Verdict) -> [String: Any] { ["keep": v.keep, "kind": v.kind, "reason": v.reason] }

func progressJSON(_ p: JobProgress) -> [String: Any] {
    ["pending": p.pending, "total": p.total, "error": p.error ?? NSNull()]
}

func json(_ obj: Any, _ status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return Response(
        status: status, headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

/// Errors carry {"detail": ...}, which the UI shows on a failed commit.
func detail(_ message: String, _ status: HTTPResponse.Status) -> Response { json(["detail": message], status) }
