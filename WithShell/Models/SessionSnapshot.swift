import Foundation

/// 탭을 열 때 복사해 두는 접속 정보.
/// 탭이 열린 뒤 원본 세션이 수정·삭제되어도 진행 중인 연결에는 영향을 주지 않는다.
struct SessionSnapshot: Sendable, Hashable {
    let sessionID: UUID
    let name: String
    let kind: ConnectionKind
    let host: String
    let port: Int
    let username: String
    let domain: String
    let authMethod: AuthMethod
    let keyID: UUID?
    let keyName: String?
    let hasSavedPassword: Bool
    let terminalThemeID: String
    let terminalType: String

    init(_ profile: SessionProfile, keyName: String?) {
        sessionID = profile.id
        name = profile.name
        kind = profile.kind
        host = profile.host
        port = profile.port
        username = profile.username
        domain = profile.domain
        authMethod = profile.authMethod
        keyID = profile.keyID
        self.keyName = keyName
        hasSavedPassword = profile.hasSavedPassword
        terminalThemeID = profile.terminalThemeID
        terminalType = profile.terminalType
    }

    var addressDescription: String {
        let qualified = domain.isEmpty || username.isEmpty ? username : "\(domain)\\\(username)"
        let userPart = qualified.isEmpty ? "" : "\(qualified)@"
        return "\(userPart)\(host):\(port)"
    }
}
