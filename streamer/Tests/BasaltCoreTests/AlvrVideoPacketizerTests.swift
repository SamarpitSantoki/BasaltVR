import XCTest
@testable import BasaltCore

final class AlvrVideoPacketizerTests: XCTestCase {
    private func bigEndianInteger(_ data: Data) -> UInt32 {
        data.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func testSingleShardPrefixAndVideoHeader() throws {
        let payload = Data([0, 0, 0, 1, 0x65, 0xAA])
        let shard = try XCTUnwrap(AlvrVideoPacketizer.shards(
            annexB: payload, timestampNanoseconds: 2_000_000_003,
            isIDR: true, packetIndex: 7).first)

        XCTAssertEqual(bigEndianInteger(shard[0..<4]), UInt32(shard.count - 4))
        XCTAssertEqual(shard[4..<6], Data([0, 3]))
        XCTAssertEqual(shard[6..<10], Data([0, 0, 0, 7]))
        XCTAssertEqual(shard[10..<14], Data([0, 0, 0, 1]))
        XCTAssertEqual(shard[14..<18], Data([0, 0, 0, 0]))
        XCTAssertEqual(shard[18..<26], Data([2, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(shard[26..<30], Data([3, 0, 0, 0]))
        XCTAssertEqual(shard[30], 1)
        XCTAssertEqual(shard[31...], payload)
    }

    func testLargeAccessUnitIsShardedAndReconstructable() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 251) })
        let shards = try AlvrVideoPacketizer.shards(
            annexB: payload, timestampNanoseconds: 10, isIDR: false, packetIndex: 99)
        XCTAssertGreaterThan(shards.count, 1)
        XCTAssertTrue(shards.allSatisfy { $0.count <= 1_404 })

        var reconstructed = Data()
        for (index, shard) in shards.enumerated() {
            XCTAssertEqual(bigEndianInteger(shard[10..<14]), UInt32(shards.count))
            XCTAssertEqual(bigEndianInteger(shard[14..<18]), UInt32(index))
            reconstructed.append(shard.dropFirst(18))
        }
        // Duration + IDR header occupies 13 bytes before the encoded payload.
        XCTAssertEqual(reconstructed.dropFirst(13), payload)
    }

    func testExtractsSPSAndPPSFromIDRAccessUnit() throws {
        let accessUnit = Data([
            0, 0, 0, 1, 0x67, 0x11, 0x22,
            0, 0, 1, 0x68, 0x33,
            0, 0, 0, 1, 0x65, 0x44, 0x55,
        ])
        XCTAssertEqual(H264ParameterSets.extract(from: accessUnit), Data([
            0, 0, 0, 1, 0x67, 0x11, 0x22,
            0, 0, 0, 1, 0x68, 0x33,
        ]))
    }

    func testReturnsNilWhenAccessUnitHasNoParameterSets() {
        XCTAssertNil(H264ParameterSets.extract(from: Data([0, 0, 0, 1, 0x41, 0x01])))
    }

    func testHapticsPacketUsesIndependentStreamFraming() throws {
        let packet = try AlvrHapticsPacketizer.packet(
            hand: .right, durationNanoseconds: 1_000_000_002,
            frequency: 160, amplitude: 0.5, packetIndex: 9)
        XCTAssertEqual(packet.count, 46)
        XCTAssertEqual(bigEndianInteger(packet[0..<4]), UInt32(packet.count - 4))
        XCTAssertEqual(packet[4..<6], Data([0, 1]))
        XCTAssertEqual(packet[6..<10], Data([0, 0, 0, 9]))
        XCTAssertEqual(packet[10..<14], Data([0, 0, 0, 1]))
        XCTAssertEqual(packet[14..<18], Data([0, 0, 0, 0]))
        // Right-hand ALVR device ID, one second + two nanoseconds.
        XCTAssertEqual(packet[18..<26], Data([0xd8, 0xbd, 0x3d, 0xeb,
                                              0x30, 0x13, 0xb8, 0xf6]))
        XCTAssertEqual(packet[26..<34], Data([1, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(packet[34..<38], Data([2, 0, 0, 0]))
    }

    func testStereoPCMIsShardedOnAudioStreamAndReconstructable() throws {
        let pcm = Data((0..<(480 * 4)).map { UInt8($0 % 251) })
        let shards = try AlvrAudioPacketizer.shards(
            pcm16Stereo: pcm, packetIndex: 12)
        XCTAssertEqual(shards.count, 2)
        XCTAssertTrue(shards.allSatisfy { $0.count <= 1_404 })

        var reconstructed = Data()
        for (index, shard) in shards.enumerated() {
            XCTAssertEqual(shard[4..<6], Data([0, 2]))
            XCTAssertEqual(bigEndianInteger(shard[6..<10]), 12)
            XCTAssertEqual(bigEndianInteger(shard[10..<14]), UInt32(shards.count))
            XCTAssertEqual(bigEndianInteger(shard[14..<18]), UInt32(index))
            reconstructed.append(shard.dropFirst(18))
        }
        XCTAssertEqual(reconstructed, pcm)
        XCTAssertThrowsError(try AlvrAudioPacketizer.shards(
            pcm16Stereo: Data([0, 1]), packetIndex: 0))
    }
}
