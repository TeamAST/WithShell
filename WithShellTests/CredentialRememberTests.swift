import Foundation
import Security
import SwiftData
import Testing
@testable import WithShell

/// 연결에 성공하면 비밀번호(·사용자 이름·도메인)를 저장하고, 이후 자동 연결 대상이 되는지.
/// 실제 테스트 서버가 필요하다 (scripts/test-sshd.sh, scripts/test-rdp.sh).
@MainActor
@Suite(.serialized)
struct CredentialRememberTests {
    static func makeServices() throws -> AppServices {
        let container = try ModelContainer(
            for: SessionProfile.self, SessionFolder.self, KnownHost.self, VaultKey.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AppServices(container: container)
    }

    static func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// 키체인에 비밀번호 항목이 있는지 (본인 확인 없이, 로그인 키체인에서 직접 조회)
    static func keychainHasPassword(_ sessionID: UUID) -> Bool {
        for useDataProtection in [true, false] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainVault.service,
                kSecAttrAccount as String: KeychainVault.passwordAccount(sessionID),
                kSecUseDataProtectionKeychain as String: useDataProtection,
            ]
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    @Test(.enabled(if: SSHConnectionTests.Config.fromEnvironment != nil))
    func sshPasswordIsRememberedAfterSuccessfulLogin() async throws {
        let config = try #require(SSHConnectionTests.Config.fromEnvironment)
        let services = try Self.makeServices()
        let profile = SessionProfile(name: "remember", kind: .ssh, host: config.host, port: config.port,
                                     username: config.user, authMethod: .password)
        services.container.mainContext.insert(profile)
        defer { services.vault.delete(account: KeychainVault.passwordAccount(profile.id)) }

        let session = SSHTerminalSession(snapshot: SessionSnapshot(profile, keyName: nil), services: services)
        #expect(!session.canAutoConnect, "저장된 비밀번호가 없으면 자동 연결하지 않음")

        session.connect(password: config.password, remember: true)
        let prompted = await Self.waitUntil(timeout: 10) { session.hostKeyPrompt != nil || session.state == .connected }
        #expect(prompted)
        if session.hostKeyPrompt != nil { session.answerHostKey(trust: true) }

        let connected = await Self.waitUntil(timeout: 10) { session.state == .connected }
        #expect(connected, "\(session.state)")
        #expect(profile.hasSavedPassword)
        #expect(session.hasSavedPassword)
        #expect(Self.keychainHasPassword(profile.id))

        session.disconnect()
        _ = await Self.waitUntil(timeout: 10) { session.state != .connected }
        #expect(session.canAutoConnect, "저장된 뒤에는 자동 연결 대상")
    }

    @Test(.enabled(if: SSHConnectionTests.Config.fromEnvironment != nil))
    func sshPasswordIsNotRememberedWhenUnchecked() async throws {
        let config = try #require(SSHConnectionTests.Config.fromEnvironment)
        let services = try Self.makeServices()
        let profile = SessionProfile(name: "no-remember", kind: .ssh, host: config.host, port: config.port,
                                     username: config.user, authMethod: .password)
        services.container.mainContext.insert(profile)
        defer { services.vault.delete(account: KeychainVault.passwordAccount(profile.id)) }

        let session = SSHTerminalSession(snapshot: SessionSnapshot(profile, keyName: nil), services: services)
        session.connect(password: config.password, remember: false)
        _ = await Self.waitUntil(timeout: 10) { session.hostKeyPrompt != nil || session.state == .connected }
        if session.hostKeyPrompt != nil { session.answerHostKey(trust: true) }
        let connected = await Self.waitUntil(timeout: 10) { session.state == .connected }
        #expect(connected)
        #expect(!profile.hasSavedPassword)
        #expect(!Self.keychainHasPassword(profile.id))
        session.disconnect()
    }

    @Test(.enabled(if: RDPConnectionTests.Config.fromEnvironment != nil))
    func rdpPromptedCredentialsAreRemembered() async throws {
        let config = try #require(RDPConnectionTests.Config.fromEnvironment)
        let services = try Self.makeServices()
        let profile = SessionProfile(name: "rdp-remember", kind: .rdp, host: config.host, port: config.port)
        services.container.mainContext.insert(profile)
        defer { services.vault.delete(account: KeychainVault.passwordAccount(profile.id)) }

        let session = RDPSession(snapshot: SessionSnapshot(profile, keyName: nil), services: services)
        #expect(session.username.isEmpty)
        #expect(!session.canAutoConnect)

        session.connect(username: config.user, domain: "WORKGROUP", password: config.password, remember: true)
        let prompted = await Self.waitUntil(timeout: 15) { session.certificatePrompt != nil || session.state == .connected }
        #expect(prompted)
        if session.certificatePrompt != nil { session.answerCertificate(.acceptOnce) }
        let connected = await Self.waitUntil(timeout: 20) { session.state == .connected }
        #expect(connected, "\(session.state)")

        #expect(profile.username == config.user)
        #expect(profile.domain == "WORKGROUP")
        #expect(profile.hasSavedPassword)
        #expect(Self.keychainHasPassword(profile.id))
        #expect(session.username == config.user)

        session.disconnect()
        _ = await Self.waitUntil(timeout: 10) { session.state != .connected }
        #expect(session.canAutoConnect)
    }
}
