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
            do {
                let candidate = try await connect(host: host, port: port)
                connection = candidate
                try await send(bytes: Array("Hello Raspi!\n".utf8), on: candidate)
                try await send(bytes: ControllerPacketEncoder.neutralPacket(), on: candidate)
                eventHandler(.connected)
                startLoop(on: candidate)
                return
            } catch {
                lastError = error
                if attempt < 5 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        self.eventHandler = nil
        throw RobotTcpError.connectionFailed(lastError?.localizedDescription ?? "TCP接続に失敗しました")
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
        let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: continuation.resume()
                        case .failed(let error): continuation.resume(throwing: error)
                        case .cancelled: continuation.resume(throwing: RobotTcpError.cancelled)
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw RobotTcpError.timedOut }
            defer { group.cancelAll() }
            try await group.next()!
        }
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
    case timedOut, cancelled, connectionFailed(String)
    var errorDescription: String? {
        switch self {
        case .timedOut: "TCP接続が3秒以内に完了しませんでした"
        case .cancelled: "TCP接続が中止されました"
        case .connectionFailed(let message): message
        }
    }
}
