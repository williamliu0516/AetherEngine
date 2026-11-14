import CoreMedia
import Foundation
import AetherLibavformat
import AetherLibavcodec

/// W2425: the video decoder the software host's demux loops feed. A loop captures its decoder once, when it
/// starts, and a seek never restarts it, so swapping VideoToolbox for libavcodec mid-stream goes through this
/// slot. The slot's feed epoch is the held decoder's own plus an offset that a swap moves past every epoch
/// the decoders before it were fed under: a packet decided on before a swap, or before any flush of the held
/// decoder (through the slot or straight on `decoder`, as the host's seeks make it), carries a retired epoch
/// and is refused, whatever epoch the new decoder counts from.
final class VideoDecoderSlot: VideoDecodingPipeline, @unchecked Sendable {
    /// Guards `current` and `offset`. Taken before a held decoder's own lock, never after it.
    private let lock = NSLock()
    private var current: any VideoDecodingPipeline
    /// The slot's epoch less the held decoder's own `feedEpoch`.
    private var offset: UInt64 = 0

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
        let retired = offset &+ current.feedEpoch
        offset = retired &+ 1 &- decoder.feedEpoch
        current = decoder
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
        lock.lock(); defer { lock.unlock() }; return offset &+ current.feedEpoch
    }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        try decoder.open(stream: stream, onFrame: onFrame)
    }

    /// The packet goes to the held decoder with the epoch it was read under, in that decoder's count, and the
    /// decoder checks it under its own lock: a flush landing at any point before refuses it. One read before a
    /// swap maps below every epoch the new decoder has had, so that decoder refuses it too.
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
        lock.lock()
        let target = current
        let targetEpoch = epoch.map { $0 &- offset }
        lock.unlock()
        target.decode(packet: packet, epoch: targetEpoch)
    }

    /// The held decoder's flush moves its epoch, and with it the slot's.
    func flush() {
        decoder.flush()
    }

    func drainForEndOfStream() {
        decoder.drainForEndOfStream()
    }

    func close() {
        decoder.close()
    }
}
