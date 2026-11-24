import Foundation

/// One HLS segment held in memory instead of a staging file (W3167, design option E).
///
/// The muxer appends each fragment while a progressive reader may copy what is written so far on a
/// server thread; both go through `lock`, and `length` grows only after the bytes are in place, so a
/// reader never sees a length ahead of its bytes. The bytes live in one `PurgeableRegion`. When an
/// append does not fit, a region twice the size is allocated and the bytes copied: a progressive
/// reader copies under the lock, so it never holds the old region, and a pinned read only exists
/// once the segment is sealed, after which nothing is appended.
///
/// The read contract for a segment that may be volatile (review H2): a read makes the region
/// non-volatile first; if the kernel emptied it the read answers nil (the cache drops the entry, the
/// AE#451 vanished path); otherwise it hands out a no-copy `Data` that pins the region, and the
/// region goes volatile again only once every pin is released and the cache still wants it volatile.
final class SegmentMemoryBuffer: @unchecked Sendable {
    /// Unique per buffer, for the cache's sealed-staging memory: an id, not the object, so remembering
    /// a sealed buffer never keeps its bytes alive.
    let id: UInt64

    private let lock = NSLock()
    private var region: PurgeableRegion?
    private var _length = 0
    private var pins = 0
    private var wantsVolatile = false
    private var emptied = false

    private static let idLock = NSLock()
    private static var nextID: UInt64 = 0

    /// `expectedBytes` sizes the first region (the previous segment's size is a good guess); it grows
    /// by doubling past that.
    init(expectedBytes: Int) {
        Self.idLock.lock()
        Self.nextID += 1
        id = Self.nextID
        Self.idLock.unlock()
        initialCapacity = PurgeableRegion.pageRounded(max(1 << 20, expectedBytes + expectedBytes / 4))
    }

    private let initialCapacity: Int

    var length: Int {
        lock.lock(); defer { lock.unlock() }
        return _length
    }

    /// Appends `count` bytes. False when no region could be allocated; the muxer treats that as a
    /// failed write, like a full disk.
    func append(_ bytes: UnsafeRawPointer, count: Int) -> Bool {
        guard count > 0 else { return true }
        lock.lock(); defer { lock.unlock() }
        let needed = _length + count
        if region == nil || region!.capacity < needed {
            let capacity = PurgeableRegion.pageRounded(max(needed, max(initialCapacity, (region?.capacity ?? 0) * 2)))
            guard let grown = try? PurgeableRegion(capacity: capacity) else { return false }
            if let old = region, _length > 0 {
                grown.base.copyMemory(from: old.base, byteCount: _length)
            }
            region = grown
        }
        region!.base.advanced(by: _length).copyMemory(from: bytes, byteCount: count)
        _length = needed
        return true
    }

    /// Drops everything written (the AE#222 moov prime's fragment).
    func truncate() {
        lock.lock(); defer { lock.unlock() }
        _length = 0
    }

    /// Up to `maxBytes` written past `offset`, copied. Empty when nothing new is written yet; nil when
    /// the kernel emptied the region.
    func copyBytes(from offset: Int, maxBytes: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard reclaimLocked() else { return nil }
        defer { settleLocked() }
        guard let region, offset < _length else { return Data() }
        return Data(bytes: region.base.advanced(by: offset), count: min(maxBytes, _length - offset))
    }

    /// The whole segment as a no-copy `Data` that pins the region until it is released, or nil when the
    /// kernel emptied it. Only for a sealed segment: nothing may be appended while a pin is out.
    func pinnedData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard reclaimLocked() else { return nil }
        guard let region, _length > 0 else { return Data() }
        pins += 1
        return Data(bytesNoCopy: region.base, count: _length, deallocator: .custom { [self, region] _, _ in
            withExtendedLifetime(region) { self.unpin() }
        })
    }

    /// The cache's wish: volatile while the segment sits behind the consumer, non-volatile in its
    /// lead. Returns false when making it non-volatile found it emptied.
    @discardableResult
    func setWantsVolatile(_ volatile: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        wantsVolatile = volatile
        if volatile {
            settleLocked()
            return true
        }
        return reclaimLocked()
    }

    /// Whether the bytes are still there. A volatile region is asked without being reclaimed.
    var isEmptied: Bool {
        lock.lock(); defer { lock.unlock() }
        if !emptied, let region, region.isEmptied { emptied = true }
        return emptied
    }

    /// Counted memory: true unless the region is volatile.
    var isVolatile: Bool {
        lock.lock(); defer { lock.unlock() }
        return region?.isVolatile ?? false
    }

    var pinCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pins
    }

    /// Empties the region now, as the kernel may once it is volatile. Tests only.
    func purgeForTesting() {
        lock.lock(); defer { lock.unlock() }
        region?.purgeForTesting()
    }

    // MARK: - Private

    private func unpin() {
        lock.lock(); defer { lock.unlock() }
        pins -= 1
        settleLocked()
    }

    /// Makes the region non-volatile for a read. False when it was emptied.
    private func reclaimLocked() -> Bool {
        if emptied { return false }
        guard let region, region.isVolatile else { return true }
        if !region.setVolatile(false) {
            emptied = true
            return false
        }
        return true
    }

    /// Back to volatile once no pin holds it, if the cache wants it so.
    private func settleLocked() {
        guard wantsVolatile, pins == 0, !emptied, let region else { return }
        region.setVolatile(true)
    }
}
