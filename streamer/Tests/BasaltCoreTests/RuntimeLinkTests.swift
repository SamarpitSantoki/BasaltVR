import XCTest
@testable import BasaltCore

final class RuntimeLinkTests: XCTestCase {
    func testOnlyCoreVideoCompatibleBGRAIsStreamable() {
        let bgraFourCC: UInt32 = 0x4247_5241
        let rgbaFourCC: UInt32 = 0x5247_4241
        XCTAssertTrue(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 87, iosurfacePixelFormat: bgraFourCC))
        XCTAssertTrue(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 91, iosurfacePixelFormat: bgraFourCC))
        XCTAssertFalse(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 28, iosurfacePixelFormat: rgbaFourCC))
        XCTAssertFalse(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 28, iosurfacePixelFormat: bgraFourCC))
        XCTAssertFalse(RuntimeLink.isStreamableSwapchainFormat(
            dxgiFormat: 87, iosurfacePixelFormat: rgbaFourCC))
    }

    func testFrameReadyHeaderPreservesExactQuestTrackingTimestamp() throws {
        var payload = Data()
        payload.appendTestU64(42)
        payload.appendTestU64(UInt64(bitPattern: Int64(-123)))
        payload.appendTestU64(9_876_543_210)
        payload.appendTestU32(2)
        payload.append(Data(repeating: 0, count: 2 * 76))

        let header = try XCTUnwrap(RuntimeLink.frameReadyHeader(from: payload))
        XCTAssertEqual(header.frameNumber, 42)
        XCTAssertEqual(header.displayTime, -123)
        XCTAssertEqual(header.questTrackingTimestampNanoseconds, 9_876_543_210)
        XCTAssertEqual(header.viewCount, 2)
    }

    func testFrameReadyHeaderRejectsLegacyAndMismatchedLayouts() {
        XCTAssertNil(RuntimeLink.frameReadyHeader(from: Data(repeating: 0, count: 20 + 76)))

        var payload = Data(repeating: 0, count: 28 + 76)
        payload.replaceSubrange(24..<28, with: [2, 0, 0, 0])
        XCTAssertNil(RuntimeLink.frameReadyHeader(from: payload))
    }

    func testHeadPosePayloadPreservesTimestampAndNormalizesQuaternion() throws {
        let pose = AlvrHeadPose(
            orientationX: 0, orientationY: 1, orientationZ: 0, orientationW: 1,
            positionX: 0.25, positionY: 1.5, positionZ: -0.5)
        let payload = try XCTUnwrap(RuntimeLink.headPosePayload(
            timestampNanoseconds: 123_456_789, pose: pose))

        XCTAssertEqual(payload.count, 36)
        XCTAssertEqual(payload.readTestU64(at: 0), 123_456_789)
        XCTAssertEqual(payload.readTestF32(at: 8), 0, accuracy: 0.000_001)
        XCTAssertEqual(payload.readTestF32(at: 12), 0.707_106_77, accuracy: 0.000_001)
        XCTAssertEqual(payload.readTestF32(at: 20), 0.707_106_77, accuracy: 0.000_001)
        XCTAssertEqual(payload.readTestF32(at: 24), 0.25)
        XCTAssertEqual(payload.readTestF32(at: 28), 1.5)
        XCTAssertEqual(payload.readTestF32(at: 32), -0.5)
    }

    func testHeadPosePayloadRejectsInvalidValues() {
        let pose = AlvrHeadPose(
            orientationX: 0, orientationY: 0, orientationZ: 0, orientationW: 1,
            positionX: .nan, positionY: 0, positionZ: 0)
        XCTAssertNil(RuntimeLink.headPosePayload(timestampNanoseconds: 1, pose: pose))
    }

    func testControllerButtonAndProfilePayloads() throws {
        let pose = AlvrHeadPose(
            orientationX: 0, orientationY: 0, orientationZ: 0, orientationW: 1.5,
            positionX: -0.2, positionY: 1.2, positionZ: -0.4)
        let motion = AlvrControllerMotion(
            pose: pose, linearVelocityX: 1, linearVelocityY: 2,
            linearVelocityZ: 3, angularVelocityX: 4,
            angularVelocityY: 5, angularVelocityZ: 6)
        let controller = try XCTUnwrap(RuntimeLink.controllerMotionPayload(
            timestampNanoseconds: 99, hand: .left, motion: motion))
        XCTAssertEqual(controller.count, 68)
        XCTAssertEqual(controller.readTestU64(at: 0), 99)
        XCTAssertEqual(controller.readTestU32(at: 8), 0)
        XCTAssertEqual(controller.readTestF32(at: 32), -0.2)
        XCTAssertEqual(controller.readTestF32(at: 64), 6)

        let mask = try XCTUnwrap(RuntimeLink.controllerMaskPayload(
            timestampNanoseconds: 100, activeMask: 2))
        XCTAssertEqual(mask.count, 16)
        XCTAssertEqual(mask.readTestU64(at: 0), 100)
        XCTAssertEqual(mask.readTestU32(at: 8), 2)
        XCTAssertEqual(mask.readTestU32(at: 12), 0)
        XCTAssertNil(RuntimeLink.controllerMaskPayload(
            timestampNanoseconds: 100, activeMask: 4))

        let button = try XCTUnwrap(RuntimeLink.buttonStatePayload(
            AlvrButtonEntry(pathID: 0x1234, value: .scalar(0.75))))
        XCTAssertEqual(button.count, 16)
        XCTAssertEqual(button.readTestU64(at: 0), 0x1234)
        XCTAssertEqual(button.readTestU32(at: 8), 1)
        XCTAssertEqual(button.readTestF32(at: 12), 0.75)

        let profile = RuntimeLink.interactionProfilePayload(
            hand: .right, profileID: 0x0812_fd85_c843_84a6)
        XCTAssertEqual(profile.count, 12)
        XCTAssertEqual(profile.readTestU32(at: 0), 1)
        XCTAssertEqual(profile.readTestU64(at: 4), 0x0812_fd85_c843_84a6)
    }

    func testViewConfigPayloadPreservesCalibratedEyeOrder() throws {
        let config = AlvrViewsConfig(
            ipdMeters: 0.0625,
            fov: [
                AlvrFov(left: -0.91, right: 0.83, up: 0.88, down: -0.84),
                AlvrFov(left: -0.82, right: 0.92, up: 0.89, down: -0.85),
            ])
        let payload = try XCTUnwrap(RuntimeLink.viewConfigPayload(config))

        XCTAssertEqual(payload.count, 36)
        let expected: [Float] = [
            0.0625,
            -0.91, 0.83, 0.88, -0.84,
            -0.82, 0.92, 0.89, -0.85,
        ]
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(payload.readTestF32(at: index * 4), value)
        }
    }

    func testViewConfigPayloadRejectsMalformedCalibration() {
        XCTAssertNil(RuntimeLink.viewConfigPayload(AlvrViewsConfig(
            ipdMeters: 0.063, fov: [
                AlvrFov(left: -.infinity, right: 1, up: 1, down: -1),
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
            ])))
        XCTAssertNil(RuntimeLink.viewConfigPayload(AlvrViewsConfig(
            ipdMeters: 0, fov: [
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
            ])))
        XCTAssertNil(RuntimeLink.viewConfigPayload(AlvrViewsConfig(
            ipdMeters: 0.063, fov: [
                AlvrFov(left: -1, right: 1, up: 1, down: -1),
            ])))
    }

    func testControllerSendSelectionAlternatesWhenBothHandsStayPending() throws {
        var preferred = AlvrHand.left
        var selected = [AlvrHand]()
        for _ in 0..<6 {
            let selection = try XCTUnwrap(RuntimeLink.controllerSendSelection(
                pending: [.left, .right], preferred: preferred))
            selected.append(selection.hand)
            preferred = selection.next
        }
        XCTAssertEqual(selected, [.left, .right, .left, .right, .left, .right])

        let rightOnly = try XCTUnwrap(RuntimeLink.controllerSendSelection(
            pending: [.right], preferred: .left))
        XCTAssertEqual(rightOnly.hand, .right)
        XCTAssertEqual(rightOnly.next, .left)
    }

    func testButtonPayloadCacheCoalescesAndEnforcesCapacity() {
        var payloads: [UInt64: Data] = [:]
        for pathID in UInt64(1)...UInt64(RuntimeLink.maximumRetainedButtonPaths) {
            XCTAssertTrue(RuntimeLink.retainButtonPayload(
                pathID: pathID, payload: Data([UInt8(pathID)]), in: &payloads))
        }
        XCTAssertEqual(payloads.count, RuntimeLink.maximumRetainedButtonPaths)
        XCTAssertFalse(RuntimeLink.retainButtonPayload(
            pathID: 65, payload: Data([65]), in: &payloads))

        XCTAssertTrue(RuntimeLink.retainButtonPayload(
            pathID: 1, payload: Data([99]), in: &payloads))
        XCTAssertEqual(payloads.count, RuntimeLink.maximumRetainedButtonPaths)
        XCTAssertEqual(payloads[1], Data([99]))
    }
}

private extension Data {
    mutating func appendTestU32(_ value: UInt32) {
        for index in 0..<4 {
            append(UInt8((value >> UInt32(index * 8)) & 0xff))
        }
    }

    mutating func appendTestU64(_ value: UInt64) {
        for index in 0..<8 {
            append(UInt8((value >> UInt64(index * 8)) & 0xff))
        }
    }

    func readTestU64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(self[startIndex + offset + index])
        }
        return value
    }

    func readTestF32(at offset: Int) -> Float {
        var bits: UInt32 = 0
        for index in (0..<4).reversed() {
            bits = (bits << 8) | UInt32(self[startIndex + offset + index])
        }
        return Float(bitPattern: bits)
    }


    func readTestU32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(self[startIndex + offset + index])
        }
        return value
    }
}
