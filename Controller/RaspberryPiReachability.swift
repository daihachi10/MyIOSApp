import Darwin
import Foundation

struct PingResult: Equatable, Sendable {
    var reachable: Bool
    var roundTripMilliseconds: Double?
    var failureDescription: String?
}

protocol ReachabilityChecking: Sendable {
    func measure(host: String) async -> PingResult
}

/// Performs an ICMP echo request; it deliberately does not substitute TCP connection time for ping.
/// Some managed networks may disallow ICMP, in which case the reason is shown to the operator.
struct ICMPReachabilityChecker: ReachabilityChecking {
    func measure(host: String) async -> PingResult {
        await Task.detached(priority: .utility) { ICMPProbe.measure(host: host) }.value
    }
}

private enum ICMPProbe {
    static func measure(host: String) -> PingResult {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(reachable: false, roundTripMilliseconds: nil, failureDescription: "接続先が未入力です")
        }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_ICMP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &resolved) == 0, let addressInfo = resolved else {
            return .init(reachable: false, roundTripMilliseconds: nil, failureDescription: "名前解決に失敗しました")
        }
        defer { freeaddrinfo(addressInfo) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            return .init(reachable: false, roundTripMilliseconds: nil, failureDescription: "ICMPソケットを作成できません。ネットワーク権限を確認してください")
        }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var packet: [UInt8] = [8, 0, 0, 0, 0x12, 0x34, 0, 1]
        let checksum = internetChecksum(packet)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(checksum & 0xFF)
        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            sendto(fd, bytes.baseAddress, bytes.count, 0, addressInfo.pointee.ai_addr, addressInfo.pointee.ai_addrlen)
        }
        guard sent == packet.count else {
            return .init(reachable: false, roundTripMilliseconds: nil, failureDescription: "ICMP echo requestを送信できませんでした")
        }
        var response = [UInt8](repeating: 0, count: 256)
        let count = recv(fd, &response, response.count, 0)
        guard count > 0 else {
            return .init(reachable: false, roundTripMilliseconds: nil, failureDescription: "Raspberry Piからping応答がありません")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return .init(reachable: true, roundTripMilliseconds: elapsed, failureDescription: nil)
    }

    private static func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count { sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1]); index += 2 }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
}
