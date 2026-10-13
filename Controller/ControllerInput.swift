import Foundation
import GameController

/// Bridges the system GameController events into the protocol model. USB is the supported path;
/// this app never starts Bluetooth pairing or scans on its own.
@MainActor
final class ControllerInput: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var snapshot = ControllerSnapshot.neutral

    /// Detail sheets leave this false so a controller cannot activate system controls there.
    var acceptsInput = true
    var onChanged: ((ControllerSnapshot) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    private weak var controller: GCController?
    private var observations: [NSObjectProtocol] = []
    private var activeButtons = Set<ControllerButton>()

    init() {
        observations = [
            NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.selectController() }
            },
            NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] notification in
                let disconnected = notification.object as? GCController
                Task { @MainActor in self?.controllerDisconnected(disconnected) }
            }
        ]
        selectController()
    }

    deinit { observations.forEach(NotificationCenter.default.removeObserver) }

    func selectController() {
        guard let selected = GCController.controllers().first(where: { dualSensePad(of: $0) != nil }) else {
            controllerDisconnected()
            return
        }
        controller = selected
        connected = true
        onConnectionChanged?(true)
        configure(selected)
    }

    func reset() {
        activeButtons.removeAll()
        snapshot = .neutral
        onChanged?(snapshot)
    }

    private func configure(_ controller: GCController) {
        guard let pad = dualSensePad(of: controller) else { return }
        let setButton: (GCControllerButtonInput?, ControllerButton) -> Void = { [weak self] input, button in
            input?.valueChangedHandler = { [weak self] _, value, pressed in
                Task { @MainActor in self?.update(button: button, pressed: pressed || value > 0.25) }
            }
        }
        setButton(pad.buttonA, .cross); setButton(pad.buttonB, .circle)
        setButton(pad.buttonX, .square); setButton(pad.buttonY, .triangle)
        setButton(pad.leftShoulder, .l1); setButton(pad.rightShoulder, .r1)
        setButton(pad.leftThumbstickButton, .leftStick); setButton(pad.rightThumbstickButton, .rightStick)
        setButton(pad.buttonMenu, .options); setButton(pad.buttonOptions, .create)
        setButton(pad.buttonHome, .home)
        setButton(pad.leftTrigger, .l2); setButton(pad.rightTrigger, .r2)
        setButton(pad.dpad.up, .dpadUp); setButton(pad.dpad.down, .dpadDown)
        setButton(pad.dpad.left, .dpadLeft); setButton(pad.dpad.right, .dpadRight)

        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            // GameController has +Y upward; Android AXIS_Y is positive downward.
            Task { @MainActor in self?.update(leftX: Double(x), leftY: -Double(y)) }
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in self?.update(rightX: Double(x), rightY: -Double(y)) }
        }
        pad.leftTrigger.valueChangedHandler = { [weak self] _, value, pressed in
            Task { @MainActor in self?.update(leftTrigger: Double(value), l2: pressed || value > 0.25) }
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, pressed in
            Task { @MainActor in self?.update(rightTrigger: Double(value), r2: pressed || value > 0.25) }
        }
    }

    private func update(button: ControllerButton, pressed: Bool) {
        guard acceptsInput else { return }
        if pressed { activeButtons.insert(button) } else { activeButtons.remove(button) }
        snapshot.buttons = activeButtons
        publish()
    }

    private func update(leftX: Double? = nil, leftY: Double? = nil, rightX: Double? = nil, rightY: Double? = nil, leftTrigger: Double? = nil, rightTrigger: Double? = nil, l2: Bool? = nil, r2: Bool? = nil) {
        guard acceptsInput else { return }
        if let leftX { snapshot.leftX = leftX }; if let leftY { snapshot.leftY = leftY }
        if let rightX { snapshot.rightX = rightX }; if let rightY { snapshot.rightY = rightY }
        if let leftTrigger { snapshot.leftTrigger = leftTrigger.clamped(to: 0...1) }
        if let rightTrigger { snapshot.rightTrigger = rightTrigger.clamped(to: 0...1) }
        if let l2 { if l2 { activeButtons.insert(.l2) } else { activeButtons.remove(.l2) } }
        if let r2 { if r2 { activeButtons.insert(.r2) } else { activeButtons.remove(.r2) } }
        snapshot.buttons = activeButtons
        publish()
    }

    private func publish() { onChanged?(snapshot) }

    private func controllerDisconnected(_ disconnected: GCController? = nil) {
        if let disconnected, let controller, disconnected !== controller { return }
        controller = nil
        connected = false
        onConnectionChanged?(false)
        reset()
    }

    private func dualSensePad(of controller: GCController) -> GCExtendedGamepad? {
        // Some iOS versions expose a USB DualSense as the base extended-gamepad
        // profile rather than GCDualSenseGamepad. The controls used by this app
        // are all part of GCExtendedGamepad, so accepting that profile is safer.
        controller.extendedGamepad
    }
}
