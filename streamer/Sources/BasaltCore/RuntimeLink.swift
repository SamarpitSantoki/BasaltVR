import Foundation
import Network
import IOSurface
import CoreVideo
import Security

/// Daemon side of the BasaltVR runtime control socket
/// (docs/DXMT-INTEROP.md §4; wire format in runtime/pe/basalt_control_protocol.h,
/// mirrored here because the constants are trivially small).
///
/// Listens on loopback, writes "<port> <token>" to the control file the
/// launcher hands the game bottle via BASALT_CONTROL, validates the Hello
/// token, retains every registered swapchain IOSurface (IDs are untrusted:
/// dimensions are re-checked after lookup), and surfaces fence-confirmed
/// frames to `onFrame`. One runtime connection at a time.
public final class RuntimeLink: @unchecked Sendable {
    private enum MessageType: UInt16 {
        case hello = 1
        case helloAck = 2
        case createSwapchain = 3
        case swapchainAck = 4
        case destroySwapchain = 5
        case destroySwapchainAck = 6
        case frameReady = 7
        case teardown = 8
        case headPose = 9
        case controllerMotion = 10
        case buttonState = 11
        case haptic = 12
        case interactionProfile = 13
        case inputReset = 14
        case viewConfig = 15
        case controllerMask = 16
    }

    private static let protocolVersion: UInt16 = 7
    private static let tokenLength = 32
    private static let maxMessageLength = 4096
    static let maximumRetainedButtonPaths = 64

    public struct FrameView {
        public let swapchainId: UInt64
        public let dxgiFormat: UInt32
        public let imageIndex: UInt32
        public let imageArrayIndex: UInt32
        public let rect: (x: Int32, y: Int32, width: Int32, height: Int32)
        public let surface: IOSurfaceRef
    }

    public struct Frame {
        public let frameNumber: UInt64
        public let displayTime: Int64
        /// Exact ALVR/Quest tracking timestamp selected by the runtime when
        /// it located the views rendered into this frame.
        public let questTrackingTimestampNanoseconds: UInt64
        public let views: [FrameView]
    }

    struct FrameReadyHeader {
        static let byteCount = 28

        let frameNumber: UInt64
        let displayTime: Int64
        let questTrackingTimestampNanoseconds: UInt64
        let viewCount: UInt32
    }

    public struct Swapchain {
        public let id: UInt64
        public let width: UInt32
        public let height: UInt32
        public let dxgiFormat: UInt32
        public let surfaces: [IOSurfaceRef]
    }

    public var onHello: ((_ sessionId: UInt64, _ renderer: String) -> Void)?
    public var onSwapchain: ((Swapchain) -> Void)?
    public var onFrame: ((Frame) -> Void)?
    public var onTeardown: (() -> Void)?
    private var hapticHandler: ((_ hand: AlvrHand, _ durationNanoseconds: UInt64,
                                 _ frequency: Float, _ amplitude: Float) -> Void)?

    private let controlFilePath: String
    private let queue = DispatchQueue(label: "basalt.runtime-link")
    private let listener: NWListener
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var helloDone = false
    private var swapchains: [UInt64: Swapchain] = [:]
    private var token = ""
    private var pendingHeadPose: Data?
    private var headPoseSendInFlight = false
    private var pendingControllerMotions: [AlvrHand: Data] = [:]
    private var controllerMotionSendInFlight = false
    private var nextControllerHand = AlvrHand.left
    private var latestButtonPayloads: [UInt64: Data] = [:]
    private var pendingButtonPayloads: [UInt64: Data] = [:]
    private var buttonSendInFlight = false
    private var latestInteractionProfiles: [AlvrHand: UInt64] = [:]
    private var latestViewConfigPayload: Data?
    private var latestControllerMask: UInt32?
    private var latestControllerMaskPayload: Data?

