import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

@Suite("Subtitle OCR preparation")
struct SubtitleOCRQualityTests {
    @Test func cropKeepsDistantRectanglesAndMargin() throws {
        let image = try picture(width: 100, height: 80, rects: [CGRect(x: 10, y: 10, width: 10, height: 5),
                                                             CGRect(x: 60, y: 40, width: 10, height: 5)])
        let bounds = try #require(SubtitleImageOCR.alphaBounds(image))
        #expect(bounds.minX == 6)
        #expect(bounds.width == 68)
        #expect(bounds.height == 43)
        let cropped = try #require(image.cropping(to: bounds))
        let inside = try #require(SubtitleImageOCR.alphaBounds(cropped, margin: 0))
        #expect(inside.minX == 4)
        #expect(inside.minY == 4)
        #expect(inside.width == 60)
        #expect(inside.height == 35)
        let prepared = try #require(SubtitleImageOCR.preparedImage(image))
        #expect(prepared.height >= 63)
        #expect(prepared.width > 68)
    }

    @Test func preparationCapsHugeOpaqueImagesAndClampsEdgeMargin() throws {
        let large = try picture(width: 4096, height: 2048, rects: [CGRect(x: 0, y: 0, width: 4096, height: 2048)])
        let prepared = try #require(SubtitleImageOCR.preparedImage(large))
        #expect(prepared.width <= 2048)
        #expect(prepared.height <= 512)
        let edge = try picture(width: 20, height: 20, rects: [CGRect(x: 0, y: 0, width: 20, height: 20)])
        #expect(SubtitleImageOCR.alphaBounds(edge) == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    @Test func contrastFallbackOnlyFollowsAnEmptyReading() throws {
        let image = try picture(width: 40, height: 20, rects: [CGRect(x: 4, y: 4, width: 30, height: 10)])
        for first in [SubtitleImageOCR.Reading.words("OK"), .failed, .nothing] {
            var calls = 0
            let result = SubtitleImageOCR.recognizeReading(image, language: "en") { _ in
                calls += 1
                return calls == 1 ? first : .words("Recovered")
            }
            #expect(calls == (first == .nothing ? 2 : 1))
            #expect(result == (first == .nothing ? .words("Recovered") : first))
        }
    }

    @Test func scriptHintsSurviveTrackNormalizationAndModelMatching() {
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "chi-Hant") == "zh-Hant")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "zh_TW") == "zh-Hant")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "zh-CN") == "zh-Hans")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "jpn") == "ja")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "kor") == "ko")
        #expect(SubtitleImageOCR.supportedLanguage("zh-Hant", among: ["zh-Hans", "zh-Hant"]) == "zh-Hant")
        #expect(SubtitleImageOCR.supportedLanguage("zh-Hant", among: ["zh-Hans"]) == nil)
    }

    @Test func emptyAndSeparatorOnlyLanguageTagsUseAutomaticRecognition() {
        for tag in ["", " ", "\n", "-", "_", "--__", "-_-", " \n_--\n "] {
            #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: tag) == nil)
        }
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: nil) == nil)
    }

    @Test func simultaneousHostAndNativeRenditionReadOnce() async throws {
        let image = try picture(width: 40, height: 20, rects: [CGRect(x: 4, y: 4, width: 30, height: 10)])
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 2,
                              body: .image(SubtitleImage(cgImage: image, position: .zero, canvasSize: .zero)))
        let readings = SubtitleImageOCR.Readings(), calls = SubtitleQualityCalls()
        let recognition: @Sendable (CGImage, String?) -> SubtitleImageOCR.Reading = { _, _ in
            calls.add()
            Thread.sleep(forTimeInterval: 0.1)
            return .words("One reading")
        }
        let store = NativeSubtitleCueStore()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await SubtitleImageOCR.appendRecognized(cues: [cue], language: "eng", to: store,
                                                                     readings: readings, recognition: recognition) }
            for _ in 0..<8 {
                group.addTask {
                    let read = await AetherEngine.recognizedText(in: cue, trackLanguage: "eng", readings: readings,
                                                                  recognition: recognition)
                    #expect(read == .text("One reading"))
                }
            }
        }
        #expect(calls.count == 1)
        #expect(store.snapshotCues().first?.text == "One reading")
    }

    private func picture(width: Int, height: Int, rects: [CGRect]) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        rects.forEach { context.fill($0) }
        return try #require(context.makeImage())
    }
}

private final class SubtitleQualityCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
