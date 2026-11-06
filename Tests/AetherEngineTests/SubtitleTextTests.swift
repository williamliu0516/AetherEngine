import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

/// The host's reading of picture subtitles (`AetherEngine.recognizedText(in:trackLanguage:)`): a PGS first line's words
/// for a translated second line (the reel app, 2026-11-05, diagnostics LMHQ: the second line waited for words forever).
@Suite("Picture subtitle text for the host")
struct SubtitleTextTests {
    @Test("a picture cue's words come back, read once whoever asks again")
    func readOnce() async {
        let readings = SubtitleImageOCR.Readings()
        let calls = Calls()
        let cue = pictureCue(1, shade: 10)
        for _ in 0..<2 {
            let reading = await AetherEngine.recognizedText(in: cue, trackLanguage: "eng", readings: readings) { _, _ in
                calls.add()
                return .words("Where are you going?")
            }
            #expect(reading == .text("Where are you going?"))
        }
        #expect(calls.count == 1)
    }

    @Test("a cue read as nothing is unreadable, kept so, and the next cue is still read")
    func unreadableDoesNotBlock() async {
        let readings = SubtitleImageOCR.Readings()
        let calls = Calls()
        let noise = pictureCue(1, shade: 20), line = pictureCue(2, shade: 200)
        guard case .image(let wanted) = line.body else { return }
        let lineImage = wanted.cgImage
        let recognition: @Sendable (CGImage, String?) -> SubtitleImageOCR.Reading = { image, _ in
            calls.add()
            return image === lineImage ? .words("Next line") : .nothing
        }
        #expect(await AetherEngine.recognizedText(in: noise, trackLanguage: nil, readings: readings,
                                                  recognition: recognition) == .unreadable)
        #expect(await AetherEngine.recognizedText(in: line, trackLanguage: nil, readings: readings,
                                                  recognition: recognition) == .text("Next line"))
        #expect(await AetherEngine.recognizedText(in: noise, trackLanguage: nil, readings: readings,
                                                  recognition: recognition) == .unreadable)
        #expect(calls.count == 2)
    }

    @Test("a pass that could not run is not kept: the next ask reads the picture again")
    func failureNotKept() async {
        let readings = SubtitleImageOCR.Readings()
        let calls = Calls()
        let cue = pictureCue(1, shade: 90)
        let first = await AetherEngine.recognizedText(in: cue, trackLanguage: nil, readings: readings) { _, _ in
            calls.add()
            return .failed
        }
        #expect(first == .unreadable)
        let second = await AetherEngine.recognizedText(in: cue, trackLanguage: nil, readings: readings) { _, _ in
            calls.add()
            return .words("Read at last")
        }
        #expect(second == .text("Read at last"))
        #expect(calls.count == 2)
    }

    @Test("the same bytes read another way are another picture")
    func fingerprintReadsTheLayout() throws {
        let bytes: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        func image(_ info: CGImageAlphaInfo) -> CGImage? {
            CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        let last = try #require(image(.premultipliedLast)), first = try #require(image(.premultipliedFirst))
        #expect(SubtitleImageOCR.fingerprint(last) != SubtitleImageOCR.fingerprint(first))
    }

    @Test("a text cue has no reading")
    func textCue() async {
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 1, body: .text("Hello"))
        #expect(await AetherEngine.recognizedText(in: cue, trackLanguage: nil, readings: nil) { _, _ in .words("x") } == nil)
    }

    @Test("lines under the confidence floor are left out, and a cue of only those reads as nothing")
    func confidenceFloor() {
        let kept = SubtitleImageOCR.assembleLines([(text: "I'm here.", midY: 0.3, confidence: 0.5),
                                                   (text: "~|", midY: 0.7, confidence: 0.1)])
        #expect(kept == "I'm here.")
        let none = SubtitleImageOCR.assembleLines([(text: "~|", midY: 0.7, confidence: 0.1)])
        #expect(none == nil)
    }

    /// A 2x1 picture of one grey, so two cues of different shades are different pictures.
    private func pictureCue(_ id: Int, shade: UInt8) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let value = CGFloat(shade) / 255
        ctx.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero, canvasSize: .zero)
        return SubtitleCue(id: id, startTime: Double(id), endTime: Double(id) + 1, body: .image(image))
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
