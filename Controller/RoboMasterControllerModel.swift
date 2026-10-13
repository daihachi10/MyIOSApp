import Foundation
import SwiftUI
import UIKit

@MainActor
final class RoboMasterControllerModel: ObservableObject {
    @Published var host: String { didSet { persist() } }
    @Published var port: String { didSet { persist() } }
    @Published var autoStartReceiver: Bool { didSet { persist() } }
    @Published var sshUsername: String { didSet { persist() } }
    @Published var sshPort: String { didSet { persist() } }
    @Published var sshPassword: String
    @Published var snapshot = ControllerSnapshot.neutral
    @Published var controllerConnected = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var ping: PingResult = .init(reachable: false, roundTripMilliseconds: nil, failureDescription: nil)
    @Published var errorText: String?
    @Published var lastPacketHex = ControllerPacketEncoder.hex(ControllerPacketEncoder.neutralPacket())
    @Published var sendErrorCount = 0
    @Published var logs: [String] = []
    @Published var speedPercent: Int { didSet { persistControls() } }
    @Published var emergencyStopMode: EmergencyStopMode { didSet { persistControls() } }
    @Published var tuning: ControlTuning { didSet { persistControls() } }
    @Published var customProfiles: [ControlProfile] { didSet { persistControls() } }
    @Published var selectedProfileID: UUID? { didSet { persistControls() } }
    @Published var emergencyStopped = false
    @Published var sshCommandRunning = false
    @Published var lastSSHResult: SSHCommandResult?

    let input = ControllerInput()
    private let session = RobotTcpSession()
    private let ssh = RaspberryPiSSHService()
    private let reachability: any ReachabilityChecking
    private let emergencyDetector = EmergencyStopDetector()
    private var pingTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var packetMonitorTask: Task<Void, Never>?

