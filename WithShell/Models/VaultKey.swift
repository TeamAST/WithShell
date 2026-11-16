import Foundation
import SwiftData

/// 키 관리자에 등록된 SSH 개인키의 공개 정보.
/// 개인키 자체는 키체인(`KeychainVault`)에만 있고 여기에는 저장하지 않는다.
@Model
final class VaultKey {
    @Attribute(.unique) var id: UUID
    var name: String
    var algorithm: String
    var displayType: String
    var publicKey: String
    var fingerprint: String
    /// 원본 키가 패스프레이즈로 암호화되어 있었는지
    var wasEncrypted: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, info: SSHKeyInfo) {
        self.id = id
        self.name = name
        self.algorithm = info.algorithm
        self.displayType = info.displayType
        self.publicKey = info.openSSHPublicKey
        self.fingerprint = info.fingerprint
        self.wasEncrypted = info.isEncrypted
        self.createdAt = .now
    }

    /// authorized_keys에 붙여 넣을 한 줄
    var authorizedKeysLine: String {
        "\(publicKey) \(name.replacingOccurrences(of: " ", with: "-"))"
    }
}
