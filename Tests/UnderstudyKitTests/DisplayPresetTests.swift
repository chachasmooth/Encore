import XCTest
@testable import UnderstudyKit

// Pure logic only. GitHub's macOS runners are headless, so anything that creates
// a real display would fail in CI — that verification lives in understudy-probe.
//
// XCTest rather than swift-testing, because swift-testing ships with Xcode and
// Understudy is buildable with Command Line Tools alone.
final class DisplayPresetTests: XCTestCase {

    func testPixelSizeScalesWithScaleFactor() {
        let retina = DisplayPreset(name: "test", pointWidth: 1512, pointHeight: 982, scaleFactor: 2)
        XCTAssertEqual(retina.pixelWidth, 3024)
        XCTAssertEqual(retina.pixelHeight, 1964)

        let standard = DisplayPreset(name: "test", pointWidth: 1512, pointHeight: 982, scaleFactor: 1)
        XCTAssertEqual(standard.pixelWidth, 1512)
        XCTAssertEqual(standard.pixelHeight, 982)
    }

    func testBuiltInPresetsAreRetinaAndEvenSized() {
        for preset in DisplayPreset.all {
            XCTAssertEqual(preset.scaleFactor, 2, "\(preset.name) should be Retina")
            XCTAssertGreaterThan(preset.refreshRate, 0, "\(preset.name) needs a refresh rate")
            // An odd pixel dimension breaks chroma-subsampled video encoding,
            // which the transport layer will rely on.
            XCTAssertEqual(preset.pixelWidth % 2, 0, "\(preset.name) width must be even")
            XCTAssertEqual(preset.pixelHeight % 2, 0, "\(preset.name) height must be even")
        }
    }

    func testPresetsAreDistinct() {
        let sizes = DisplayPreset.all.map { "\($0.pixelWidth)x\($0.pixelHeight)" }
        XCTAssertEqual(Set(sizes).count, sizes.count, "two presets share a resolution")
    }

    func testMatchingFindsPresetByPixelSize() {
        let target = DisplayPreset.macBookPro14
        XCTAssertEqual(
            DisplayPreset.matching(pixelWidth: target.pixelWidth, pixelHeight: target.pixelHeight),
            target)
        XCTAssertNil(DisplayPreset.matching(pixelWidth: 12345, pixelHeight: 6789))
    }

    func testUncompressedBandwidthJustifiesEncoding() {
        // 3024x1964 at 4 bytes per pixel, 60 times a second, is about 1.4 GB/s —
        // far beyond even Thunderbolt. This is why frames must be encoded.
        let gigabytesPerSecond = DisplayPreset.macBookPro14.uncompressedBytesPerSecond / 1_000_000_000
        XCTAssertGreaterThan(gigabytesPerSecond, 1.0)
    }
}
