import XCTest
import Network
@testable import BasaltCore

final class TCPServerTests: XCTestCase {
    func testLoopbackClientReceivesBroadcast() async throws {
        // Port 0: let the OS pick, so tests don't collide with a running
        // streamer.
        let server = try TCPServer(port: 0, bindHost: "127.0.0.1")
        defer { server.stop() }

        let connected = expectation(description: "server saw the client")
        server.onClientConnected = { connected.fulfill() }
        try await server.start()

        let boundPort = try XCTUnwrap(server.port)
        XCTAssertNotEqual(boundPort, 0)

        let payload = Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB])
        let receivedPayload = expectation(description: "client received broadcast")

        let client = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: boundPort)!,
            using: .tcp)
        defer { client.cancel() }
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.receive(minimumIncompleteLength: payload.count,
                           maximumLength: 64 * 1024) { data, _, _, _ in
                if data == payload { receivedPayload.fulfill() }
            }
        }
        client.start(queue: .global())

        await fulfillment(of: [connected], timeout: 5)
        server.broadcast(payload)
        await fulfillment(of: [receivedPayload], timeout: 5)
    }
}
