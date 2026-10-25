import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #165: on an FFmpeg build missing the bridge encoder the configured mode resolves to (e.g. no
/// --enable-encoder=eac3), `AudioBridge.init` throws `.encoderNotFound` and the single-attempt route dropped
/// straight to silent video-only. The fix cascades to the other encoder before giving up. These cover the
/// ordering decision in isolation; the encoder-absent runtime path itself can't be unit-tested because CI's
/// FFmpeg build carries both encoders (verified on hardware by the reporter).
///
/// AE#395 turned this from a MODE cascade into an ENCODER cascade. `.surroundCompat` resolves to FLAC for a
/// source with no surround to carry, so on a stereo source both modes name the same encoder and a mode list
/// would have retried the absent one against itself, landing on exactly the silent fallback #165 removed.
@Suite("Issue #165 audio bridge-encoder cascade")
struct Issue165BridgeModeCascadeTests {

    @Test("EAC3 cascades to FLAC")
    func eac3CascadesToFLAC() {
        #expect(HLSVideoEngine.bridgeEncoderCascade(firstAttempt: AV_CODEC_ID_EAC3)
                == [AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC])
    }

    @Test("FLAC cascades to EAC3")
    func flacCascadesToEAC3() {
        #expect(HLSVideoEngine.bridgeEncoderCascade(firstAttempt: AV_CODEC_ID_FLAC)
                == [AV_CODEC_ID_FLAC, AV_CODEC_ID_EAC3])
    }

    @Test("the resolved encoder is always attempted first")
    func resolvedEncoderFirst() {
        for encoder in [AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC] {
            #expect(HLSVideoEngine.bridgeEncoderCascade(firstAttempt: encoder).first == encoder)
        }
    }

    @Test("cascade covers both encoders exactly once (no repeats, no silent gaps)")
    func cascadeIsAPermutationOfBothEncoders() {
        for encoder in [AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC] {
            let cascade = HLSVideoEngine.bridgeEncoderCascade(firstAttempt: encoder)
            #expect(cascade.count == 2)
            #expect(Set(cascade.map(\.rawValue)).count == cascade.count)
            #expect(Set(cascade.map(\.rawValue)) == Set([AV_CODEC_ID_EAC3, AV_CODEC_ID_FLAC].map(\.rawValue)))
        }
    }

    /// The regression the encoder cascade exists for: a stereo source resolves to FLAC under BOTH modes, so
    /// the retry has to be derived from the encoder that was missing, never from the mode list.
    @Test("a stereo source still cascades onto a DIFFERENT encoder under either mode")
    func stereoSourceStillCascadesOntoTheOtherEncoder() {
        for mode in [AudioBridgeMode.surroundCompat, .lossless] {
            let first = AudioBridge.bridgeEncoder(for: mode, sourceChannels: 2)
            #expect(first == AV_CODEC_ID_FLAC)
            let cascade = HLSVideoEngine.bridgeEncoderCascade(firstAttempt: first)
            #expect(cascade.last == AV_CODEC_ID_EAC3)
        }
    }

    @Test("receiverCompat is AAC stereo whatever the source, and an absent AAC encoder cascades to EAC3")
    func receiverCompatIsAACStereo() {
        for channels: Int32 in [1, 2, 6, 8] {
            #expect(AudioBridge.bridgeEncoder(for: .receiverCompat, sourceChannels: channels) == AV_CODEC_ID_AAC)
        }
        #expect(AudioBridge.maxEncodedChannels(for: AV_CODEC_ID_AAC) == 2)
        #expect(AudioBridge.encoderBitRate(for: AV_CODEC_ID_AAC, channels: 2) == 192_000)
        #expect(HLSVideoEngine.bridgeEncoderCascade(firstAttempt: AV_CODEC_ID_AAC)
                == [AV_CODEC_ID_AAC, AV_CODEC_ID_EAC3])
        // A 5.1 source folded into AAC stereo goes through the limiter, as the E-AC-3 fold does.
        #expect(AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_AAC, sourceChannels: 6, encoderChannels: 2,
                                             dialogueBoost: false))
        #expect(!AudioBridge.foldNeedsLimiter(encoder: AV_CODEC_ID_AAC, sourceChannels: 2, encoderChannels: 2,
                                              dialogueBoost: false))
    }

    /// AE#396: the message said "absent from this FFmpeg build" while the build that answered was a
    /// second FFmpeg the host had linked ahead of ours. It read as a statement about AetherEngine's
    /// own build, and that reading is what sent the reporter through five fixtures and two devices.
    @Test("the encoder-absent line names the libavcodec that answered, not 'this build'")
    func encoderAbsentLineNamesTheAnsweringLibavcodec() {
        let message = HLSVideoEngine.encoderAbsentMessage(missing: AV_CODEC_ID_FLAC,
                                                          cascadingTo: AV_CODEC_ID_EAC3)
        #expect(message.contains("flac"))
        #expect(message.contains("eac3"))
        #expect(message.contains("libavcodec"))
        #expect(message.contains(FFmpegRuntimeCheck.avcodecIdentity))
        #expect(!message.contains("this FFmpeg build"))
    }
}
