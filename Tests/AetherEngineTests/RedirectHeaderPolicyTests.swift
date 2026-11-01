import Testing
import Foundation
@testable import AetherEngine

/// Issue #126 follow-up: `redirectPreservingHeaders` replayed every caller-supplied
/// header, including `Authorization`, onto cross-origin redirect targets. A media
/// server 307-redirecting to a presigned object-storage URL (query-string auth) then
/// rejects the request with 400 because two authentication mechanisms collide, all
/// size probes go blind, and the reader degrades to forward-only streaming. It also
/// disclosed the media-server token to foreign hosts. The policy: credential headers
/// are replayed only when the redirect target is a trustworthy same-host destination
/// (no security downgrade); elsewhere only what describes the request goes, the Referer and
/// User-Agent header-dependent proxies need among it (#8).
struct RedirectHeaderPolicyTests {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Same-origin replay

    @Test("Same scheme/host/port, different path: all headers replayed")
    func samePathChangeKeepsAll() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc", "X-Custom": "1"],
            originalURL: url("https://media.example:8920/emby/videos/42/stream.mp4"),
            redirectURL: url("https://media.example:8920/emby/videos/42/alt.mp4"))
        #expect(out["Authorization"] == "Bearer abc")
        #expect(out["X-Custom"] == "1")
    }

    @Test("Implicit and explicit default port are the same origin")
    func defaultPortEquivalence() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc"],
            originalURL: url("https://media.example/a.mp4"),
            redirectURL: url("https://media.example:443/b.mp4"))
        #expect(out["Authorization"] == "Bearer abc")
    }

    @Test("Same-host TLS upgrade keeps credentials (Emby http:8096 to https:8920)")
    func tlsUpgradeSameHostKeepsCredentials() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc"],
            originalURL: url("http://media.example:8096/emby/stream.mp4"),
            redirectURL: url("https://media.example:8920/emby/stream.mp4"))
        #expect(out["Authorization"] == "Bearer abc")
    }

    // MARK: Cross-origin credential stripping

    @Test("Host change keeps only the headers that describe the request")
    func crossHostDropsCredentials() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: [
                "Authorization": "Bearer abc",
                "User-Agent": "Sodalite/1.0",
                "Referer": "https://app.example/",
                "X-Custom": "1",
            ],
            originalURL: url("https://media.example/Items/42/stream.mp4"),
            redirectURL: url("https://storage.cdn.example/bucket/42.mp4?sig=xyz"))
        #expect(out == ["User-Agent": "Sodalite/1.0", "Referer": "https://app.example/"])
    }

    @Test("A Plex token and a proxy's own secret stay behind cross-host, carried over or replayed")
    func crossHostDropsTokensByAnyName() {
        let extra = ["X-Plex-Token": "FAKE-PLEX", "CF-Access-Client-Secret": "FAKE-PROXY", "Range": "bytes=0-"]
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: extra,
            originalURL: url("https://plex.example:32400/video/start.m3u8"),
            redirectURL: url("https://relay.other.example/video/start.m3u8"))
        #expect(out == ["Range": "bytes=0-"])
        var carried = URLRequest(url: url("https://relay.other.example/video/start.m3u8"))
        for (name, value) in extra { carried.setValue(value, forHTTPHeaderField: name) }
        let request = RedirectHeaderPolicy.redirectRequest(
            carried, originalURL: url("https://plex.example:32400/video/start.m3u8"), originalRange: nil,
            extraHeaders: extra)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-")
    }

    @Test("All credential header kinds are stripped cross-host")
    func crossHostDropsAllCredentialHeaderKinds() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: [
                "Authorization": "a",
                "Proxy-Authorization": "b",
                "Cookie": "c",
                "X-Emby-Token": "d",
                "X-Emby-Authorization": "e",
                "X-MediaBrowser-Token": "f",
            ],
            originalURL: url("https://media.example/x"),
            redirectURL: url("https://other.example/x"))
        #expect(out.isEmpty)
    }

    @Test("Credential header names match case-insensitively")
    func caseInsensitiveCredentialNames() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["authorization": "a", "COOKIE": "c", "x-emby-token": "d"],
            originalURL: url("https://media.example/x"),
            redirectURL: url("https://other.example/x"))
        #expect(out.isEmpty)
    }

    @Test("Same host but TLS downgrade strips credentials")
    func downgradeDropsCredentials() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc"],
            originalURL: url("https://media.example/x"),
            redirectURL: url("http://media.example/x"))
        #expect(out["Authorization"] == nil)
    }

    @Test("Same scheme but different port strips credentials")
    func differentPortSameSchemeDrops() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc"],
            originalURL: url("https://media.example/x"),
            redirectURL: url("https://media.example:8443/x"))
        #expect(out["Authorization"] == nil)
    }

    @Test("Host comparison is case-insensitive")
    func hostCaseInsensitive() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc"],
            originalURL: url("https://Media.Example/x"),
            redirectURL: url("https://media.example/x"))
        #expect(out["Authorization"] == "Bearer abc")
    }

    @Test("Missing original URL strips credentials, keeps what describes the request")
    func nilOriginalDropsCredentials() {
        let out = RedirectHeaderPolicy.headersToReplay(
            extraHeaders: ["Authorization": "Bearer abc", "X-Custom": "1", "User-Agent": "UA/1"],
            originalURL: nil,
            redirectURL: url("https://media.example/x"))
        #expect(out == ["User-Agent": "UA/1"])
    }

    // MARK: Request-level sanitization

    @Test("Credential carried over by URLSession is removed cross-host")
    func carriedOverCredentialRemovedCrossHost() {
        var carried = URLRequest(url: url("https://storage.cdn.example/o.mp4?sig=x"))
        carried.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        let out = RedirectHeaderPolicy.redirectRequest(
            carried,
            originalURL: url("https://media.example/Items/42/stream.mp4"),
            originalRange: nil,
            extraHeaders: ["Authorization": "Bearer abc"])
        #expect(out.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Range from the original request survives a cross-host redirect")
    func rangePreservedCrossHost() {
        let carried = URLRequest(url: url("https://storage.cdn.example/o.mp4?sig=x"))
        let out = RedirectHeaderPolicy.redirectRequest(
            carried,
            originalURL: url("https://media.example/Items/42/stream.mp4"),
            originalRange: "bytes=0-1",
            extraHeaders: ["Authorization": "Bearer abc"])
        #expect(out.value(forHTTPHeaderField: "Range") == "bytes=0-1")
        #expect(out.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Same-origin redirect request keeps credentials and Range")
    func sameOriginRequestKeepsCredentialsAndRange() {
        let carried = URLRequest(url: url("https://media.example/Items/42/alt.mp4"))
        let out = RedirectHeaderPolicy.redirectRequest(
            carried,
            originalURL: url("https://media.example/Items/42/stream.mp4"),
            originalRange: "bytes=1024-",
            extraHeaders: ["Authorization": "Bearer abc", "X-Custom": "1"])
        #expect(out.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(out.value(forHTTPHeaderField: "X-Custom") == "1")
        #expect(out.value(forHTTPHeaderField: "Range") == "bytes=1024-")
    }
}
