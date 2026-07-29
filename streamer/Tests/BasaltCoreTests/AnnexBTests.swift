import XCTest
import CoreMedia
@testable import BasaltCore

final class AnnexBTests: XCTestCase {
    private let startCode: [UInt8] = [0, 0, 0, 1]

    private func avcc(_ nalus: [[UInt8]]) -> Data {
        var data = Data()
        for nalu in nalus {
            let length = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
            data.append(contentsOf: nalu)
        }
        return data
    }

    func testRewritesLengthPrefixesAsStartCodes() {
        let converted = H264Encoder.annexB(fromAVCC: avcc([[0x65, 0xAA], [0x41, 0xBB, 0xCC]]))
        XCTAssertEqual(converted, Data(startCode + [0x65, 0xAA] + startCode + [0x41, 0xBB, 0xCC]))
    }

    func testStopsAtTruncatedNALU() {
        // Second NALU claims 100 bytes but only 1 follows.
        var data = avcc([[0x65, 0xAA]])
        data.append(contentsOf: [0, 0, 0, 100, 0xDE])
        XCTAssertEqual(H264Encoder.annexB(fromAVCC: data), Data(startCode + [0x65, 0xAA]))
    }

    func testStopsAtZeroLength() {
        var data = avcc([[0x65]])
        data.append(contentsOf: [0, 0, 0, 0])
        XCTAssertEqual(H264Encoder.annexB(fromAVCC: data), Data(startCode + [0x65]))
    }

    func testEmptyAndTinyInputs() {
        XCTAssertEqual(H264Encoder.annexB(fromAVCC: Data()), Data())
        XCTAssertEqual(H264Encoder.annexB(fromAVCC: Data([0, 0, 1])), Data())
    }

    func testSliceInputWithNonZeroStartIndex() {
        // Data slices keep their parent's indices; the converter must not
        // assume startIndex == 0.
        var padded = Data([0xFF, 0xFF, 0xFF, 0xFF])
        padded.append(avcc([[0x65, 0x01]]))
        let slice = padded[4...]
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(H264Encoder.annexB(fromAVCC: slice), Data(startCode + [0x65, 0x01]))
    }

    func testQuestTrackingTimestampRoundTripsExactlyThroughPresentationTime() throws {
        let timestamp: UInt64 = 12_345_678_901_234
        let pts = try XCTUnwrap(H264Encoder.presentationTime(
            questTrackingTimestampNanoseconds: timestamp))

        XCTAssertEqual(pts.timescale, 1_000_000_000)
        XCTAssertEqual(
            H264Encoder.questTrackingTimestampNanoseconds(from: pts), timestamp)
        XCTAssertNil(H264Encoder.presentationTime(
            questTrackingTimestampNanoseconds: UInt64(Int64.max) + 1))
        XCTAssertNil(H264Encoder.questTrackingTimestampNanoseconds(
            from: CMTime(value: -1, timescale: 1_000_000_000)))
    }
}
