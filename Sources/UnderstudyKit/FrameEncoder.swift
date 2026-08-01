import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoCodingError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case propertyRejected(String, OSStatus)
    case encodeFailed(OSStatus)
    case decodeFailed(OSStatus)
    case frameDropped
    case noFormatDescription

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "VideoToolbox refused to create a session (OSStatus \(status))."
        case .propertyRejected(let key, let status):
            return "VideoToolbox rejected \(key) (OSStatus \(status))."
        case .encodeFailed(let status):
            return "Encoding a frame failed (OSStatus \(status))."
        case .decodeFailed(let status):
            return "Decoding a frame failed (OSStatus \(status))."
        case .frameDropped:
            return "The encoder dropped this frame."
        case .noFormatDescription:
            return "The encoded frame carried no format description, so it cannot be decoded."
        }
    }
}

/// Hardware HEVC encoder, configured for latency rather than file size.
///
/// Every setting here trades compression efficiency for getting a frame out of
/// the encoder as fast as possible. A monitor that is a frame behind is worse
/// than a monitor that is slightly blockier.
public final class FrameEncoder {
    private var session: VTCompressionSession?
    private let pixelWidth: Int
    private let pixelHeight: Int

    /// Whether VideoToolbox actually chose the hardware encoder.
    ///
    /// Worth checking rather than assuming. Hardware HEVC runs at roughly
    /// 6 ms per 3024x1964 frame on Apple Silicon and software at about 12 ms,
    /// which is the difference between comfortable headroom and none.
    public private(set) var isHardwareAccelerated = false

    /// - Parameter bitrateMbps: Target average rate. 3024x1964 at 60Hz sits
    ///   comfortably around 40 Mbps over a cable, far below what Thunderbolt
    ///   allows, so there is no reason to squeeze harder and add latency.
    public init(pixelWidth: Int, pixelHeight: Int, frameRate: Int = 60, bitrateMbps: Double = 40) throws {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight

        // Deliberately NOT EnableLowLatencyRateControl. Despite the name, on
        // macOS 26 it forces HEVC onto the software encoder: measured at 12.4 ms
        // per frame against 6.3 ms with hardware, at this resolution. It does
        // produce smaller frames, but bitrate is not the constraint over a cable
        // and latency is the entire point.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(pixelWidth),
            height: Int32(pixelHeight),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,   // using the block-based encode call instead
            refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let session = created else {
            throw VideoCodingError.sessionCreationFailed(status)
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw VideoCodingError.propertyRejected(key as String, status)
            }
        }

        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // B-frames reference a future frame, so the encoder cannot emit anything
        // until that future frame arrives. Unusable for live output.
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        try set(kVTCompressionPropertyKey_AverageBitRate,
                NSNumber(value: Int(bitrateMbps * 1_000_000)))
        // Keyframes cost far more bits than delta frames. On a reliable cable
        // they are only needed so a client joining late has something to start
        // from, so they can be sparse.
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frameRate * 5))

        VTCompressionSessionPrepareToEncodeFrames(session)

        // Unmanaged rather than CFTypeRef?, because VTSessionCopyProperty takes a
        // raw pointer and pointing one at an object reference is unsound.
        var hardware: Unmanaged<CFTypeRef>?
        if VTSessionCopyProperty(session,
                                 key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: kCFAllocatorDefault,
                                 valueOut: &hardware) == noErr,
           let hardware {
            isHardwareAccelerated = (hardware.takeRetainedValue() as? NSNumber)?.boolValue ?? false
        }
    }

    /// Encodes one frame. `completion` runs on a VideoToolbox-owned thread.
    ///
    /// - Parameter forceKeyframe: Emit a self-contained frame rather than one
    ///   that references earlier frames. Required after the transport drops a
    ///   frame, since the gap breaks the reference chain and the picture stays
    ///   corrupt until a keyframe arrives.
    public func encode(_ pixelBuffer: CVPixelBuffer,
                       at time: CMTime,
                       forceKeyframe: Bool = false,
                       completion: @escaping (Result<CMSampleBuffer, Error>) -> Void) {
        guard let session else { return completion(.failure(VideoCodingError.encodeFailed(-1))) }

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, infoFlags, sampleBuffer in
            if status != noErr {
                return completion(.failure(VideoCodingError.encodeFailed(status)))
            }
            if infoFlags.contains(.frameDropped) {
                return completion(.failure(VideoCodingError.frameDropped))
            }
            guard let sampleBuffer else {
                return completion(.failure(VideoCodingError.frameDropped))
            }
            completion(.success(sampleBuffer))
        }

        if status != noErr {
            completion(.failure(VideoCodingError.encodeFailed(status)))
        }
    }

    /// Waits for frames still inside the encoder to come out.
    public func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    deinit { invalidate() }
}

extension CMSampleBuffer {
    /// Size of the compressed payload, for measuring how well encoding is working.
    public var encodedByteCount: Int {
        CMSampleBufferGetTotalSampleSize(self)
    }

    /// Whether this frame stands alone rather than depending on earlier ones.
    public var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
                as? [[CFString: Any]],
              let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }   // absent means "not a dependent frame"
        return !notSync
    }
}
