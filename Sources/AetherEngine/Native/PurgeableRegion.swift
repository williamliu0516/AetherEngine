import Darwin
import Foundation

/// One block of purgeable VM (`vm_allocate(VM_FLAGS_PURGABLE)`): counted memory while non-volatile, and
/// memory the kernel may take back under pressure once it is made volatile. Shared by the software
/// path's packet store (`SoftwarePacketMemoryFIFO`) and the HLS segment cache's memory segments
/// (`SegmentMemoryBuffer`).
///
/// Only touched pages are resident, so a region larger than what is written costs address space, not
/// footprint. Not thread-safe: each owner guards its regions with its own lock.
final class PurgeableRegion {
    let base: UnsafeMutableRawPointer
    let capacity: Int
    private(set) var isVolatile = false

    struct AllocationFailed: Error {}

    init(capacity: Int) throws {
        var address: vm_address_t = 0
        let size = vm_size_t(capacity)
        let kr = vm_allocate(mach_task_self_, &address, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE)
        guard kr == KERN_SUCCESS, let base = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
            throw AllocationFailed()
        }
        self.base = base
        self.capacity = capacity
    }

    deinit {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: base)), vm_size_t(capacity))
    }

    /// `capacity` rounded up to whole pages.
    static func pageRounded(_ bytes: Int) -> Int {
        let page = Int(getpagesize())
        return max(page, (bytes + page - 1) / page * page)
    }

    /// `vm_purgable_control` operations; the header macros carry a cast and do not import.
    private static let setState: vm_purgable_t = 0
    private static let getState: vm_purgable_t = 1

    /// Returns false when making the region non-volatile found it already emptied by the kernel.
    /// A region that cannot be made volatile simply stays resident.
    @discardableResult
    func setVolatile(_ volatile: Bool) -> Bool {
        guard volatile != isVolatile else { return true }
        var state: Int32 = volatile ? VM_PURGABLE_VOLATILE : VM_PURGABLE_NONVOLATILE
        let kr = vm_purgable_control(mach_task_self_, vm_address_t(UInt(bitPattern: base)),
                                     Self.setState, &state)
        if volatile {
            if kr == KERN_SUCCESS { isVolatile = true }
            return true
        }
        isVolatile = false
        // SET_STATE hands back the previous state.
        return kr == KERN_SUCCESS && state != VM_PURGABLE_EMPTY
    }

    /// A query only: the region stays volatile either way.
    var isEmptied: Bool {
        guard isVolatile else { return false }
        var state: Int32 = 0
        let kr = vm_purgable_control(mach_task_self_, vm_address_t(UInt(bitPattern: base)),
                                     Self.getState, &state)
        return kr == KERN_SUCCESS && state == VM_PURGABLE_EMPTY
    }

    /// Empties the region now, as the kernel may once it is volatile. Tests only.
    func purgeForTesting() {
        var state: Int32 = VM_PURGABLE_EMPTY
        vm_purgable_control(mach_task_self_, vm_address_t(UInt(bitPattern: base)), Self.setState, &state)
    }
}
