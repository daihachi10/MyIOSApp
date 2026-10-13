import Foundation

enum ControllerButton: String, CaseIterable, Codable, Hashable, Sendable {
    case cross, circle, square, triangle, create, home, options, leftStick, rightStick
    case l1, r1, dpadUp, dpadDown, dpadLeft, dpadRight, touchpad, mute, l2, r2

    var label: String {
        switch self {
        case .cross: "Cross"; case .circle: "Circle"; case .square: "Square"; case .triangle: "Triangle"
        case .create: "Create"; case .home: "Home"; case .options: "Options"; case .leftStick: "L3"
        case .rightStick: "R3"; case .l1: "L1"; case .r1: "R1"; case .dpadUp: "↑"
        case .dpadDown: "↓"; case .dpadLeft: "←"; case .dpadRight: "→"; case .touchpad: "Touchpad"
        case .mute: "Mute"; case .l2: "L2"; case .r2: "R2"
        }
    }
}

struct ControllerSnapshot: Equatable, Sendable {
    var buttons: Set<ControllerButton> = []
    var leftX = 0.0
    var leftY = 0.0
    var rightX = 0.0
    var rightY = 0.0
    var leftTrigger = 0.0
    var rightTrigger = 0.0

    static let neutral = ControllerSnapshot()

    func sticksAreCentered(radius: Double = 0.10) -> Bool {
        hypot(leftX, leftY) <= radius && hypot(rightX, rightY) <= radius
    }
}

struct ControlTuning: Codable, Equatable, Sendable {
    var deadzone = 0.05
    var sensitivity = 1.0

    func normalized() -> ControlTuning {
        var copy = self
        copy.deadzone = deadzone.clamped(to: 0...0.3)
        copy.sensitivity = sensitivity.clamped(to: 0.5...2)
        return copy
    }
}

enum EmergencyStopMode: String, Codable, CaseIterable, Sendable {
    case optionsHold
    case optionsCreate

    var label: String {
        switch self {
        case .optionsHold: String(localized: "Optionsを1秒長押し")
        case .optionsCreate: String(localized: "Options＋Createを同時押し")
        }
    }
}

struct ControlProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var speedPercent: Int
    var emergencyStopMode: EmergencyStopMode
    var tuning: ControlTuning

    static let presets: [ControlProfile] = [
        .init(id: UUID(uuidString: "40C60E3A-68E2-4A44-8B10-000000000001")!, name: String(localized: "安全確認"), speedPercent: 25, emergencyStopMode: .optionsCreate, tuning: .init()),
        .init(id: UUID(uuidString: "40C60E3A-68E2-4A44-8B10-000000000002")!, name: String(localized: "通常走行"), speedPercent: 100, emergencyStopMode: .optionsCreate, tuning: .init()),
        .init(id: UUID(uuidString: "40C60E3A-68E2-4A44-8B10-000000000003")!, name: String(localized: "低速調整"), speedPercent: 50, emergencyStopMode: .optionsHold, tuning: .init())
    ]
}

enum ConnectionStatus: Equatable, Sendable {
    case disconnected, connecting(Int), connected, stopping, error

    var label: String {
        switch self {
        case .disconnected: String(localized: "未接続")
        case .connecting(let attempt): String(localized: "接続中（\(attempt)/5）")
        case .connected: String(localized: "送信中")
        case .stopping: String(localized: "安全停止中")
        case .error: String(localized: "接続エラー")
        }
    }

    var isActive: Bool {
        switch self { case .connecting, .connected, .stopping: true; default: false }
    }
}

struct ControllerPacketEncoder {
    static let deadzone = 0.05
    static let triggerThreshold = 0.25

    static func encode(_ snapshot: ControllerSnapshot, tuning: ControlTuning = .init()) -> [UInt8] {
        let tuning = tuning.normalized()
        let left = applyRadialDeadzone(snapshot.leftX, snapshot.leftY, radius: tuning.deadzone)
        let right = applyRadialDeadzone(snapshot.rightX, snapshot.rightY, radius: tuning.deadzone)
        func transformed(_ value: Double) -> UInt8 {
            let shaped = value.sign == .minus ? -pow(abs(value), tuning.sensitivity) : pow(abs(value), tuning.sensitivity)
            return axisToByte(shaped)
        }

        var b1: UInt8 = 0
        b1.set(0, snapshot.buttons.contains(.cross)); b1.set(1, snapshot.buttons.contains(.circle))
        b1.set(2, snapshot.buttons.contains(.square)); b1.set(3, snapshot.buttons.contains(.triangle))
        b1.set(4, snapshot.buttons.contains(.create)); b1.set(5, snapshot.buttons.contains(.home))
        b1.set(6, snapshot.buttons.contains(.options)); b1.set(7, snapshot.buttons.contains(.leftStick))
        var b2: UInt8 = 0
        b2.set(0, snapshot.buttons.contains(.rightStick)); b2.set(1, snapshot.buttons.contains(.l1))
        b2.set(2, snapshot.buttons.contains(.r1)); b2.set(3, snapshot.buttons.contains(.dpadUp))
        b2.set(4, snapshot.buttons.contains(.dpadDown)); b2.set(5, snapshot.buttons.contains(.dpadLeft))
        b2.set(6, snapshot.buttons.contains(.dpadRight)); b2.set(7, snapshot.buttons.contains(.touchpad))
        var b3: UInt8 = 0
        b3.set(0, snapshot.buttons.contains(.mute))
        b3.set(1, snapshot.buttons.contains(.l2) || snapshot.leftTrigger > triggerThreshold)
        b3.set(2, snapshot.buttons.contains(.r2) || snapshot.rightTrigger > triggerThreshold)
        return [0xAA, b1, b2, b3,
                transformed(left.0), transformed(left.1),
                transformed(right.0), transformed(right.1)]
    }

    static func neutralPacket() -> [UInt8] { encode(.neutral) }

    static func hex(_ packet: [UInt8]) -> String { packet.map { String(format: "%02X", $0) }.joined(separator: " ") }

    static func applyRadialDeadzone(_ x: Double, _ y: Double, radius: Double = deadzone) -> (Double, Double) {
        hypot(x, y) < radius.clamped(to: 0...0.3) ? (0, 0) : (x.clamped(to: -1...1), y.clamped(to: -1...1))
    }

    /// Matches Kotlin's round() for the half-value cases used by the Android controller.
    static func axisToByte(_ value: Double) -> UInt8 {
        let raw = ((value.clamped(to: -1...1) + 1) * 127.5).rounded(.toNearestOrEven)
        return UInt8(raw.clamped(to: 0...255))
    }
}

final class EmergencyStopDetector {
    private var optionsPressedAt: ContinuousClock.Instant?
    private var triggered = false
    private let clock = ContinuousClock()

    func update(snapshot: ControllerSnapshot, mode: EmergencyStopMode) -> Bool {
        guard snapshot.buttons.contains(.options) else { reset(); return false }
        if optionsPressedAt == nil { optionsPressedAt = clock.now }
        let shouldStop: Bool
        switch mode {
        case .optionsHold: shouldStop = optionsPressedAt!.duration(to: clock.now) >= .seconds(1)
        case .optionsCreate: shouldStop = snapshot.buttons.contains(.create)
        }
        if shouldStop && !triggered { triggered = true; return true }
        return false
    }

    func reset() { optionsPressedAt = nil; triggered = false }
}

private extension UInt8 {
    mutating func set(_ bit: UInt8, _ enabled: Bool) { if enabled { self |= 1 << bit } }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
