import Foundation
#if os(iOS)
import UIKit
#endif

/// Whether the screen is being recorded, mirrored or otherwise captured (`UITraitCollection.sceneCaptureState`).
///
/// Zool on an M5 iPad (iPadOS 27.0.1, 2026-10-19): while the user screen-recorded, the built-in panel left HDR
/// (`panelIsHDR=false`) and AVPlayer refused every PQ master with -11868, the recovery master included, while
/// `eligibleForHDRPlayback` still read true; with no recording the same iPad took SDR and HDR10 masters at once
/// (Diagnostics 74 and 76). A refusal under capture is about the capture, so it neither latches the process's
/// panel refusal nor outlives the capture in the session's verdict.
enum ScreenCapture {
    @MainActor static var isActive: Bool {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.traitCollection.sceneCaptureState == .active }
        #else
        false
        #endif
    }
}