    init(reachability: any ReachabilityChecking = ICMPReachabilityChecker()) {
        self.reachability = reachability
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "host") ?? "192.168.11.3"
        port = defaults.string(forKey: "port") ?? "5001"
        autoStartReceiver = defaults.object(forKey: "autoStartReceiver") as? Bool ?? true
        sshUsername = defaults.string(forKey: "sshUsername") ?? "daihachi"
        sshPort = defaults.string(forKey: "sshPort") ?? "22"
        sshPassword = KeychainStore.loadPassword()
        speedPercent = defaults.object(forKey: "speedPercent") as? Int ?? 100
        emergencyStopMode = EmergencyStopMode(rawValue: defaults.string(forKey: "emergencyStopMode") ?? "") ?? .optionsCreate
        tuning = Self.load(defaults, key: "tuning", fallback: .init())
        customProfiles = Self.load(defaults, key: "customProfiles", fallback: [])
        selectedProfileID = Self.load(defaults, key: "selectedProfileID", fallback: Optional<UUID>.none)
        input.onChanged = { [weak self] snapshot in self?.receive(snapshot) }
        input.onConnectionChanged = { [weak self] connected in self?.controllerConnectionChanged(connected) }
        controllerConnected = input.connected
        startPingLoop()
    }

    deinit { pingTask?.cancel(); packetMonitorTask?.cancel(); ssh.close() }

    var hostIsValid: Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    var validPort: UInt16? { UInt16(port) }
    var canConnect: Bool {
        !connectionStatus.isActive && !emergencyStopped && controllerConnected && snapshot.sticksAreCentered() &&
        !snapshot.buttons.contains(.options) && !snapshot.buttons.contains(.create) && hostIsValid && validPort != nil &&
        (!autoStartReceiver || (!sshUsername.isEmpty && !sshPassword.isEmpty && UInt16(sshPort) != nil))
    }

    var raspberryPiLabel: String {
        guard connectionStatus.isActive, ping.reachable else { return "未接続" }
        guard let milliseconds = ping.roundTripMilliseconds else { return "Ping — ms" }
        return String(format: "Ping %.1f ms", milliseconds)
    }

    func begin() async {
        guard validateConnectionPrerequisites() else { return }
        guard let destinationPort = validPort else { return }
        errorText = nil
        sendErrorCount = 0
        connectionStatus = .connecting(1)
        appendLog(autoStartReceiver ? "SSHでPi側受信プログラムを起動します" : "Pi側プログラムを起動せずTCP接続します")
        do {
            if autoStartReceiver {
                let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
                let sshPort = Int(sshPort) ?? 22
                let username = sshUsername
                let password = sshPassword
                let speed = speedPercent
                let standardOutput: @Sendable (String) -> Void = { [weak self] line in
                    Task { @MainActor in self?.appendLog("Pi受信: \(line)") }
                }
                let standardError: @Sendable (String) -> Void = { [weak self] line in
                    Task { @MainActor in self?.appendLog("Pi受信エラー: \(line)") }
                }
                try await Task.detached(priority: .userInitiated) { [ssh] in
                    try ssh.startReceiver(host: host, port: sshPort, username: username, password: password, speedPercent: speed, onStandardOutput: standardOutput, onStandardError: standardError)
                }.value
                appendLog("Pi側受信プログラムを起動しました")
            }
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            try await session.start(host: host, port: destinationPort) { [weak self] event in
                Task { @MainActor in self?.handleSessionEvent(event) }
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            ssh.close()
            connectionStatus = .error
            errorText = error.localizedDescription
            appendLog("接続エラー: \(error.localizedDescription)")
        }
    }

    func disconnect(reason: String = "切断しました", emergency: Bool = false) async {
        guard connectionStatus.isActive else { return }
        connectionStatus = .stopping
        input.reset()
        await session.stop(emergency: emergency)
        ssh.close()
        UIApplication.shared.isIdleTimerDisabled = false
        connectionStatus = .disconnected
        lastPacketHex = ControllerPacketEncoder.hex(ControllerPacketEncoder.neutralPacket())
        appendLog(reason)
    }

    func emergencyStop() async {
        guard connectionStatus.isActive, !emergencyStopped else { return }
        emergencyStopped = true
        await disconnect(reason: "非常停止: Options停止パケットを送信して切断しました", emergency: true)
    }

    func clearEmergencyStop() {
        guard !connectionStatus.isActive, snapshot.sticksAreCentered(), !snapshot.buttons.contains(.options), !snapshot.buttons.contains(.create) else {
            errorText = "スティックとOptions／Createを離してから解除してください"; return
        }
        emergencyStopped = false
        emergencyDetector.reset()
        errorText = nil
        appendLog("非常停止を解除しました")
    }

    func setSettingsInput(enabled: Bool) { input.acceptsInput = enabled }

    func saveSSHPassword() {
        do { try KeychainStore.savePassword(sshPassword); appendLog("SSHパスワードをKeychainへ保存しました") }
        catch { errorText = error.localizedDescription }
    }

    func runManualSSH(_ command: String) { runSSH(label: "手動SSH", command: command) }
    func killPython() { runSSH(label: "Python停止", command: RaspberryPiCommand.killPython) }
    func shutdownPi() { runSSH(label: "Raspberry Piシャットダウン", command: RaspberryPiCommand.shutdown, standardInput: sshPassword + "\n") }

    func applyProfile(_ profile: ControlProfile) {
        guard !connectionStatus.isActive else { return }
        speedPercent = profile.speedPercent; emergencyStopMode = profile.emergencyStopMode; tuning = profile.tuning; selectedProfileID = profile.id
        emergencyDetector.reset(); appendLog("プロファイル適用: \(profile.name)")
    }

    func saveProfile(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !connectionStatus.isActive else { return }
        if let index = customProfiles.firstIndex(where: { $0.name == name }) {
            customProfiles[index] = .init(id: customProfiles[index].id, name: name, speedPercent: speedPercent, emergencyStopMode: emergencyStopMode, tuning: tuning)
            selectedProfileID = customProfiles[index].id
        } else if customProfiles.count < 12 {
            let profile = ControlProfile(id: UUID(), name: String(name.prefix(40)), speedPercent: speedPercent, emergencyStopMode: emergencyStopMode, tuning: tuning)
            customProfiles.append(profile); selectedProfileID = profile.id
        } else { errorText = "保存できるカスタムプロファイルは12件までです" }
    }

    func deleteProfile(_ profile: ControlProfile) { customProfiles.removeAll { $0.id == profile.id }; if selectedProfileID == profile.id { selectedProfileID = nil } }
    func clearLogs() { logs.removeAll() }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != .active, connectionStatus.isActive else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "RoboMasterSafetyStop") { [weak self] in self?.finishBackgroundTask() }
        backgroundTask = task
        Task { [weak self] in
            await self?.disconnect(reason: "アプリが前面から離れたため安全停止しました")
            self?.finishBackgroundTask()
        }
    }

    private func receive(_ newSnapshot: ControllerSnapshot) {
        snapshot = newSnapshot
        controllerConnected = input.connected
        if connectionStatus.isActive {
            Task { await session.update(snapshot: newSnapshot, tuning: tuning) }
            if emergencyDetector.update(snapshot: newSnapshot, mode: emergencyStopMode) { Task { await emergencyStop() } }
        }
    }

    private func controllerConnectionChanged(_ connected: Bool) {
        let wasConnected = controllerConnected
        controllerConnected = connected
        if wasConnected, !connected, connectionStatus.isActive {
            Task { await disconnect(reason: "コントローラーが外れたため安全停止しました") }
        }
    }

    private func handleSessionEvent(_ event: RobotSessionEvent) {
        switch event {
        case .connecting(let attempt, _): connectionStatus = .connecting(attempt)
        case .connected: connectionStatus = .connected; appendLog("TCP接続済み・50 Hz送信開始")
        case .packetSent(let packet):
            // Packet visualisation is deliberately throttled to 10 Hz.
            if packetMonitorTask == nil {
                packetMonitorTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.lastPacketHex = ControllerPacketEncoder.hex(packet)
                    self?.packetMonitorTask = nil
                }
            }
        case .failed(let message):
            sendErrorCount += 1; errorText = message; appendLog("送信エラー: \(message)")
        }
    }

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = self.hostIsValid ? await self.reachability.measure(host: host) : PingResult(reachable: false, roundTripMilliseconds: nil, failureDescription: nil)
                guard !Task.isCancelled else { return }
                if host == self.host.trimmingCharacters(in: .whitespacesAndNewlines) { self.ping = result }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func validateConnectionPrerequisites() -> Bool {
        let message: String?
        switch true {
        case emergencyStopped: message = "非常停止を解除してから接続してください"
        case !controllerConnected: message = "DualSenseが検出されていません。USB接続またはiOS設定のBluetooth接続を確認してください"
        case !snapshot.sticksAreCentered(): message = "左右のスティックを中央に戻してください"
        case snapshot.buttons.contains(.options) || snapshot.buttons.contains(.create): message = "OptionsとCreateを離してから接続してください"
        case !hostIsValid: message = "ホスト名またはIPv4アドレスを確認してください"
        case validPort == nil: message = "ポートは1～65535で入力してください"
        case autoStartReceiver && (sshUsername.isEmpty || sshPassword.isEmpty || UInt16(sshPort) == nil): message = "SSH設定とKeychainのパスワードを確認してください"
        default: message = nil
        }
        if let message { errorText = message; appendLog("エラー: \(message)"); return false }
        return true
    }

    private func runSSH(label: String, command: String, standardInput: String? = nil) {
        guard !sshCommandRunning, hostIsValid, !sshUsername.isEmpty, !sshPassword.isEmpty, let port = Int(sshPort) else { errorText = "SSH設定を確認してください"; return }
        sshCommandRunning = true; errorText = nil; appendLog("\(label) 実行: \(command)")
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines); let username = sshUsername; let password = sshPassword
        Task { [weak self, ssh] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ssh.execute(host: host, port: port, username: username, password: password, command: command, standardInput: standardInput) }.value
                self?.lastSSHResult = result; self?.appendLog("\(label) 終了コード=\(result.exitStatus)\n\(result.output)")
            } catch { self?.errorText = error.localizedDescription; self?.appendLog("\(label) エラー: \(error.localizedDescription)") }
            self?.sshCommandRunning = false
        }
    }

    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logs.insert("[\(timestamp)] \(message)", at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "host"); defaults.set(port, forKey: "port"); defaults.set(autoStartReceiver, forKey: "autoStartReceiver")
        defaults.set(sshUsername, forKey: "sshUsername"); defaults.set(sshPort, forKey: "sshPort")
    }

    private func persistControls() {
        let defaults = UserDefaults.standard
        defaults.set(speedPercent, forKey: "speedPercent"); defaults.set(emergencyStopMode.rawValue, forKey: "emergencyStopMode")
        Self.store(tuning, defaults: defaults, key: "tuning"); Self.store(customProfiles, defaults: defaults, key: "customProfiles")
        Self.store(selectedProfileID, defaults: defaults, key: "selectedProfileID")
    }

    private static func store<T: Encodable>(_ value: T, defaults: UserDefaults, key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
    private static func load<T: Decodable>(_ defaults: UserDefaults, key: String, fallback: T) -> T {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }; return value
    }
}
