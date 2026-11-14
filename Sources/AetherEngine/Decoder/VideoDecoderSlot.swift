import CoreMedia
import Foundation
import AetherLibavformat
import AetherLibavcodec

/// W2425: the video decoder the software host's demux loops feed. A loop captures its decoder once, when it
/// starts, and a seek never restarts it, so swapping VideoToolbox for libavcodec mid-stream goes through this
/// slot. The slot keeps its own feed epoch across every decoder it holds: a packet decided on before a swap
/// (or a flush) carries a retired epoch and is refused, whatever epoch the new decoder counts from.
final class VideoDecoderSlot: VideoDecodingPipeline, @unchecked Sendable {
    /// Guards `current` and `epoch`. Taken before a held decoder's own lock, never after it.
    private let lock = NSLock()
    private var current: any VideoDecodingPipeline
    private var epoch: UInt64 = 0

    init(_ decoder: any VideoDecodingPipeline) {
        current = decoder
    }

    /// The decoder held now.
    var decoder: any VideoDecodingPipeline {
        lock.lock(); defer { lock.unlock() }; return current
    }

    /// Feeds `decoder` from here on and retires the epoch the one it replaces was fed under. The caller opens
    /// `decoder` before and closes the old one.
    func replace(with decoder: any VideoDecodingPipeline) {
        lock.lock()
        current = decoder
        epoch &+= 1
        lock.unlock()
    }

    var onFrame: DecodedFrameHandler? {
        get { decoder.onFrame }
        set { decoder.onFrame = newValue }
    }
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)? {
        get { decoder.onFirstHDR10PlusDetected }
        set { decoder.onFirstHDR10PlusDetected = newValue }
    }
    var onA53Captions: A53CaptionHandler? {
        get { decoder.onA53Captions }
        set { decoder.onA53Captions = newValue }
    }
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)? {
        get { decoder.onDecodedFormat }
        set { decoder.onDecodedFormat = newValue }
    }
    var onHardwareFallbackNeeded: (@Sendable (HardwareFallbackReason) -> Void)? {
        get { decoder.onHardwareFallbackNeeded }
        set { decoder.onHardwareFallbackNeeded = newValue }
    }
    var skipUntilPTS: CMTime? {
        get { decoder.skipUntilPTS }
        set { decoder.skipUntilPTS = newValue }
    }

    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return epoch
    }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        try decoder.open(stream: stream, onFrame: onFrame)
    }

    /// The held decoder's epoch is read under the slot's lock, so a `flush()` or a swap either lands before
    /// the check (the packet is refused here) or after the read (the decoder refuses it itself).
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
        lock.lock()
        if let epoch, epoch != self.epoch { lock.unlock(); return }
        let target = current
        let targetEpoch = epoch == nil ? nil : target.feedEpoch
        lock.unlock()
        target.decode(packet: packet, epoch: targetEpoch)
    }

    func flush() {
        lock.lock()
        epoch &+= 1
        let target = current
        lock.unlock()
        target.flush()
    }

    func drainForEndOfStream() {
        decoder.drainForEndOfStream()
    }

    func close() {
        decoder.close()
    }
}
