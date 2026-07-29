import CoreVideo
import XCTest
@testable import BasaltCore

final class StereoFrameComposerTests: XCTestCase {
    func testDuplicatesCompleteSourceIntoBothEyes() throws {
        var maybeSource: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA,
                                           nil, &maybeSource), kCVReturnSuccess)
        let source = try XCTUnwrap(maybeSource)
        CVPixelBufferLockBaseAddress(source, [])
        let sourceBytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        for y in 0..<2 {
            for x in 0..<4 {
                let offset = y * sourceStride + x * 4
                sourceBytes[offset] = UInt8(20 + x)       // B
                sourceBytes[offset + 1] = UInt8(40 + y)   // G
                sourceBytes[offset + 2] = UInt8(60 + x)   // R
                sourceBytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let composer = try StereoFrameComposer(sourceWidth: 4, sourceHeight: 2,
                                               perEyeWidth: 4, height: 2,
                                               contentScale: 1)
        let output = try XCTUnwrap(composer.compose(source))
        let repeatedOutput = try XCTUnwrap(composer.compose(source))
        XCTAssertTrue(output === repeatedOutput,
                      "An unchanged captured surface should reuse composed stereo output")
        XCTAssertEqual(CVPixelBufferGetWidth(output), 8)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 2)

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(output)
        for y in 0..<2 {
            let left = Data(bytes: bytes.advanced(by: y * stride), count: 4 * 4)
            let right = Data(bytes: bytes.advanced(by: y * stride + 4 * 4), count: 4 * 4)
            XCTAssertEqual(left, right)
        }
    }
}
