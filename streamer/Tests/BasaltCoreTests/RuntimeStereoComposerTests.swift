import CoreVideo
import XCTest
@testable import BasaltCore

final class RuntimeStereoComposerTests: XCTestCase {
    private func pixelBuffer(b: UInt8, g: UInt8, r: UInt8, a: UInt8) throws
        -> CVPixelBuffer
    {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var maybeBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil, 1, 1, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &maybeBuffer),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(maybeBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        bytes[0] = b
        bytes[1] = g
        bytes[2] = r
        bytes[3] = a
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testOpaqueProjectionPreservesRGBWhenSourceAlphaIsZero() throws {
        let composer = try RuntimeStereoComposer(perEyeWidth: 1, height: 1)
        let left = try pixelBuffer(b: 0, g: 0, r: 255, a: 0)
        let right = try pixelBuffer(b: 0, g: 255, r: 0, a: 0)
        let output = try XCTUnwrap(composer.compose(left: left, right: right))

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[2], 240)
        XCTAssertLessThan(bytes[1], 15)
        XCTAssertGreaterThan(bytes[3], 240)
        XCTAssertGreaterThan(bytes[5], 240)
        XCTAssertLessThan(bytes[6], 15)
        XCTAssertGreaterThan(bytes[7], 240)
    }
}
