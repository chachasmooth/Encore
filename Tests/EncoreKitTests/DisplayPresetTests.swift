import XCTest
@testable import EncoreKit

// Pure logic only. GitHub's macOS runners are headless, so anything that creates
// a real display would fail in CI — that verification lives in encore-probe.
//
// XCTest rather than swift-testing, because swift-testing ships with Xcode and
// Encore is buildable with Command Line Tools alone.
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

}
