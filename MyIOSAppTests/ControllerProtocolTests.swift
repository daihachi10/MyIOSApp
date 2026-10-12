import XCTest
@testable import MyIOSApp

final class ControllerProtocolTests: XCTestCase {
    func testEveryButtonUsesAndroidCompatibleBit() {
        let expectations: [(ControllerButton, Int, UInt8)] = [
            (.cross, 1, 0), (.circle, 2, 0), (.square, 4, 0), (.triangle, 8, 0),
            (.create, 16, 0), (.home, 32, 0), (.options, 64, 0), (.leftStick, 128, 0),
            (.rightStick, 1, 1), (.l1, 2, 1), (.r1, 4, 1), (.dpadUp, 8, 1),
            (.dpadDown, 16, 1), (.dpadLeft, 32, 1), (.dpadRight, 64, 1), (.touchpad, 128, 1),
            (.mute, 1, 2), (.l2, 2, 2), (.r2, 4, 2)
        ]
        for (button, bit, offset) in expectations {
            let frame = ControllerPacketEncoder.encode(.init(buttons: [button]))
            XCTAssertEqual(frame[1 + offset], bit, "\(button)")
        }
    }

    func testTriggerThresholdAndDigitalButton() {
        XCTAssertEqual(ControllerPacketEncoder.encode(.init(leftTrigger: 0.25))[3] & 0b10, 0)
        XCTAssertEqual(ControllerPacketEncoder.encode(.init(leftTrigger: 0.251))[3] & 0b10, 0b10)
        XCTAssertEqual(ControllerPacketEncoder.encode(.init(buttons: [.r2]))[3] & 0b100, 0b100)
    }

    func testAxesAndDeadzoneMatchWireProtocol() {
        XCTAssertEqual(ControllerPacketEncoder.axisToByte(-1), 0)
        XCTAssertEqual(ControllerPacketEncoder.axisToByte(0), 128)
        XCTAssertEqual(ControllerPacketEncoder.axisToByte(1), 255)
        let inside = ControllerPacketEncoder.applyRadialDeadzone(0.03, 0.03)
        XCTAssertEqual(inside.0, 0); XCTAssertEqual(inside.1, 0)
        let edge = ControllerPacketEncoder.applyRadialDeadzone(0.05, 0)
        XCTAssertEqual(edge.0, 0.05); XCTAssertEqual(edge.1, 0)
    }

    func testNeutralFrameIsEightBytes() {
        XCTAssertEqual(ControllerPacketEncoder.neutralPacket(), [0xAA, 0, 0, 0, 128, 128, 128, 128])
    }

    func testEmergencyModes() {
        let detector = EmergencyStopDetector()
        XCTAssertFalse(detector.update(snapshot: .init(buttons: [.options]), mode: .optionsCreate))
        XCTAssertTrue(detector.update(snapshot: .init(buttons: [.options, .create]), mode: .optionsCreate))
        XCTAssertFalse(detector.update(snapshot: .init(buttons: [.options, .create]), mode: .optionsCreate))
        detector.reset()
        XCTAssertFalse(detector.update(snapshot: .neutral, mode: .optionsHold))
    }

    func testReceiverCommandUsesSpeedOnlyAtPiStart() {
        XCTAssertEqual(RaspberryPiCommand.receiver(speedPercent: 50), "exec python3 -u \"$HOME/DifferentialDriveRobomaster/controller_motor_receiver.py\" --max-rpm 6000 --max-current 4000")
        XCTAssertEqual(RaspberryPiCommand.receiver(speedPercent: 500), "exec python3 -u \"$HOME/DifferentialDriveRobomaster/controller_motor_receiver.py\" --max-rpm 12000 --max-current 4000")
    }
}
