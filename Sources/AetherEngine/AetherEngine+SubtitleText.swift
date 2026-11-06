import CoreGraphics
import Foundation

/// What the engine read in a picture subtitle's cue (`AetherEngine.recognizedText(in:trackLanguage:)`).
public enum SubtitleRecognition: Sendable, Equatable {
    /// The cue's words, top line first, one line per line of the picture.
    case text(String)
    /// Nothing read, or only lines below the confidence floor: the picture is all there is of this cue.
    case unreadable
}

extension AetherEngine {
    /// The words in a picture subtitle's cue (PGS, DVB, DVD) for the host's own uses, a translated second line among
    /// them: the same on-device recognition the native rendition runs (`SubtitleImageOCR`), on its one recognition
    /// thread, each picture read once whichever of the two asks first (kept by its pixels and language, text only).
    /// Lines Vision is not confident of are left out, and a cue left with none is `.unreadable`, which is kept too, so
    /// the next cue is not held behind it; a pass that could not run (Vision's requests failing) is `.unreadable` and
    /// not kept. Nil for a text cue, whose words are its own.
    ///
    /// `trackLanguage` is the track's tag ("chi", "eng", "ja"): recognition is pinned to it where the model supports
    /// it, and runs unpinned elsewhere. The call waits for its turn and the reading (tens of milliseconds a cue on the
    /// fast model, more on the accurate one); cancelling it while it waits gives nil and reads nothing.
    public nonisolated func recognizedText(in cue: SubtitleCue, trackLanguage: String?) async -> SubtitleRecognition? {
        await Self.recognizedText(in: cue, trackLanguage: trackLanguage)
    }

    /// `recognizedText(in:trackLanguage:)` with its readings and recognition passed in, for tests.
    nonisolated static func recognizedText(
        in cue: SubtitleCue, trackLanguage: String?,
        readings: SubtitleImageOCR.Readings? = SubtitleImageOCR.readings,
        recognition: @escaping @Sendable (CGImage, String?) -> SubtitleImageOCR.Reading = SubtitleImageOCR.recognizeReading
    ) async -> SubtitleRecognition? {
        guard case .image(let image) = cue.body else { return nil }
        let language = SubtitleImageOCR.recognitionLanguage(forTrackLanguage: trackLanguage)
        guard let reading = await SubtitleImageOCR.read(image.cgImage, language: language, readings: readings,
                                                        recognition: recognition),
              !Task.isCancelled else { return nil }
        // A pass that could not run is unreadable to this caller, and not kept: the next caller reads it again.
        return reading.text.map { .text($0) } ?? .unreadable
    }
}
