import Foundation
import Network

enum RobotSessionEvent: Sendable {
    case connecting(attempt: Int, maximumAttempts: Int)
    case connected
    case packetSent([UInt8])
    case failed(String)
}

/// A single serial TCP sender. It retains only the newest controller frame, so a slow LAN cannot
/// turn old steering data into an ever-growing packet queue.
actor RobotTcpSession {
    private var connection: NWConnection?
    private var sendTask: Task<Void, Never>?
    private var latestPacket = ControllerPacketEncoder.neutralPacket()
    private var eventHandler: (@Sendable (RobotSessionEvent) -> Void)?
    private var stopping = false

    func start(host: String, port: UInt16, eventHandler: @escaping @Sendable (RobotSessionEvent) -> Void) async throws {
        guard connection == nil else { return }
        self.eventHandler = eventHandler
        stopping = false
        var lastError: Error?
        for attempt in 1...5 {
            eventHandler(.connecting(attempt: attempt, maximumAttempts: 5))
            var candidate: NWConnection?
            do {
                candidate = try await connect(host: host, port: port)
                guard let candidate else { throw RobotTcpError.cancelled }
                connection = candidate
                try await send(bytes: Array("Hello Raspi!\n".utf8), on: candidate)
                try await send(bytes: ControllerPacketEncoder.neutralPacket(), on: candidate)
                eventHandler(.connected)
                startLoop(on: candidate)
                return
            } catch {
                candidate?.cancel()
                connection = nil
                lastError = error
                if attempt < 5 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        self.eventHandler = nil
        throw RobotTcpError.connectionFailed(lastError?.localizedDescription ?? String(localized: "TCP接続に失敗しました"))
    }

    func update(snapshot: ControllerSnapshot, tuning: ControlTuning) {
        guard !stopping else { return }
        latestPacket = ControllerPacketEncoder.encode(snapshot, tuning: tuning)
    }

    func stop(emergency: Bool = false) async {
        guard let connection else { cleanup(); return }
        stopping = true
        sendTask?.cancel()
        sendTask = nil
        if emergency {
            let packet = ControllerPacketEncoder.encode(.init(buttons: [.options]))
            for _ in 0..<3 { try? await send(bytes: packet, on: connection) }
        }
        for _ in 0..<3 { try? await send(bytes: ControllerPacketEncoder.neutralPacket(), on: connection) }
        connection.cancel()
        cleanup()
    }

    private func startLoop(on connection: NWConnection) {
        sendTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let frame = await self.latestPacket
                do {
                    try await self.send(bytes: frame, on: connection)
                    await self.emit(.packetSent(frame))
                } catch {
                    await self.emit(.failed(error.localizedDescription))
                    await self.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func connect(host: String, port: UInt16) async throws -> NWConnection {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RobotTcpError.invalidPort }
        let connection = NWConnection(host: .init(host), port: endpointPort, using: parameters)
        try await NWConnectionReadyWaiter(connection: connection, timeout: 3).wait()
        return connection
    }

    private func send(bytes: [UInt8], on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func emit(_ event: RobotSessionEvent) { eventHandler?(event) }

    private func cleanup() {
        connection = nil
        sendTask = nil
        eventHandler = nil
        latestPacket = ControllerPacketEncoder.neutralPacket()
    }
}

enum RobotTcpError: LocalizedError {
    case timedOut, cancelled, invalidPort, connectionFailed(String)
    var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "TCP接続が3秒以内に完了しませんでした")
        case .cancelled: String(localized: "TCP接続が中止されました")
        case .invalidPort: String(localized: "TCPポートは1～65535で入力してください")
        case .connectionFailed(let message): message
        }
    }
}

/// Waits for exactly one terminal NWConnection state. The state handler and timeout run on
/// the same serial queue, preventing checked continuations from being resumed more than once.
private final class NWConnectionReadyWaiter: @unchecked Sendable {
    private let connection: NWConnection
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.daihachi10.controller.tcp-connect")
    private var continuation: CheckedContinuation<Void, Error>?
    private var completed = false

    init(connection: NWConnection, timeout: TimeInterval) {
        self.connection = connection
        self.timeout = timeout
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                    self?.finish(.failure(RobotTcpError.timedOut), cancelConnection: true)
                }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finish(.success(()), cancelConnection: false)
        case .failed(let error):
            finish(.failure(error), cancelConnection: true)
        case .cancelled:
            finish(.failure(RobotTcpError.cancelled), cancelConnection: false)
        default:
            break
        }
    }

    private func finish(_ result: Result<Void, Error>, cancelConnection: Bool) {
        guard !completed, let continuation else { return }
        completed = true
        self.continuation = nil
        connection.stateUpdateHandler = nil
        if cancelConnection { connection.cancel() }
        continuation.resume(with: result)
    }
}
