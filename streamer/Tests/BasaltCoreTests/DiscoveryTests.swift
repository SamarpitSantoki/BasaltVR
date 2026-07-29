import XCTest
@testable import BasaltCore

final class DiscoveryTests: XCTestCase {
    /// Builds a beacon exactly the way the ALVR v20.14.0 client does.
    private func beacon(hostname: String = "1234.client.alvr",
                        protocolId: UInt64 = 0x0123_4567_89AB_CDEF,
                        magic: String = "ALVR") -> Data {
        var packet = Data(count: AlvrBeaconParser.packetSize)
        packet.replaceSubrange(0..<magic.utf8.count, with: Data(magic.utf8))
        withUnsafeBytes(of: protocolId.littleEndian) {
            packet.replaceSubrange(16..<24, with: $0)
        }
        let hostnameBytes = Data(hostname.utf8)
        packet.replaceSubrange(24..<24 + hostnameBytes.count, with: hostnameBytes)
        return packet
    }

    func testParsesValidBeacon() {
        let parsed = AlvrBeaconParser.parse(beacon())
        XCTAssertEqual(parsed, AlvrBeacon(protocolId: 0x0123_4567_89AB_CDEF,
                                          hostname: "1234.client.alvr"))
    }

    func testProtocolIdIsLittleEndian() {
        var packet = beacon(protocolId: 0)
        packet.replaceSubrange(16..<24, with: Data([1, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(AlvrBeaconParser.parse(packet)?.protocolId, 1)
    }

    func testHostnameCanFillAll32Bytes() {
        let name = String(repeating: "h", count: 32)
        XCTAssertEqual(AlvrBeaconParser.parse(beacon(hostname: name))?.hostname, name)
    }

    func testRejectsWrongMagic() {
        XCTAssertNil(AlvrBeaconParser.parse(beacon(magic: "ELVR")))
    }

    func testRejectsNonZeroMagicPadding() {
        var packet = beacon()
        packet[10] = 0x42
        XCTAssertNil(AlvrBeaconParser.parse(packet))
    }

    func testRejectsWrongSize() {
        XCTAssertNil(AlvrBeaconParser.parse(beacon().dropLast()))
        XCTAssertNil(AlvrBeaconParser.parse(beacon() + Data([0])))
        XCTAssertNil(AlvrBeaconParser.parse(Data()))
    }

    func testRejectsInvalidUTF8Hostname() {
        var packet = beacon()
        packet.replaceSubrange(24..<28, with: Data([0xFF, 0xFE, 0xFD, 0xFC]))
        XCTAssertNil(AlvrBeaconParser.parse(packet))
    }

    func testListenerReceivesBeaconAndReportsEachClientOnce() throws {
        let received = expectation(description: "beacon reported")
        received.assertForOverFulfill = false
        var reports: [(AlvrBeacon, String)] = []
        let reportsLock = NSLock()

        // Ephemeral port so the test never collides with a running ALVR.
        let listener = try AlvrDiscoveryListener(port: 0) { beacon, ip in
            reportsLock.lock()
            reports.append((beacon, ip))
            reportsLock.unlock()
            received.fulfill()
        }
        defer { listener.stop() }
        XCTAssertNotEqual(listener.boundPort, 0)

        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { close(sender) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = listener.boundPort.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")

        // The client re-broadcasts every second; send a duplicate plus
        // junk to check both dedup and parser tolerance.
        for packet in [beacon(), beacon(), Data("not a beacon".utf8)] {
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sender, bytes.baseAddress, packet.count, 0,
                               $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            XCTAssertEqual(sent, packet.count)
        }

        wait(for: [received], timeout: 5)
        // Give the duplicate a moment to (wrongly) arrive before checking.
        Thread.sleep(forTimeInterval: 0.3)
        reportsLock.lock()
        defer { reportsLock.unlock() }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0.hostname, "1234.client.alvr")
        XCTAssertEqual(reports.first?.1, "127.0.0.1")
    }
}