    public init(controlFilePath: String) throws {
        self.controlFilePath = controlFilePath
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: 0)!)
        listener = try NWListener(using: parameters)
    }

    /// Binds, writes the control file, and begins accepting the runtime.
    public func start() async throws {
        var tokenBytes = [UInt8](repeating: 0, count: Self.tokenLength / 2)
        guard SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
                == errSecSuccess else {
            throw BasaltError("SecRandomCopyBytes failed")
        }
        token = tokenBytes.map { String(format: "%02x", $0) }.joined()

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var finished = false
                self.listener.newConnectionHandler = { [weak self] newConnection in
                    self?.accept(newConnection)
                }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, !finished else { return }
                    switch state {
                    case .ready:
                        finished = true
                        do {
                            guard let port = self.listener.port?.rawValue else {
                                throw BasaltError("runtime link has no bound port")
                            }
                            // The token is the only authentication for the
                            // loopback control socket, so the file that carries
                            // it must not be world-readable (the launcher points
                            // BASALT_CONTROL at it, often under /tmp). Create it
                            // 0600 in one step so it is never briefly exposed.
                            try? FileManager.default.removeItem(
                                atPath: self.controlFilePath)
                            let controlLine = "\(port) \(self.token)\n"
                            guard FileManager.default.createFile(
                                atPath: self.controlFilePath,
                                contents: Data(controlLine.utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                                throw BasaltError(
                                    "Could not write runtime control file at "
                                    + self.controlFilePath)
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    case .failed(let error):
                        finished = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.dropConnection()
            self.listener.cancel()
            try? FileManager.default.removeItem(atPath: self.controlFilePath)
        }
    }

    /// Publishes ALVR's latest pre-predicted OpenXR head pose. The Quest
    /// timestamp is retained for ordering only; it is a different clock from
    /// the runtime's XrTime. Queue confinement and one-deep replacement keep
    /// tracking from accumulating behind a slow control connection.
    public func publishHeadPose(timestampNanoseconds: UInt64, pose: AlvrHeadPose) {
        guard let payload = Self.headPosePayload(
                timestampNanoseconds: timestampNanoseconds, pose: pose) else {
            return
        }
        queue.async {
            self.pendingHeadPose = payload
            self.pumpHeadPose()
        }
    }

    public func publishControllerMotion(timestampNanoseconds: UInt64, hand: AlvrHand,
                                        motion: AlvrControllerMotion) {
        guard let payload = Self.controllerMotionPayload(
                timestampNanoseconds: timestampNanoseconds, hand: hand,
                motion: motion) else { return }
        queue.async {
            self.pendingControllerMotions[hand] = payload
            self.pumpControllerMotion()
        }
    }

    /// Invalidates controller poses omitted from one authoritative ALVR
    /// tracking packet. Present bits never activate a pose by themselves;
    /// the corresponding motion message remains the source of pose data.
    public func publishControllerMask(timestampNanoseconds: UInt64, activeMask: UInt32) {
        guard let payload = Self.controllerMaskPayload(
                timestampNanoseconds: timestampNanoseconds,
                activeMask: activeMask) else { return }
        queue.async {
            let changed = self.latestControllerMask != activeMask
            self.latestControllerMask = activeMask
            self.latestControllerMaskPayload = payload
            if changed && self.helloDone {
                // Presence transitions must not be coalesced behind a stale
                // pending motion for the same hand.
                self.send(type: .controllerMask, payload: payload)
            }
        }
    }

    public func publishButtons(_ entries: [AlvrButtonEntry]) {
        let payloads = entries.compactMap { entry in
            Self.buttonStatePayload(entry).map { (entry.pathID, $0) }
        }
        guard !payloads.isEmpty else { return }
        queue.async {
            for (pathID, payload) in payloads {
                guard Self.retainButtonPayload(
                        pathID: pathID, payload: payload,
                        in: &self.latestButtonPayloads) else { continue }
                self.pendingButtonPayloads[pathID] = payload
            }
            self.pumpButtonState()
        }
    }

    public func publishInteractionProfile(deviceID: UInt64, profileID: UInt64) {
        guard let hand = AlvrHand(alvrDeviceID: deviceID) else { return }
        queue.async {
            self.latestInteractionProfiles[hand] = profileID
            if self.helloDone {
                self.send(type: .interactionProfile,
                          payload: Self.interactionProfilePayload(hand: hand,
                                                                  profileID: profileID))
            }
        }
    }

    /// Publishes the headset's calibrated IPD and asymmetric per-eye FOV.
    /// Retaining the most recent value lets a runtime that connects after the
    /// ALVR control handshake receive the same projection configuration.
    public func publishViewsConfig(_ config: AlvrViewsConfig) {
        guard let payload = Self.viewConfigPayload(config) else { return }
        queue.async {
            self.latestViewConfigPayload = payload
            if self.helloDone {
                self.send(type: .viewConfig, payload: payload)
            }
        }
    }

    /// Invalidates input retained from the current ALVR session. A reset is
    /// ordered after any already-submitted tracking/button writes and before
    /// samples from a replacement session. Head tracking then becomes stale
    /// naturally in the runtime; unsent head/controller samples are discarded.
    public func resetInputs() {
        queue.async {
            self.pendingHeadPose = nil
            self.pendingControllerMotions.removeAll()
            self.nextControllerHand = .left
            self.latestButtonPayloads.removeAll()
            self.pendingButtonPayloads.removeAll()
            self.latestInteractionProfiles.removeAll()
            self.latestControllerMask = nil
            self.latestControllerMaskPayload = nil
            if self.helloDone {
                self.send(type: .inputReset, payload: Data())
            }
        }
    }

    public func onHaptic(
        _ handler: @escaping (_ hand: AlvrHand, _ durationNanoseconds: UInt64,
                              _ frequency: Float, _ amplitude: Float) -> Void
    ) {
        queue.async { self.hapticHandler = handler }
    }

    @discardableResult
    static func retainButtonPayload(
        pathID: UInt64,
        payload: Data,
        in payloads: inout [UInt64: Data],
        capacity: Int = maximumRetainedButtonPaths
    ) -> Bool {
        guard payloads[pathID] != nil || payloads.count < capacity else { return false }
        payloads[pathID] = payload
        return true
    }

    static func controllerSendSelection(
        pending: Set<AlvrHand>, preferred: AlvrHand
    ) -> (hand: AlvrHand, next: AlvrHand)? {
        let other: AlvrHand = preferred == .left ? .right : .left
        if pending.contains(preferred) { return (preferred, other) }
        if pending.contains(other) { return (other, preferred) }
        return nil
    }

    static func headPosePayload(
        timestampNanoseconds: UInt64,
        pose: AlvrHeadPose
    ) -> Data? {
        let values = [
            pose.orientationX, pose.orientationY, pose.orientationZ, pose.orientationW,
            pose.positionX, pose.positionY, pose.positionZ,
        ]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let normSquared = values[0] * values[0] + values[1] * values[1]
            + values[2] * values[2] + values[3] * values[3]
        guard normSquared >= 0.25, normSquared <= 2.25 else { return nil }
        let inverseNorm = 1 / sqrt(normSquared)

        var payload = Data()
        payload.appendU64(timestampNanoseconds)
        for value in values.prefix(4) { payload.appendF32(value * inverseNorm) }
        for value in values.suffix(3) { payload.appendF32(value) }
        return payload
    }

    static func controllerMotionPayload(
        timestampNanoseconds: UInt64, hand: AlvrHand,
        motion: AlvrControllerMotion
    ) -> Data? {
        let pose = motion.pose
        let values = [
            pose.orientationX, pose.orientationY, pose.orientationZ, pose.orientationW,
            pose.positionX, pose.positionY, pose.positionZ,
            motion.linearVelocityX, motion.linearVelocityY, motion.linearVelocityZ,
            motion.angularVelocityX, motion.angularVelocityY, motion.angularVelocityZ,
        ]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let normSquared = values[0] * values[0] + values[1] * values[1]
            + values[2] * values[2] + values[3] * values[3]
        guard normSquared >= 0.25, normSquared <= 2.25 else { return nil }
        let inverseNorm = 1 / sqrt(normSquared)

        var payload = Data()
        payload.appendU64(timestampNanoseconds)
        payload.appendU32(hand.rawValue)
        payload.appendU32(0)
        for value in values.prefix(4) { payload.appendF32(value * inverseNorm) }
        for value in values.dropFirst(4) { payload.appendF32(value) }
        return payload
    }

    static func controllerMaskPayload(
        timestampNanoseconds: UInt64, activeMask: UInt32
    ) -> Data? {
        guard activeMask & ~UInt32(3) == 0 else { return nil }
        var payload = Data()
        payload.appendU64(timestampNanoseconds)
        payload.appendU32(activeMask)
        payload.appendU32(0)
        return payload
    }

    static func buttonStatePayload(_ entry: AlvrButtonEntry) -> Data? {
        var payload = Data()
        payload.appendU64(entry.pathID)
        switch entry.value {
        case .binary(let value):
            payload.appendU32(0)
            payload.appendF32(value ? 1 : 0)
        case .scalar(let value):
            guard value.isFinite else { return nil }
            payload.appendU32(1)
            payload.appendF32(value)
        }
        return payload
    }

    static func interactionProfilePayload(hand: AlvrHand, profileID: UInt64) -> Data {
        var payload = Data()
        payload.appendU32(hand.rawValue)
        payload.appendU64(profileID)
        return payload
    }

    static func viewConfigPayload(_ config: AlvrViewsConfig) -> Data? {
        guard config.fov.count == 2, config.ipdMeters.isFinite,
              config.ipdMeters > 0 else { return nil }
        let values = config.fov.flatMap { [$0.left, $0.right, $0.up, $0.down] }
        guard values.allSatisfy(\.isFinite) else { return nil }

        var payload = Data()
        payload.appendF32(config.ipdMeters)
        for value in values { payload.appendF32(value) }
        return payload
    }

    // MARK: - connection handling (all on `queue`)

    private func accept(_ newConnection: NWConnection) {
        guard connection == nil else {
            newConnection.cancel()
            return
        }
        connection = newConnection
        receiveBuffer.removeAll()
        helloDone = false
        newConnection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.queue.async { self?.dropConnection() } }
        }
        newConnection.start(queue: queue)
        receiveMore()
    }

    private func dropConnection() {
        connection?.cancel()
        connection = nil
        // Dropping the dictionary releases every surface retain.
        swapchains.removeAll()
        receiveBuffer.removeAll()
        pendingHeadPose = nil
        headPoseSendInFlight = false
        pendingControllerMotions.removeAll()
        controllerMotionSendInFlight = false
        nextControllerHand = .left
        pendingButtonPayloads.removeAll()
        buttonSendInFlight = false
        if helloDone {
            helloDone = false
            onTeardown?()
        }
    }

    private func receiveMore() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                if !self.drainMessages() {
                    self.dropConnection()
                    return
                }
            }
            if isComplete || error != nil {
                self.dropConnection()
                return
            }
            self.receiveMore()
        }
    }

    /// Extracts complete length-framed messages; false on protocol error.
    private func drainMessages() -> Bool {
        while receiveBuffer.count >= 6 {
            let length = receiveBuffer.readU32(at: 0)
            guard length >= 2, length <= Self.maxMessageLength else { return false }
            guard receiveBuffer.count >= 4 + Int(length) else { return true }
            let type = receiveBuffer.readU16(at: 4)
            let payload = receiveBuffer.subdata(in: 6..<(4 + Int(length)))
            receiveBuffer.removeSubrange(0..<(4 + Int(length)))
            guard handle(type: type, payload: payload) else { return false }
        }
        return true
    }

    private func send(type: MessageType, payload: Data) {
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(type.rawValue)
        message.append(payload)
        connection?.send(content: message, completion: .idempotent)
    }

    private func pumpHeadPose() {
        guard helloDone, !headPoseSendInFlight,
              let connection, let payload = pendingHeadPose else {
            return
        }
        pendingHeadPose = nil
        headPoseSendInFlight = true
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(MessageType.headPose.rawValue)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                self.headPoseSendInFlight = false
                if error != nil {
                    self.dropConnection()
                } else {
                    self.pumpHeadPose()
                }
            }
        })
    }

    private func pumpControllerMotion() {
        guard helloDone, !controllerMotionSendInFlight, let connection,
              let selection = Self.controllerSendSelection(
                  pending: Set(pendingControllerMotions.keys),
                  preferred: nextControllerHand),
              let payload = pendingControllerMotions.removeValue(forKey: selection.hand) else {
            return
        }
        nextControllerHand = selection.next
        controllerMotionSendInFlight = true
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(MessageType.controllerMotion.rawValue)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                self.controllerMotionSendInFlight = false
                if error != nil { self.dropConnection() } else { self.pumpControllerMotion() }
            }
        })
    }

    private func pumpButtonState() {
        guard helloDone, !buttonSendInFlight, let connection,
              let (pathID, payload) = pendingButtonPayloads.first else { return }
        pendingButtonPayloads.removeValue(forKey: pathID)
        buttonSendInFlight = true
        var message = Data()
        message.appendU32(UInt32(2 + payload.count))
        message.appendU16(MessageType.buttonState.rawValue)
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.queue.async {
                guard self.connection === connection else { return }
                self.buttonSendInFlight = false
                if error != nil { self.dropConnection() } else { self.pumpButtonState() }
            }
        })
    }

    private func handle(type: UInt16, payload: Data) -> Bool {
        guard let message = MessageType(rawValue: type) else { return false }
        if !helloDone {
            guard message == .hello else { return false }
            return handleHello(payload)
        }
        switch message {
        case .createSwapchain: return handleCreateSwapchain(payload)
        case .destroySwapchain: return handleDestroySwapchain(payload)
        case .frameReady: return handleFrameReady(payload)
        case .haptic: return handleHaptic(payload)
        case .teardown:
            dropConnection()
            return true
        default:
            return false
        }
    }

    private func handleHello(_ payload: Data) -> Bool {
        let headerLength = 2 + Self.tokenLength + 8 + 2
        guard payload.count >= headerLength,
              payload.readU16(at: 0) == Self.protocolVersion,
              String(data: payload.subdata(in: 2..<(2 + Self.tokenLength)),
                     encoding: .ascii) == token else {
            return false
        }
        let sessionId = payload.readU64(at: 2 + Self.tokenLength)
        let rendererLength = Int(payload.readU16(at: 2 + Self.tokenLength + 8))
        guard payload.count == headerLength + rendererLength else { return false }
        let renderer = String(
            data: payload.subdata(in: headerLength..<(headerLength + rendererLength)),
            encoding: .utf8) ?? ""
        helloDone = true
        var ack = Data()
        ack.appendU16(Self.protocolVersion)
        send(type: .helloAck, payload: ack)
        onHello?(sessionId, renderer)
        pumpHeadPose()
        pumpControllerMotion()
        pendingButtonPayloads = latestButtonPayloads
        pumpButtonState()
        for (hand, profileID) in latestInteractionProfiles {
            send(type: .interactionProfile,
                 payload: Self.interactionProfilePayload(hand: hand, profileID: profileID))
        }
        if let latestViewConfigPayload {
            send(type: .viewConfig, payload: latestViewConfigPayload)
        }
        if let latestControllerMaskPayload {
            send(type: .controllerMask, payload: latestControllerMaskPayload)
        }
        return true
    }

    private func handleCreateSwapchain(_ payload: Data) -> Bool {
        guard payload.count >= 24 else { return false }
        let id = payload.readU64(at: 0)
        let width = payload.readU32(at: 8)
        let height = payload.readU32(at: 12)
        let format = payload.readU32(at: 16)
        let imageCount = payload.readU32(at: 20)
        guard imageCount > 0, imageCount <= 8,
              Self.isStreamableSwapchainFormat(
                  dxgiFormat: format,
                  iosurfacePixelFormat: kCVPixelFormatType_32BGRA),
              payload.count == 24 + Int(imageCount) * 4,
              swapchains[id] == nil else {
            return false
        }
        var surfaces: [IOSurfaceRef] = []
        for index in 0..<Int(imageCount) {
            let surfaceId = payload.readU32(at: 24 + index * 4)
            guard let surface = IOSurfaceLookup(surfaceId),
                  IOSurfaceGetWidth(surface) == Int(width),
                  IOSurfaceGetHeight(surface) == Int(height),
                  Self.isStreamableSwapchainFormat(
                      dxgiFormat: format,
                      iosurfacePixelFormat: IOSurfaceGetPixelFormat(surface)) else {
                return false
            }
            surfaces.append(surface)
        }
        let swapchain = Swapchain(
            id: id, width: width, height: height, dxgiFormat: format,
            surfaces: surfaces)
        swapchains[id] = swapchain
        var ack = Data()
        ack.appendU64(id)
        ack.appendU32(1)  // generation
        send(type: .swapchainAck, payload: ack)
        onSwapchain?(swapchain)
        return true
    }

    private func handleDestroySwapchain(_ payload: Data) -> Bool {
        guard payload.count == 8 else { return false }
        let id = payload.readU64(at: 0)
        guard swapchains.removeValue(forKey: id) != nil else { return false }
        send(type: .destroySwapchainAck, payload: payload)
        return true
    }

    private func handleFrameReady(_ payload: Data) -> Bool {
        guard let header = Self.frameReadyHeader(from: payload) else { return false }
        var views: [FrameView] = []
        for index in 0..<Int(header.viewCount) {
            let base = FrameReadyHeader.byteCount + index * 76
            let swapchainId = payload.readU64(at: base)
            let imageIndex = payload.readU32(at: base + 8)
            let imageArrayIndex = payload.readU32(at: base + 12)
            let rect = (
                x: Int32(bitPattern: payload.readU32(at: base + 16)),
                y: Int32(bitPattern: payload.readU32(at: base + 20)),
                width: Int32(bitPattern: payload.readU32(at: base + 24)),
                height: Int32(bitPattern: payload.readU32(at: base + 28)))
            guard let swapchain = swapchains[swapchainId],
                  imageIndex < UInt32(swapchain.surfaces.count) else {
                return false
            }
            views.append(FrameView(
                swapchainId: swapchainId,
                dxgiFormat: swapchain.dxgiFormat,
                imageIndex: imageIndex,
                imageArrayIndex: imageArrayIndex,
                rect: rect,
                surface: swapchain.surfaces[Int(imageIndex)]))
        }
        onFrame?(Frame(
            frameNumber: header.frameNumber,
            displayTime: header.displayTime,
            questTrackingTimestampNanoseconds: header.questTrackingTimestampNanoseconds,
            views: views))
        return true
    }

    static func frameReadyHeader(from payload: Data) -> FrameReadyHeader? {
        guard payload.count >= FrameReadyHeader.byteCount else { return nil }
        let viewCount = payload.readU32(at: 24)
        guard viewCount > 0, viewCount <= 2,
              payload.count == FrameReadyHeader.byteCount + Int(viewCount) * 76 else {
            return nil
        }
        return FrameReadyHeader(
            frameNumber: payload.readU64(at: 0),
            displayTime: Int64(bitPattern: payload.readU64(at: 8)),
            questTrackingTimestampNanoseconds: payload.readU64(at: 16),
            viewCount: viewCount)
    }

    /// The current native compose/encode path is zero-copy BGRA. DXMT can
    /// allocate RGBA IOSurfaces, but CoreVideo cannot wrap that layout.
    static func isStreamableSwapchainFormat(
            dxgiFormat: UInt32, iosurfacePixelFormat: OSType) -> Bool {
        let isBgraDxgi = dxgiFormat == 87 || dxgiFormat == 91
        return isBgraDxgi && iosurfacePixelFormat == kCVPixelFormatType_32BGRA
    }

    private func handleHaptic(_ payload: Data) -> Bool {
        guard payload.count == 20,
              let hand = AlvrHand(rawValue: payload.readU32(at: 0)) else {
            return false
        }
        let duration = payload.readU64(at: 4)
        let frequency = payload.readF32(at: 12)
        let amplitude = payload.readF32(at: 16)
        guard frequency.isFinite, frequency >= 0,
              amplitude.isFinite, amplitude >= 0, amplitude <= 1 else {
            return false
        }
        hapticHandler?(hand, duration, frequency, amplitude)
        return true
    }
}

// MARK: - little-endian Data helpers

private extension Data {
    func readU16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) |
            (UInt16(self[startIndex + offset + 1]) << 8)
    }
    func readU32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            value = (value << 8) | UInt32(self[startIndex + offset + i])
        }
        return value
    }
    func readU64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(self[startIndex + offset + i])
        }
        return value
    }
    func readF32(at offset: Int) -> Float {
        Float(bitPattern: readU32(at: offset))
    }
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }
    mutating func appendU32(_ value: UInt32) {
        for i in 0..<4 { append(UInt8((value >> (8 * UInt32(i))) & 0xff)) }
    }
    mutating func appendU64(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (8 * UInt64(i))) & 0xff)) }
    }
    mutating func appendF32(_ value: Float) {
        appendU32(value.bitPattern)
    }
}
