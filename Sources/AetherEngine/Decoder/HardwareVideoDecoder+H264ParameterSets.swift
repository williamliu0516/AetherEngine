import CoreMedia
import Foundation
import AetherLibavcodec

/// W2425: reading and building H.264 parameter sets, for `followH264ParameterSets`.
extension HardwareVideoDecoder {

    /// The first SPS and PPS of a length-prefixed H.264 access unit, read up to its first slice.
    static func inBandH264ParameterSets(
        _ packet: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int
    ) -> (sps: [UInt8], pps: [UInt8])? {
        guard let data = packet.pointee.data, packet.pointee.size > 0, (1...4).contains(nalLengthSize) else { return nil }
        let size = Int(packet.pointee.size)
        var sps: [UInt8]?
        var pps: [UInt8]?
        var offset = 0
        walk: while offset + nalLengthSize < size, sps == nil || pps == nil {
            var length = 0
            for k in 0..<nalLengthSize { length = length << 8 | Int(data[offset + k]) }
            offset += nalLengthSize
            guard length > 0, offset + length <= size else { return nil }
            switch data[offset] & 0x1F {
            case 1, 5: break walk
            case 7 where sps == nil: sps = Array(UnsafeBufferPointer(start: data + offset, count: length))
            case 8 where pps == nil: pps = Array(UnsafeBufferPointer(start: data + offset, count: length))
            default: break
            }
            offset += length
        }
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }

    /// Every parameter set (SPS, then PPS) an H.264 format description holds.
    static func h264ParameterSets(of description: CMFormatDescription) -> [[UInt8]] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var length = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: length))
        }
    }

    static func h264FormatDescription(sps: [UInt8], pps: [UInt8], nalLengthSize: Int) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p -> OSStatus in
                guard let sBase = s.baseAddress, let pBase = p.baseAddress else { return -1 }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [sBase, pBase],
                    parameterSetSizes: [s.count, p.count], nalUnitHeaderLength: Int32(nalLengthSize),
                    formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }
}
