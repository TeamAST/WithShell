import Foundation
import SwiftData

/// 저장된 접속 정보. 비밀번호와 개인키는 여기에 저장하지 않고,
/// 키 관리자(Keychain)에 보관한 뒤 `keyID`로만 참조한다.
@Model
final class SessionProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var kindRaw: String
    var host: String
    var port: Int
    var username: String
    /// RDP 도메인 (Active Directory). 비어 있으면 사용자 이름의 `DOMAIN\user` 형식을 따른다.
    var domain: String = ""
    var authMethodRaw: String
    /// 키 관리자 항목 ID (개인키 인증일 때 사용)
    var keyID: UUID?
    /// 비밀번호를 키체인에 저장해 두었는지 (비밀번호 자체는 키체인에만 있음)
    var hasSavedPassword: Bool = false
    /// SSH 터미널 색상 프리셋 ID (비어 있으면 기본 설정)
    var terminalThemeID: String = ""
    /// SSH 터미널 종류 TERM (비어 있으면 기본 설정)
    var terminalType: String = ""
    var notes: String
    var createdAt: Date
    var lastConnectedAt: Date?
    var folder: SessionFolder?

    init(
        name: String,
        kind: ConnectionKind,
        host: String,
        port: Int? = nil,
        username: String = "",
        authMethod: AuthMethod = .password,
        keyID: UUID? = nil,
        notes: String = "",
        folder: SessionFolder? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.keyID = keyID
        self.notes = notes
        self.createdAt = .now
        self.folder = folder
    }

    var kind: ConnectionKind {
        get { ConnectionKind(rawValue: kindRaw) ?? .ssh }
        set { kindRaw = newValue.rawValue }
    }

    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    /// 예: `root@10.0.0.5:22`
    var addressDescription: String {
        let qualified = domain.isEmpty || username.isEmpty ? username : "\(domain)\\\(username)"
        let userPart = qualified.isEmpty ? "" : "\(qualified)@"
        return "\(userPart)\(host):\(port)"
    }
}

@Model
final class SessionFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    @Relationship(deleteRule: .nullify, inverse: \SessionProfile.folder)
    var sessions: [SessionProfile] = []

    init(name: String, sortOrder: Int) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
    }
}
