import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct SSHCommandResult: Equatable, Sendable {
    var exitStatus: Int
    var standardOutput: String
    var standardError: String
    var succeeded: Bool { exitStatus == 0 }
    var output: String { [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n").isEmpty ? "（出力なし）" : [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum RaspberryPiCommand {
    static let maxCurrent = 4_000
    static let maxDriveRPM = 12_000
    static let killPython = "pkill python; pkill python3; true"
    static let shutdown = "sudo -S -p '' shutdown -h now"

    static func receiver(speedPercent: Int) -> String {
        let rpm = (maxDriveRPM * speedPercent.clamped(to: 0...100) / 100).clamped(to: 0...maxDriveRPM)
        return "exec python3 -u \"$HOME/DifferentialDriveRobomaster/controller_motor_receiver.py\" --max-rpm \(rpm) --max-current \(maxCurrent)"
    }
}

/// Password SSH client built on Apple SwiftNIO SSH. Passwords enter this type only from Keychain;
/// neither commands nor logs print them.
final class RaspberryPiSSHService: @unchecked Sendable {
    private let lock = NSLock()
    private var activeParent: Channel?
    private var activeGroup: MultiThreadedEventLoopGroup?

    func startReceiver(host: String, port: Int, username: String, password: String, speedPercent: Int, onStandardOutput: @escaping @Sendable (String) -> Void, onStandardError: @escaping @Sendable (String) -> Void) throws {
        close()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let parent = try connect(host: host, port: port, username: username, password: password, group: group)
            let exit = parent.eventLoop.makePromise(of: Int.self)
            _ = try openExec(on: parent, command: RaspberryPiCommand.receiver(speedPercent: speedPercent), standardInput: nil, exitPromise: exit, onStandardOutput: onStandardOutput, onStandardError: onStandardError)
            lock.lock(); activeGroup = group; activeParent = parent; lock.unlock()
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func execute(host: String, port: Int, username: String, password: String, command: String, standardInput: String? = nil, timeout: TimeAmount = .seconds(15)) throws -> SSHCommandResult {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let output = LockedLines()
        let errors = LockedLines()
        let parent = try connect(host: host, port: port, username: username, password: password, group: group)
        defer { _ = parent.close(mode: .all) }
        let exit = parent.eventLoop.makePromise(of: Int.self)
        let child = try openExec(on: parent, command: command, standardInput: standardInput, exitPromise: exit, onStandardOutput: output.append, onStandardError: errors.append)
        let timeoutTask = parent.eventLoop.scheduleTask(in: timeout) { child.close(promise: nil) }
        defer { timeoutTask.cancel() }
        _ = try child.closeFuture.wait()
        let status = (try? exit.futureResult.wait()) ?? -1
        return .init(exitStatus: status, standardOutput: output.text, standardError: errors.text)
    }

    func close() {
        lock.lock(); let parent = activeParent; let group = activeGroup; activeParent = nil; activeGroup = nil; lock.unlock()
        _ = parent?.close(mode: .all)
        try? group?.syncShutdownGracefully()
    }

    private func connect(host: String, port: Int, username: String, password: String, group: EventLoopGroup) throws -> Channel {
        guard !username.isEmpty, !password.isEmpty else { throw SSHError.missingCredentials }
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(3))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(role: .client(.init(
                        userAuthDelegate: PasswordAuthDelegate(username: username, password: password),
                        // Match the existing Android application's first-LAN-connection behavior.
                        // This is intentionally disclosed in the README.
                        serverAuthDelegate: AcceptAllHostKeysDelegate()
                    )), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        return try bootstrap.connect(host: host, port: port).wait()
    }

    private func openExec(on parent: Channel, command: String, standardInput: String?, exitPromise: EventLoopPromise<Int>, onStandardOutput: @escaping @Sendable (String) -> Void, onStandardError: @escaping @Sendable (String) -> Void) throws -> Channel {
        try parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
            let promise = parent.eventLoop.makePromise(of: Channel.self)
            ssh.createChannel(promise) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.invalidChannel) }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHExecHandler(command: command, standardInput: standardInput, completePromise: exitPromise, onStandardOutput: onStandardOutput, onStandardError: onStandardError))
                }
            }
            return promise.futureResult
        }.wait()
    }
}

private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let password: String
    init(username: String, password: String) { self.username = username; self.password = password }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.password) else { nextChallengePromise.fail(SSHError.passwordAuthenticationUnsupported); return }
        nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: password))))
    }
}

private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) { validationCompletePromise.succeed(()) }
}

private final class SSHExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let standardInput: String?
    private var completePromise: EventLoopPromise<Int>?
    private let onStandardOutput: @Sendable (String) -> Void
    private let onStandardError: @Sendable (String) -> Void

    init(command: String, standardInput: String?, completePromise: EventLoopPromise<Int>, onStandardOutput: @escaping @Sendable (String) -> Void, onStandardError: @escaping @Sendable (String) -> Void) {
        self.command = command; self.standardInput = standardInput; self.completePromise = completePromise
        self.onStandardOutput = onStandardOutput; self.onStandardError = onStandardError
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { context.fireErrorCaught($0) }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)).whenSuccess { [weak self, weak context] in
            guard let self, let context, let standardInput = self.standardInput else { return }
            var buffer = context.channel.allocator.buffer(capacity: standardInput.utf8.count)
            buffer.writeString(standardInput)
            context.writeAndFlush(self.wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            context.close(mode: .output, promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let incoming = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = incoming.data, let line = bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes), !line.isEmpty else { return }
        switch incoming.type {
        case .channel: onStandardOutput(line)
        case .stdErr: onStandardError(line)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            completePromise?.succeed(status.exitStatus); completePromise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let completePromise { completePromise.succeed(-1); self.completePromise = nil }
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock(); private var value = ""
    func append(_ text: String) { lock.lock(); value += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

private enum SSHError: LocalizedError {
    case missingCredentials, passwordAuthenticationUnsupported, invalidChannel
    var errorDescription: String? {
        switch self {
        case .missingCredentials: "SSHのユーザー名またはパスワードが未設定です"
        case .passwordAuthenticationUnsupported: "SSHサーバーがパスワード認証を受け付けません"
        case .invalidChannel: "SSHセッションを作成できませんでした"
        }
    }
}
