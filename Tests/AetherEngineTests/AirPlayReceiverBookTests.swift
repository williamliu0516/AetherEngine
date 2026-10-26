import Foundation
import Testing
@testable import AetherEngine

struct AirPlayReceiverBookTests {

    private func freshDefaults() -> UserDefaults {
        let name = "AirPlayReceiverBookTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("An unknown receiver has refused nothing")
    func unknownReceiver() {
        let book = AirPlayReceiverBook(defaults: freshDefaults())
        #expect(book.entry(for: "AA:BB-airplay") == AirPlayReceiverBook.Entry())
    }

    @Test("What a receiver refused is kept per receiver and survives a new book on the same store")
    func keptAcrossLaunches() {
        let defaults = freshDefaults()
        AirPlayReceiverBook(defaults: defaults).update("tv") { $0.needsCompatAudio = true }
        AirPlayReceiverBook(defaults: defaults).update("tv") { $0.refusesEveryMaster = true }
        let reopened = AirPlayReceiverBook(defaults: defaults)
        #expect(reopened.entry(for: "tv").needsCompatAudio)
        #expect(reopened.entry(for: "tv").refusesEveryMaster)
        #expect(reopened.entry(for: "appletv") == AirPlayReceiverBook.Entry())
    }

    @Test("The book keeps the most recently updated receivers up to its capacity")
    func capacity() {
        let book = AirPlayReceiverBook(defaults: freshDefaults())
        for i in 0..<(AirPlayReceiverBook.capacity + 3) {
            book.update("r\(i)") { $0.needsCompatAudio = true }
        }
        #expect(!book.entry(for: "r0").needsCompatAudio)
        #expect(book.entry(for: "r\(AirPlayReceiverBook.capacity + 2)").needsCompatAudio)
    }

    @Test("A refused master: HDR stays per process, non-AAC SDR asks for AAC once (and every master), AAC SDR every master")
    func refusalVerdicts() {
        #expect(AirPlayReceiverBook.refusal(sourceIsHDR: true, servesCompatibleAudio: false,
                                            builtForReceiver: false) == .hdrMaster)
        #expect(AirPlayReceiverBook.refusal(sourceIsHDR: false, servesCompatibleAudio: false,
                                            builtForReceiver: false) == .needsCompatAudio)
        #expect(AirPlayReceiverBook.refusal(sourceIsHDR: false, servesCompatibleAudio: true,
                                            builtForReceiver: false) == .everyMaster)
        // Built for the receiver and still not AAC (the encoder cascaded to E-AC-3): no second rebuild.
        #expect(AirPlayReceiverBook.refusal(sourceIsHDR: false, servesCompatibleAudio: false,
                                            builtForReceiver: true) == .everyMaster)
    }
}
