import Foundation

/// ALVR client discovery — the first slice of the M2 bridge.
///
/// ALVR headsets announce themselves by broadcasting a 56-byte beacon to
/// UDP port 9943 roughly once per second. Layout (verified against ALVR
/// v20.14.0, `alvr/client_core/src/sockets.rs` /
/// `alvr/server_core/src/sockets.rs`):
///
///     bytes  0..16   "ALVR", NUL-padded
///     bytes 16..24   protocol id, u64 little-endian
///     bytes 24..56   hostname, UTF-8, NUL-padded
public struct AlvrBeacon: Equatable, Sendable {
    public let protocolId: UInt64
    public let hostname: String

    public init(protocolId: UInt64, hostname: String) {
        self.protocolId = protocolId
        self.hostname = hostname
    }
}

public enum AlvrBeaconParser {
    public static let packetSize = 56
    private static let magic = Data("ALVR".utf8)

    public static func parse(_ packet: Data) -> AlvrBeacon? {
        guard packet.count == packetSize else { return nil }
        let bytes = Data(packet)  // normalize slice indices to 0-based

        guard bytes.prefix(magic.count) == magic,
              bytes[magic.count..<16].allSatisfy({ $0 == 0 }) else { return nil }

        let protocolId = bytes[16..<24].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

        // Mirror the reference implementation: trim trailing NULs, reject
        // invalid UTF-8.
        var hostnameBytes = bytes[24..<56]
        while hostnameBytes.last == 0 { hostnameBytes = hostnameBytes.dropLast() }
        guard let hostname = String(bytes: hostnameBytes, encoding: .utf8) else { return nil }

        return AlvrBeacon(protocolId: protocolId, hostname: hostname)
    }
}

/// Listens for ALVR beacons and rate-limits reports for repeated clients.
///
/// Uses a plain BSD socket: broadcast packets (the client sends to
/// 255.255.255.255) don't reliably reach `NWListener` flows, and this also
/// keeps the listener trivially testable via unicast on an ephemeral port.
///
/// Receive-and-log only for now — the server side of discovery never sends
/// anything back; responding (session negotiation) is the next M2 step.
public final class AlvrDiscoveryListener {
    public static let alvrPort: UInt16 = 9943  // CONTROL_PORT in ALVR

    /// The port actually bound (differs from init's when passing 0).
    public let boundPort: UInt16

    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "basalt.discovery")

    /// `onClient` fires at most once per `repeatInterval` for each
    /// (hostname, source IP) pair, on an internal queue. Retrying matters
    /// because the subsequent TCP control connection can fail transiently.
    public init(port: UInt16 = AlvrDiscoveryListener.alvrPort,
                repeatInterval: TimeInterval = 5,
                onClient: @escaping (AlvrBeacon, String) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw BasaltError("discovery socket() failed: \(String(cString: strerror(errno)))")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY  // beacons are broadcast; must listen on all interfaces
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw BasaltError("Cannot bind UDP port \(port) for discovery "
                + "(is ALVR or MoltenVR already running?)")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &boundLength)
            }
        }
        boundPort = UInt16(bigEndian: boundAddress.sin_port)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var lastReported: [String: Date] = [:]
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1024)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }
            guard count > 0,
                  let beacon = AlvrBeaconParser.parse(Data(buffer[0..<count])) else { return }

            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuffer)

            let key = "\(beacon.hostname)@\(ip)"
            let now = Date()
            if let last = lastReported[key], now.timeIntervalSince(last) < repeatInterval { return }
            lastReported[key] = now
            onClient(beacon, ip)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() {
        source.cancel()
    }

    deinit {
        if !source.isCancelled { source.cancel() }
    }
}
