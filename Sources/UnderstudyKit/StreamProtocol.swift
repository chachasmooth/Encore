import CoreMedia
import Foundation

/// The HEVC parameter sets (VPS, SPS, PPS) describing a stream.
///
/// In-process, a decoder gets these for free from the encoder's format
/// description. Across a socket they have to travel explicitly: without them the
/// client cannot build a decoder at all, and every frame it receives is
/// meaningless bytes.
public struct VideoParameterSets: Equatable, Sendable {
    public let sets: [Data]
    /// Length in bytes of the size prefix on each NAL unit. Always 4 in practice,
    /// but it is carried rather than assumed because the stream defines it.
    public let nalUnitHeaderLength: Int32

    public init(sets: [Data], nalUnitHeaderLength: Int32) {
        self.sets = sets
        self.nalUnitHeaderLength = nalUnitHeaderLength
    }

    /// Reads the parameter sets out of an encoded frame's format description.
    public init?(formatDescription: CMFormatDescription) {
        var count = 0
        var headerLength: Int32 = 0
        // The first call exists only to learn how many sets there are.
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &headerLength) == noErr,
              count > 0
        else { return nil }

        var collected: [Data] = []
        collected.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr,
                  let pointer
            else { return nil }
            collected.append(Data(bytes: pointer, count: size))
        }

        self.sets = collected
        self.nalUnitHeaderLength = headerLength
    }

    /// Rebuilds a format description the decoder can be created from.
    public func makeFormatDescription() -> CMFormatDescription? {
        let sizes = sets.map(\.count)

        // CoreMedia wants an array of pointers that are all valid at once, and a
        // Data's bytes are only guaranteed valid inside withUnsafeBytes. Nesting
        // one call per set keeps every pointer alive until the innermost scope.
        func withPointers(_ index: Int,
                          _ gathered: [UnsafePointer<UInt8>],
                          _ body: ([UnsafePointer<UInt8>]) -> CMFormatDescription?) -> CMFormatDescription? {
            guard index < sets.count else { return body(gathered) }
            return sets[index].withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return withPointers(index + 1, gathered + [base], body)
            }
        }

        return withPointers(0, []) { pointers in
            var format: CMFormatDescription?
            let status = pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: nalUnitHeaderLength,
                        extensions: nil,
                        formatDescriptionOut: &format)
                }
            }
            return status == noErr ? format : nil
        }
    }
}

/// One message on the wire.
public enum StreamMessage: Equatable {
    /// Sent before the first frame, and again if the stream's format changes.
    case parameters(VideoParameterSets)
    case frame(data: Data, presentationTime: CMTime, isKeyframe: Bool)
}

public enum StreamProtocolError: LocalizedError {
    case truncated
    case unknownMessageType(UInt8)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: return "The message ended sooner than its header promised."
        case .unknownMessageType(let type): return "Unknown message type \(type)."
        case .malformed(let detail): return "Malformed message: \(detail)."
        }
    }
}

extension StreamMessage {
    // Wire layout: one type byte, a big-endian UInt32 payload length, then the
    // payload. Length-prefixing means the reader always knows exactly how much
    // to wait for, which TCP will not tell it.
    static let headerSize = 5

    private enum Kind: UInt8 {
        case parameters = 1
        case frame = 2
    }

    public func encoded() -> Data {
        var payload = Data()

        switch self {
        case .parameters(let parameters):
            payload.append(UInt8(clamping: Int(parameters.nalUnitHeaderLength)))
            payload.append(UInt8(clamping: parameters.sets.count))
            for set in parameters.sets {
                payload.appendBigEndian(UInt32(set.count))
                payload.append(set)
            }

        case .frame(let data, let presentationTime, let isKeyframe):
            payload.appendBigEndian(UInt64(bitPattern: presentationTime.value))
            payload.appendBigEndian(UInt32(bitPattern: presentationTime.timescale))
            payload.append(isKeyframe ? 1 : 0)
            payload.append(data)
        }

        var message = Data(capacity: Self.headerSize + payload.count)
        message.append(kind.rawValue)
        message.appendBigEndian(UInt32(payload.count))
        message.append(payload)
        return message
    }

    private var kind: Kind {
        switch self {
        case .parameters: return .parameters
        case .frame: return .frame
        }
    }

    /// Reads one message from the front of `buffer`.
    ///
    /// Returns nil when the buffer does not yet hold a whole message, which is
    /// the normal case for a TCP reader that has only seen part of one.
    public static func decode(from buffer: inout Data) throws -> StreamMessage? {
        guard buffer.count >= headerSize else { return nil }

        let type = buffer[buffer.startIndex]
        let length = Int(buffer.readBigEndianUInt32(at: 1))
        guard buffer.count >= headerSize + length else { return nil }

        var payload = buffer.subdata(in: (buffer.startIndex + headerSize)..<(buffer.startIndex + headerSize + length))
        buffer.removeFirst(headerSize + length)

        guard let kind = Kind(rawValue: type) else {
            throw StreamProtocolError.unknownMessageType(type)
        }

        switch kind {
        case .parameters:
            guard payload.count >= 2 else { throw StreamProtocolError.truncated }
            let headerLength = Int32(payload[payload.startIndex])
            let count = Int(payload[payload.startIndex + 1])
            payload.removeFirst(2)

            var sets: [Data] = []
            sets.reserveCapacity(count)
            for _ in 0..<count {
                guard payload.count >= 4 else { throw StreamProtocolError.truncated }
                let size = Int(payload.readBigEndianUInt32(at: 0))
                payload.removeFirst(4)
                guard payload.count >= size else { throw StreamProtocolError.truncated }
                sets.append(payload.prefix(size))
                payload.removeFirst(size)
            }
            guard !sets.isEmpty else { throw StreamProtocolError.malformed("no parameter sets") }
            return .parameters(VideoParameterSets(sets: sets, nalUnitHeaderLength: headerLength))

        case .frame:
            guard payload.count >= 13 else { throw StreamProtocolError.truncated }
            let value = Int64(bitPattern: payload.readBigEndianUInt64(at: 0))
            let timescale = Int32(bitPattern: payload.readBigEndianUInt32(at: 8))
            let isKeyframe = payload[payload.startIndex + 12] != 0
            payload.removeFirst(13)
            return .frame(data: Data(payload),
                          presentationTime: CMTime(value: value, timescale: timescale),
                          isKeyframe: isKeyframe)
        }
    }
}

// MARK: - Turning frames into bytes and back

extension CMSampleBuffer {
    /// The compressed bytes of an encoded frame.
    public var encodedData: Data? {
        guard let block = CMSampleBufferGetDataBuffer(self) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            // Copy rather than take the pointer: a block buffer is allowed to be
            // several disjoint chunks, and reading it as one would be wrong.
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }

    /// Rebuilds an encoded frame from bytes received over the wire.
    public static func makeEncodedFrame(data: Data,
                                        formatDescription: CMFormatDescription,
                                        presentationTime: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer
        else { return nil }

        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr
        else { return nil }

        return sampleBuffer
    }
}

// MARK: - Byte helpers

extension Data {
    // Swift-qualified: inside a Data extension, the bare name resolves to Data's
    // own instance method instead of the global one.
    fileprivate mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    fileprivate func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[start + $1]) }
    }

    fileprivate func readBigEndianUInt64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(self[start + $1]) }
    }
}
