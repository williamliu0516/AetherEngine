// master-variants-check.swift
//
// Opens each master the loopback server serves for one session (master.m3u8, master_safe.m3u8,
// master_hdr.m3u8) with AVURLAsset + AVPlayerItem and reports, one line per master, whether AVPlayer
// reached .readyToPlay, the error it refused with (-11868 and kin), the legible options it exposed and
// the audio CHANNELS the body declared. Like avplayer-open-check.swift it imports only Foundation and
// AVFoundation and talks to the engine over HTTP. `master-variants-check.sh` drives it over a matrix
// of files (SDR, HDR10, DV P8.1, DV P5; E-AC-3 JOC or bed; with or without a text subtitle track).
//
// Run:   swift Tests/Integration/master-variants-check.swift <base url ending in /> <expect-legible 0|1> [timeout]
// Exit:  0 = every master opened with no refusal, and with a legible option when one is expected; 1 otherwise.

import AVFoundation
import Foundation

struct Verdict {
    let path: String
    let ready: Bool
    let error: String?
    let legible: Int
    let channels: String
    let supplemental: Bool
}

func body(of url: URL) async -> String? {
    guard let (data, response) = try? await URLSession.shared.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return String(decoding: data, as: UTF8.self)
}

func open(_ url: URL, timeout: Double) async -> (ready: Bool, error: String?, legible: Int) {
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    player.isMuted = true
    defer { player.replaceCurrentItem(with: nil) }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, item.status == .unknown {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if item.status == .failed {
        let e = item.error as NSError?
        let u = e?.userInfo[NSUnderlyingErrorKey] as? NSError
        var text = e.map { "\($0.domain)/\($0.code)" } ?? "failed"
        if let u { text += " <- \(u.domain)/\(u.code)" }
        for ev in item.errorLog()?.events ?? [] {
            text += " | errorLog \(ev.errorDomain)/\(ev.errorStatusCode) \(ev.errorComment ?? "")"
        }
        return (false, text, 0)
    }
    guard item.status == .readyToPlay else { return (false, "timeout", 0) }
    let group = try? await asset.loadMediaSelectionGroup(for: .legible)
    return (true, nil, group?.options.count ?? 0)
}

func run() async -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 3, let base = URL(string: args[1]) else {
        FileHandle.standardError.write(Data("usage: master-variants-check.swift <base url/> <expect-legible 0|1> [timeout]\n".utf8))
        return 2
    }
    let expectLegible = args[2] == "1"
    let timeout = args.count >= 4 ? (Double(args[3]) ?? 20) : 20
    var failed = false
    for path in ["master.m3u8", "master_safe.m3u8", "master_hdr.m3u8"] {
        let url = base.appendingPathComponent(path)
        guard let text = await body(of: url) else {
            print("  \(path): not served")
            continue
        }
        let channels = text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
            .flatMap { line in line.range(of: "CHANNELS=\"").map { line[$0.upperBound...].prefix { $0 != "\"" } } }
            .map(String.init) ?? "-"
        let result = await open(url, timeout: timeout)
        let v = Verdict(path: path, ready: result.ready, error: result.error, legible: result.legible,
                        channels: channels, supplemental: text.contains("SUPPLEMENTAL-CODECS"))
        let ok = v.ready && (!expectLegible || v.legible > 0)
        if !ok { failed = true }
        print("  \(ok ? "PASS" : "FAIL") \(v.path): \(v.ready ? "readyToPlay" : "refused \(v.error ?? "")") "
            + "legible=\(v.legible) CHANNELS=\(v.channels) SUPPLEMENTAL-CODECS=\(v.supplemental ? "yes" : "no")")
    }
    return failed ? 1 : 0
}

exit(await run())
