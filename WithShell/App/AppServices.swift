import Foundation
import SwiftData

/// 앱 전체에서 함께 쓰는 저장소·보안 서비스.
@MainActor
final class AppServices {
    let container: ModelContainer
    let knownHosts: KnownHostStore
    let vault = KeychainVault()
    let terminalAppearance = TerminalAppearanceStore()

    init(container: ModelContainer) {
        self.container = container
        knownHosts = KnownHostStore(context: container.mainContext)
    }

    func vaultKey(id: UUID?) -> VaultKey? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<VaultKey>(predicate: #Predicate { $0.id == id })
        return try? container.mainContext.fetch(descriptor).first
    }

    func sessionProfile(id: UUID) -> SessionProfile? {
        let descriptor = FetchDescriptor<SessionProfile>(predicate: #Predicate { $0.id == id })
        return try? container.mainContext.fetch(descriptor).first
    }

    /// 연결에 성공한 로그인 정보를 저장한다.
    /// 비밀번호는 키체인에, (세션에 비어 있던) 사용자 이름·도메인은 세션에 저장한다.
    func rememberCredentials(sessionID: UUID, password: String, username: String? = nil, domain: String? = nil) {
        guard let profile = sessionProfile(id: sessionID) else { return }
        if (try? vault.storePassword(password, sessionID: sessionID)) != nil {
            profile.hasSavedPassword = true
        }
        if let username, !username.isEmpty, profile.username.isEmpty {
            profile.username = username
        }
        if let domain, !domain.isEmpty, profile.domain.isEmpty {
            profile.domain = domain
        }
        try? container.mainContext.save()
    }

    /// 세션을 지울 때 키체인에 남은 비밀번호도 지운다.
    func deleteSession(_ session: SessionProfile) {
        vault.delete(account: KeychainVault.passwordAccount(session.id))
        container.mainContext.delete(session)
    }

    /// 키를 지우고, 그 키를 쓰던 세션의 연결을 해제한다.
    func deleteKey(_ key: VaultKey) {
        let keyID = key.id
        let descriptor = FetchDescriptor<SessionProfile>(predicate: #Predicate { $0.keyID == keyID })
        for session in (try? container.mainContext.fetch(descriptor)) ?? [] {
            session.keyID = nil
        }
        vault.delete(account: KeychainVault.keyAccount(keyID))
        container.mainContext.delete(key)
        try? container.mainContext.save()
    }
}
