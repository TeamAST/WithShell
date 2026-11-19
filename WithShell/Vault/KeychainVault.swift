import Foundation
import LocalAuthentication
import Security

/// 키 관리자에 보관하는 개인키 비밀 정보.
struct StoredPrivateKey: Codable, Sendable {
    var privateKey: String
    var passphrase: String?
}

enum VaultError: LocalizedError {
    case authenticationFailed(String)
    case notFound
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason): "본인 확인에 실패했습니다: \(reason)"
        case .notFound: "키체인에서 항목을 찾을 수 없습니다. 키 관리자에서 다시 등록하세요."
        case .keychain(let status):
            "키체인 오류 (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없음")"
        }
    }
}

/// 개인키·비밀번호를 macOS 키체인에 저장한다.
///
/// 본인 확인(Touch ID 또는 Mac 계정 암호)은 **앱을 실행한 뒤 처음 저장된 정보를 꺼낼 때 한 번만** 한다.
/// 그 뒤로는 앱을 끝내거나 직접 잠글 때까지 다시 묻지 않는다.
/// - 항목은 이 Mac에서만, 화면 잠금이 풀려 있을 때만 읽을 수 있게 저장한다 (iCloud 동기화 안 함).
/// - 데이터 보호 키체인을 쓸 수 없는 빌드(팀 권한 없음)에서는 로그인 키체인에 저장한다.
/// - 한 번 읽은 값은 잠글 때까지 메모리에 보관해 키체인 접근을 줄인다.
@MainActor
final class KeychainVault {
    nonisolated static let service = "com.teamast.withshell.vault"

    private var context: LAContext?
    /// 이번 실행에서 본인 확인을 마쳤는지
    private(set) var isUnlocked = false
    /// 잠금 해제 중 읽은 값 (잠그면 지운다)
    private var cache: [String: Data] = [:]

    // MARK: - 계정 이름

    nonisolated static func keyAccount(_ id: UUID) -> String { "key.\(id.uuidString)" }
    nonisolated static func passwordAccount(_ sessionID: UUID) -> String { "password.\(sessionID.uuidString)" }

    // MARK: - 개인키

    func storePrivateKey(_ secret: StoredPrivateKey, id: UUID) throws {
        try store(JSONEncoder().encode(secret), account: Self.keyAccount(id))
    }

    func loadPrivateKey(id: UUID, reason: String) async throws -> StoredPrivateKey {
        let data = try await load(account: Self.keyAccount(id), reason: reason)
        return try JSONDecoder().decode(StoredPrivateKey.self, from: data)
    }

    // MARK: - 비밀번호

    func storePassword(_ password: String, sessionID: UUID) throws {
        try store(Data(password.utf8), account: Self.passwordAccount(sessionID))
    }

    func loadPassword(sessionID: UUID, reason: String) async throws -> String {
        let data = try await load(account: Self.passwordAccount(sessionID), reason: reason)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 공통

    func delete(account: String) {
        cache[account] = nil
        for useDataProtection in [true, false] {
            var query = Self.baseQuery(account: account)
            query[kSecUseDataProtectionKeychain as String] = useDataProtection
            SecItemDelete(query as CFDictionary)
        }
    }

    /// 본인 확인 상태를 해제한다. 다음에 저장된 정보를 꺼낼 때 다시 확인한다.
    func lock() {
        context?.invalidate()
        context = nil
        isUnlocked = false
        cache.removeAll()
    }

    /// 이번 실행에서 아직 확인하지 않았으면 Touch ID / Mac 암호로 본인 확인을 한다.
    func unlock(reason: String) async throws {
        _ = try await authenticatedContext(reason: reason)
    }

    private func store(_ data: Data, account: String) throws {
        delete(account: account)

        // 1) 데이터 보호 키체인 (팀 서명 + 권한이 있는 빌드)
        var query = Self.baseQuery(account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        query[kSecValueData as String] = data
        var status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            guard status == errSecMissingEntitlement else { throw VaultError.keychain(status) }

            // 2) 로그인 키체인
            var legacy = Self.baseQuery(account: account)
            legacy[kSecUseDataProtectionKeychain as String] = false
            legacy[kSecValueData as String] = data
            status = SecItemAdd(legacy as CFDictionary, nil)
            guard status == errSecSuccess else { throw VaultError.keychain(status) }
        }
        // 이미 잠금 해제된 상태라면 방금 저장한 값을 바로 쓸 수 있게 둔다
        if isUnlocked { cache[account] = data }
    }

    private func load(account: String, reason: String) async throws -> Data {
        let context = try await authenticatedContext(reason: reason)
        if let cached = cache[account] { return cached }
        // 키체인 접근은 블로킹 호출이므로 백그라운드에서 실행한다.
        let data = try await Task.detached { Self.copyItem(account: account, context: context) }.value.get()
        cache[account] = data
        return data
    }

    private func authenticatedContext(reason: String) async throws -> LAContext {
        if isUnlocked, let context { return context }

        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw VaultError.authenticationFailed(error.localizedDescription)
        }
        self.context = context
        isUnlocked = true
        return context
    }

    private nonisolated static func copyItem(account: String, context: LAContext) -> Result<Data, VaultError> {
        for useDataProtection in [true, false] {
            var query = baseQuery(account: account)
            query[kSecUseDataProtectionKeychain as String] = useDataProtection
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if useDataProtection {
                query[kSecUseAuthenticationContext as String] = context
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                if let data = item as? Data { return .success(data) }
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                return .failure(.keychain(status))
            }
        }
        return .failure(.notFound)
    }

    private nonisolated static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension LAContext: @retroactive @unchecked Sendable {}
