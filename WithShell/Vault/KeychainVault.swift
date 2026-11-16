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

/// 개인키·비밀번호를 macOS 키체인에 저장하고, 꺼낼 때 Touch ID(또는 Mac 암호)로 본인 확인을 한다.
///
/// - 앱이 개발자 팀으로 서명되어 있으면 데이터 보호 키체인에 `.userPresence` 접근 제어를 걸어 저장한다.
///   이때는 OS가 직접 본인 확인을 강제한다.
/// - ad-hoc 서명(팀 없음)이라 데이터 보호 키체인을 쓸 수 없으면 로그인 키체인에 저장하고,
///   읽기 전에 앱이 LocalAuthentication으로 본인 확인을 한다.
@MainActor
final class KeychainVault {
    nonisolated static let service = "com.teamast.withshell.vault"
    /// 한 번 본인 확인을 하면 이 시간 동안은 다시 묻지 않는다.
    static let unlockDuration: TimeInterval = 5 * 60

    private var context: LAContext?
    private var unlockedAt: Date?

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
        for useDataProtection in [true, false] {
            var query = Self.baseQuery(account: account)
            query[kSecUseDataProtectionKeychain as String] = useDataProtection
            SecItemDelete(query as CFDictionary)
        }
    }

    /// 본인 확인 상태를 즉시 해제한다.
    func lock() {
        context?.invalidate()
        context = nil
        unlockedAt = nil
    }

    private func store(_ data: Data, account: String) throws {
        delete(account: account)

        // 1) 데이터 보호 키체인 + 본인 확인 필수
        var error: Unmanaged<CFError>?
        if let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error
        ) {
            var query = Self.baseQuery(account: account)
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessControl as String] = access
            query[kSecAttrSynchronizable as String] = false
            query[kSecValueData as String] = data
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { return }
            if status != errSecMissingEntitlement { throw VaultError.keychain(status) }
        }

        // 2) 로그인 키체인 (ad-hoc 서명 개발 빌드)
        var query = Self.baseQuery(account: account)
        query[kSecUseDataProtectionKeychain as String] = false
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    private func load(account: String, reason: String) async throws -> Data {
        let context = try await authenticatedContext(reason: reason)
        // 키체인 접근은 블로킹 호출이므로 백그라운드에서 실행한다.
        let result = await Task.detached { Self.copyItem(account: account, context: context) }.value
        return try result.get()
    }

    private func authenticatedContext(reason: String) async throws -> LAContext {
        if let context, let unlockedAt, Date.now.timeIntervalSince(unlockedAt) < Self.unlockDuration {
            return context
        }
        lock()

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = Self.unlockDuration
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw VaultError.authenticationFailed(error.localizedDescription)
        }
        self.context = context
        unlockedAt = .now
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
