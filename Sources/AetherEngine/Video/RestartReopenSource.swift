import Foundation

/// W3147/W3154: what a restart's #79 / #169 reopen of a custom source opens its fresh demuxer on: the host's
/// replacement reader, and for a disc image the title the session plays and the key its recognition is kept under,
/// so the reopen reads the same title without parsing the disc again.
struct RestartReopenSource: @unchecked Sendable {
    let reader: IOReader
    let formatHint: String?
    var discTitleID: Int? = nil
    var discCacheKey: String? = nil

    func open(_ demuxer: Demuxer, profile: DemuxerOpenProfile) throws {
        try demuxer.open(reader: reader, formatHint: formatHint, profile: profile, isLive: false,
                         selectTitleID: discTitleID, discCacheKey: discCacheKey)
    }

    /// Vends a source per reopen from the session's custom reader; nil once the reader is gone or cannot clone.
    static func vendor(_ source: IOReader, formatHint: String?, discTitleID: Int?,
                       discCacheKey: String?) -> @Sendable () -> RestartReopenSource? {
        { [weak source] in
            source?.makeReplacementReader().map {
                RestartReopenSource(reader: $0, formatHint: formatHint, discTitleID: discTitleID,
                                    discCacheKey: discCacheKey)
            }
        }
    }
}
