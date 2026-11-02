import Foundation
import Testing
@testable import AetherEngine

/// `LoadOptions.relaysRemoteHLS`: a host whose headers carry a secret (a reverse proxy's `Authorization`, a
/// Cloudflare Access pair) asks for the relay, because AVPlayer sends the headers it is given to every host a
/// redirect or a playlist names. The relay stands in front of the master with no evaluator and no sidecar, AVPlayer
/// is handed none of the headers, and the relay's own fetches send the secrets to the origin the host named only.
@Suite("A host that asks for the relay keeps its headers off every other host", .serialized,
       .timeLimit(.minutes(2)))
struct RelaysRemoteHLSTests {

    private let headers = [
        "Authorization": "Basic cHJveHk6c2VjcmV0",
        "CF-Access-Client-Id": "id.access",
        "CF-Access-Client-Secret": "proxy-secret",
        "X-Proxy-Key": "k3y",
        "User-Agent": "Host/1",
    ]
    private let secrets = ["authorization", "cf-access-client-id", "cf-access-client-secret", "x-proxy-key"]

    private func options(relayed: Bool) -> LoadOptions {
        var options = LoadOptions(httpHeaders: headers)
        options.relaysRemoteHLS = relayed
        return options
    }

    @Test("Asked for, the relay stands in front of an http origin with no evaluator, and the origin is not asked")
    func theRelayIsMountedWhenAskedFor() async throws {
        let origin = try #require(CannedHTTPOrigin())
        defer { origin.stop() }
        let master = try #require(URL(string: "\(origin.baseURL)/master.m3u8"))
        #expect(EngineTLS.serverTrustEvaluator == nil)

        #expect(await AetherEngine.remoteHLSNeedsRelay(master, options: options(relayed: true)))
        #expect(await AetherEngine.remoteHLSNeedsRelay(master, options: options(relayed: false)) == false,
                "a host that did not ask keeps AVPlayer on the origin, as before")
        #expect(origin.requests.isEmpty, "the decision asked the origin \(origin.requests.count) times")
    }

    @Test("AVPlayer is handed none of the headers when the relay was asked for, all of them otherwise")
    func thePlayerGetsNoHeaders() {
        #expect(AetherEngine.remoteHLSPlayerHeaders(options(relayed: true)).isEmpty)
        #expect(AetherEngine.remoteHLSPlayerHeaders(options(relayed: false)) == headers)
    }

    @Test("Through the relay, a redirect and the URIs a playlist names on other hosts get no secret")
    func aRedirectToAnotherHostGetsNoSecret() async throws {
        let originMaybe = CannedHTTPOrigin(), edgeMaybe = CannedHTTPOrigin(), keysMaybe = CannedHTTPOrigin()
        let origin = try #require(originMaybe), edge = try #require(edgeMaybe), keys = try #require(keysMaybe)
        defer { origin.stop(); edge.stop(); keys.stop() }
        origin.route("/master.m3u8", .redirect(to: "\(edge.baseURL)/master.m3u8"))
        edge.route("/master.m3u8", .body("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            \(edge.baseURL)/v/index.m3u8
            """, contentType: "application/vnd.apple.mpegurl"))
        edge.route("/v/index.m3u8", .body("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-KEY:METHOD=AES-128,URI="\(keys.baseURL)/key"
            #EXTINF:6.0,
            seg0.ts
            #EXT-X-ENDLIST
            """, contentType: "application/vnd.apple.mpegurl"))
        edge.route("/v/seg0.ts", .body("segment", contentType: "video/mp2t"))
        keys.route("/key", .body("0123456789abcdef", contentType: "application/octet-stream"))
        let master = try #require(URL(string: "\(origin.baseURL)/master.m3u8"))

        // The stand-in as `prepareRemoteHLSStandIn` mounts it for a relayed source with no sidecar.
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: master, tracks: [], httpHeaders: headers, needsRelay: true))
        defer { prepared.tearDown() }
        #expect(prepared.masterURL.host == "127.0.0.1")

        // What AVPlayer would ask, with the headers it is handed: none.
        let masterBody = try await Self.text(of: prepared.masterURL)
        let variant = try #require(Self.relayed(masterBody).first)
        let media = try await Self.text(of: variant)
        let relayedMedia = Self.relayed(media)
        #expect(relayedMedia.count == 2, "the key and the segment come back through the relay: \(media)")
        for url in relayedMedia { _ = try await Self.text(of: url) }

        let seenAtOrigin = try #require(origin.requests(to: "/master.m3u8").first)
        for name in secrets { #expect(seenAtOrigin.headers[name] == headers.first { $0.key.lowercased() == name }?.value,
                                      "the origin the host named lost \(name)") }
        let elsewhere = edge.requests + keys.requests
        #expect(Set(elsewhere.map(\.path)) == ["/master.m3u8", "/v/index.m3u8", "/v/seg0.ts", "/key"])
        for request in elsewhere {
            for name in secrets { #expect(request.headers[name] == nil, "\(name) reached \(request.path)") }
            #expect(request.headers["user-agent"] == "Host/1", "a header that describes the request was dropped")
        }
    }

    /// A playlist the origin redirected names its variant relative to where it was served from, the edge, not to the
    /// URL the relay asked (Codex's review of relay-proxy-headers, 4): resolved against the origin, the variant was
    /// asked of the origin and the stream did not play.
    @Test("Relative URIs in a redirected playlist resolve against where it was served from")
    func aRedirectedPlaylistsRelativeURIsGoToTheEdge() async throws {
        let originMaybe = CannedHTTPOrigin(), edgeMaybe = CannedHTTPOrigin()
        let origin = try #require(originMaybe), edge = try #require(edgeMaybe)
        defer { origin.stop(); edge.stop() }
        origin.route("/master.m3u8", .redirect(to: "\(edge.baseURL)/vod/master.m3u8"))
        edge.route("/vod/master.m3u8", .body("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            v/index.m3u8
            """, contentType: "application/vnd.apple.mpegurl"))
        edge.route("/vod/v/index.m3u8", .body("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXTINF:6.0,
            seg0.ts
            #EXT-X-ENDLIST
            """, contentType: "application/vnd.apple.mpegurl"))
        let master = try #require(URL(string: "\(origin.baseURL)/master.m3u8"))
        let prepared = try #require(await RemoteHLSSubtitleProxy.prepare(
            originURL: master, tracks: [], httpHeaders: headers, needsRelay: true))
        defer { prepared.tearDown() }

        let variant = try #require(Self.relayed(try await Self.text(of: prepared.masterURL)).first)
        let media = try await Self.text(of: variant)
        #expect(media.contains("#EXTINF"), "the variant was not the edge's: \(media)")
        #expect(origin.requests.map(\.path) == ["/master.m3u8"], "asked of the origin: \(origin.requests.map(\.path))")
        for request in edge.requests {
            for name in secrets { #expect(request.headers[name] == nil, "\(name) reached \(request.path)") }
        }
    }

    /// The relay's own addresses in a playlist it served: every URI in it.
    private static func relayed(_ playlist: String) -> [URL] {
        playlist.components(separatedBy: "\n").flatMap { line -> [String] in
            if line.hasPrefix("http://127.0.0.1:") { return [line] }
            guard let start = line.range(of: "URI=\"http://127.0.0.1:") else { return [] }
            let from = line.index(start.lowerBound, offsetBy: 5)
            return [String(line[from...].prefix { $0 != "\"" })]
        }.compactMap(URL.init(string:))
    }

    private static func text(of url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(url) answered \(response)")
        return String(decoding: body, as: UTF8.self)
    }
}
