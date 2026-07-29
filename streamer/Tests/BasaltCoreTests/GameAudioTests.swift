import XCTest
@testable import BasaltCore

final class GameAudioTests: XCTestCase {
    func testFloatStereoConvertsToLittleEndianPCM16WithClipping() throws {
        let pcm = try StereoPCM16Encoder.encode(
            left: [-2, -1, -0.5, 0, 0.5, 1, 2, .nan],
            right: [1, 0.25, 0, -0.25, -1, 0, 0.75, .infinity])
        XCTAssertEqual(pcm, Data([
            0x00, 0x80, 0xff, 0x7f,
            0x00, 0x80, 0x00, 0x20,
            0x00, 0xc0, 0x00, 0x00,
            0x00, 0x00, 0x00, 0xe0,
            0x00, 0x40, 0x00, 0x80,
            0xff, 0x7f, 0x00, 0x00,
            0xff, 0x7f, 0x00, 0x60,
            0x00, 0x00, 0x00, 0x00,
        ]))
    }

    func testStereoConversionRejectsMismatchedChannels() {
        XCTAssertThrowsError(try StereoPCM16Encoder.encode(
            left: [0, 1], right: [0]))
    }
}
