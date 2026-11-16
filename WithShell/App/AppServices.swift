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
