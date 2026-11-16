import Foundation
import SwiftData

/// 신뢰하기로 한 서버 호스트 키 (OpenSSH의 known_hosts와 같은 역할).
@Model
final class KnownHost {
    /// `host:port` 형태의 조회 키
    @Attribute(.unique) var endpoint: String
    var algorithm: String
    /// OpenSSH 공개키 형식 (`ssh-ed25519 AAAA...`)
    var publicKey: String
    var fingerprint: String
    var addedAt: Date

    init(endpoint: String, info: HostKeyInfo) {
        self.endpoint = endpoint
        self.algorithm = info.algorithm
        self.publicKey = info.openSSHKey
        self.fingerprint = info.fingerprint
        self.addedAt = .now
    }

    static func endpoint(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }
}
