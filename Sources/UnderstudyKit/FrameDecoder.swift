import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware HEVC decoder.
///
/// The session is created from the first frame rather than up front, because the
/// parameter sets describing the video are carried by the encoded stream itself.
/// If those change the session is rebuilt.
public final class FrameDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?

    public init() {}

    /// Decodes one frame. `completion` runs on a VideoToolbox-owned thread.
    public func decode(_ sampleBuffer: CMSampleBuffer,
                       completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return completion(.failure(VideoCodingError.noFormatDescription))
        }

        do {
            try prepareSession(for: format)
        } catch {
            return completion(.failure(error))
        }
        guard let session else {
            return completion(.failure(VideoCodingError.decodeFailed(-1)))
        }

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // Asynchronous decoding would let VideoToolbox reorder output for
            // throughput. Frames must leave in the order they arrived.
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            if status != noErr {
                return completion(.failure(VideoCodingError.decodeFailed(status)))
            }
            guard let imageBuffer else {
                return completion(.failure(VideoCodingError.decodeFailed(status)))
            }
            completion(.success(imageBuffer))
        }

        if status != noErr {
            completion(.failure(VideoCodingError.decodeFailed(status)))
        }
    }

    /// Builds a session, or rebuilds it if the stream's format changed.
    private func prepareSession(for format: CMFormatDescription) throws {
        if let existing = session, let current = formatDescription,
           CMFormatDescriptionEqual(current, otherFormatDescription: format),
           VTDecompressionSessionCanAcceptFormatDescription(existing, formatDescription: format) {
            return
        }
        invalidate()

        // BGRA out, matching what capture produces, so both ends of a round trip
        // can be compared pixel for pixel without a conversion in between.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,   // using the block-based decode call instead
            decompressionSessionOut: &created)

        guard status == noErr, let created else {
            throw VideoCodingError.sessionCreationFailed(status)
        }
        session = created
        formatDescription = format
    }

    public func invalidate() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
        self.formatDescription = nil
    }

    deinit { invalidate() }
}
