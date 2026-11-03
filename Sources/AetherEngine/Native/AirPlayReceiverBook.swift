import Foundation

/// What each wireless AirPlay receiver has shown it cannot play, kept across launches and keyed by the
/// receiver's audio-route UID, so a receiver is made to refuse a format once and is then handed the
/// form it takes from the start.
///
/// Two things are learnt, each from the receiver's own behaviour rather than from its name. A refused HDR master is
/// not among them: an Apple TV whose output is SDR refuses one, and a user who switches its output to HDR should be
/// offered the master again on the next launch, so that refusal stays per process (`AetherEngine`).
///
/// - `refusesEveryMaster`: an SDR master was refused too. Third-party receivers do this (a Hisense Roku TV,
///   2026-10-25: four sources, HEVC and H.264, every master refused with -11870 / -60034, every media
///   playlist taken), so such a receiver is handed the media playlist straight away.
/// - `needsCompatAudio`: the receiver plays AAC and nothing else. The same Roku TV refused FLAC outright and
///   stalled on E-AC-3 with 28 s of it fetched, while a Dolby Vision source with AAC played. Learnt when a
///   receiver refuses an SDR master of a session whose audio is not AAC, or holds segments and does not play
///   them (`AetherEngine.armAirPlayDecodeWatchdog`); from then on its audio is re-encoded to AAC stereo
///   (`AudioBridgeMode.receiverCompat`).
struct AirPlayReceiverBook {

    struct Entry: Codable, Equatable {
        var refusesEveryMaster = false
        var needsCompatAudio = false
    }

    /// What a refused master says about the receiver, given the session it refused.
    enum Refusal: Equatable {
        /// An HDR master: kept per process only (an Apple TV in SDR output).
        case hdrMaster
        /// An SDR master whose audio is not AAC, from a session not yet built for AAC: rebuild with AAC and offer
        /// the master again.
        case needsCompatAudio
        /// An SDR master the receiver refused although its audio was AAC, or a session already built for AAC
        /// refused again (its AAC encoder absent): media playlist from now on, no further rebuild.
        case everyMaster
    }

    static func refusal(sourceIsHDR: Bool, servesCompatibleAudio: Bool, builtForReceiver: Bool) -> Refusal {
        if sourceIsHDR { return .hdrMaster }
        return servesCompatibleAudio || builtForReceiver ? .everyMaster : .needsCompatAudio
    }

    static let defaultsKey = "AetherEngine.airPlayReceiverBook.v1"
    /// Receivers kept. A home has a handful; the cap only stops a travelling device from growing the list forever.
    static let capacity = 32

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entry(for uid: String) -> Entry {
        load()[uid]?.entry ?? Entry()
    }

    /// Applies `change` to the receiver's entry and saves it. Returns the entry as saved.
    @discardableResult
    func update(_ uid: String, _ change: (inout Entry) -> Void) -> Entry {
        var book = load()
        var entry = book[uid]?.entry ?? Entry()
        change(&entry)
        book[uid] = Stamped(entry: entry, at: Date())
        if book.count > Self.capacity {
            let oldest = book.sorted { $0.value.at < $1.value.at }.prefix(book.count - Self.capacity)
            for (key, _) in oldest { book.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(book) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        return entry
    }

    private struct Stamped: Codable {
        var entry: Entry
        var at: Date
    }

    private func load() -> [String: Stamped] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let book = try? JSONDecoder().decode([String: Stamped].self, from: data) else { return [:] }
        return book
    }
}
