import AVFoundation

/// AE#616: feeds `RemoteHLSCueClock` from a legible output on the bypass item.
///
/// The output never suppresses player rendering. A host that draws AVPlayer's renditions keeps them, a
/// host with its own suppressing output keeps that, and the frozen-line trap (an output that starts
/// suppressing while a line is on screen leaves it there for good) cannot be triggered from here.
/// AVPlayer only delivers the selected legible option. Its words always go to the host; the clock can measure
/// an offset when the provider's injected renditions supply the matching source-time reference.
@MainActor
final class RemoteHLSCueClockObserver: NSObject, AVPlayerItemLegibleOutputPushDelegate {

    private let output = AVPlayerItemLegibleOutput()
    private weak var item: AVPlayerItem?
    private let provider: RemoteHLSSubtitleProvider?
    private var legibleGroup: AVMediaSelectionGroup?
    private var legibleTrackIDs: [Int] = []
    private let onText: @MainActor ([String], Double, Int) -> Void
    private var clock = RemoteHLSCueClock()
    /// The provider's `textGeneration` the clock's index was built at.
    private var indexedText = 0
    private var jumpObserver: NSObjectProtocol?
    private let onOffset: @MainActor (Double) -> Void
    private let onTimeJump: @MainActor () -> Void

    init(item: AVPlayerItem, provider: RemoteHLSSubtitleProvider?,
         onOffset: @escaping @MainActor (Double) -> Void,
         onTimeJump: @escaping @MainActor () -> Void,
         onText: @escaping @MainActor ([String], Double, Int) -> Void) {
        self.item = item
        self.provider = provider
        self.onText = onText
        self.onOffset = onOffset
        self.onTimeJump = onTimeJump
        super.init()
        output.suppressesPlayerRendering = false
        output.advanceIntervalForDelegateInvocation = 0
        output.setDelegate(self, queue: .main)
        item.add(output)
        jumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.noteTimeJump()
                self.onTimeJump()
            }
        }
    }

    /// Use the track discovery's ready-retried group and identities, including injected external ids.
    func setLegibleGroup(_ group: AVMediaSelectionGroup, trackIDs: [Int]) {
        guard group.options.count == trackIDs.count else { return }
        legibleGroup = group
        legibleTrackIDs = trackIDs
    }

    func detach() {
        legibleGroup = nil
        legibleTrackIDs = []
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        output.setDelegate(nil, queue: nil)
        item?.remove(output)
        item = nil
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                                   didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any],
                                   forItemTime itemTime: CMTime) {
        let texts = strings.map(\.string)
        let seconds = itemTime.seconds
        guard seconds.isFinite else { return }
        MainActor.assumeIsolated { self.deliver(texts: texts, itemTime: seconds) }
    }

    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated {
            clock.noteTimeJump()
            onTimeJump()
        }
    }

    private func deliver(texts: [String], itemTime: Double) {
        // The fill runs from mount; a line can be presented before it finished. Index once it has, and again when
        // the host's text rewrite changes what the renditions serve (`setNativeSubtitleText`): AVPlayer shows the new
        // text from then on, and a line the replayed selection brings back part-way is a landing, not a start.
        defer {
            if let group = legibleGroup, let selected = item?.currentMediaSelection.selectedMediaOption(in: group),
               let ordinal = group.options.firstIndex(of: selected), legibleTrackIDs.indices.contains(ordinal) {
                onText(texts, itemTime, legibleTrackIDs[ordinal])
            }
        }
        guard let provider else { return }
        let text = provider.textGeneration
        if provider.isFillFinished, !clock.hasCues || text != indexedText {
            if clock.hasCues { clock.noteTimeJump() }
            clock.setCues(provider.allCueStarts())
            indexedText = text
        }
        guard clock.hasCues else { return }
        let previous = clock.offset
        guard let offset = clock.observe(strings: texts, itemTime: itemTime) else { return }
        if previous == nil || abs(offset - (previous ?? 0)) >= 0.05 {
            EngineLog.emit(
                "[AetherEngine] AE#616: item time leads the presented frame by "
                + "\(String(format: "%.3f", offset))s (was "
                + (previous.map { String(format: "%.3f", $0) } ?? "unmeasured")
                + "), measured at item \(String(format: "%.3f", itemTime))s",
                category: .engine)
        }
        onOffset(offset)
    }
}
