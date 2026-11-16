import Foundation
import Testing
@testable import WithShell

/// 실제 SSH 서버에 접속하는 통합 테스트.
/// `scripts/test-sshd.sh up` 후 `scripts/test-sshd.sh test`로 실행한다. 환경 변수가 없으면 건너뛴다.
struct SSHConnectionTests {
    struct Config {
        let host: String
        let port: Int
        let user: String
        let password: String

        static var fromEnvironment: Config? {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["WITHSHELL_TEST_SSH_HOST"],
                  let port = env["WITHSHELL_TEST_SSH_PORT"].flatMap(Int.init),
                  let user = env["WITHSHELL_TEST_SSH_USER"],
                  let password = env["WITHSHELL_TEST_SSH_PASSWORD"] else { return nil }
            return Config(host: host, port: port, user: user, password: password)
        }
    }

    actor Collector {
        var text = ""
        var hostKey: HostKeyInfo?
        func append(_ bytes: [UInt8]) { text += String(decoding: bytes, as: UTF8.self) }
        func record(_ key: HostKeyInfo) { hostKey = key }
    }

    @Test(.enabled(if: Config.fromEnvironment != nil))
    func passwordLoginRunsShellCommand() async throws {
        let config = try #require(Config.fromEnvironment)
        let collector = Collector()
        let connection = SSHConnection()

        let validator = HostKeyValidationBridge { info in
            await collector.record(info)
            return true
        }
        let events = SSHConnection.Events(
            opened: {
                connection.resize(cols: 100, rows: 30)
                connection.send(Array("stty size; echo with$((1+1))shell; exit\n".utf8))
            },
            output: { bytes in await collector.append(bytes) }
        )

        try await connection.run(
            target: .init(host: config.host, port: config.port, username: config.user, credential: .password(config.password)),
            hostKeyValidator: validator,
            initialSize: (cols: 80, rows: 24),
            events: events
        )

        let output = await collector.text
        #expect(output.contains("with2shell"), "셸 명령 출력이 없음: \(output)")
        #expect(output.contains("30 100"), "창 크기 변경이 반영되지 않음: \(output)")

        let key = try #require(await collector.hostKey)
        #expect(key.fingerprint.hasPrefix("SHA256:"))
        print("HOSTKEY \(key.algorithm) \(key.fingerprint)")
    }

    @Test(.enabled(if: Config.fromEnvironment != nil))
    func wrongPasswordFailsWithAuthError() async throws {
        let config = try #require(Config.fromEnvironment)
        let connection = SSHConnection()
        do {
            try await connection.run(
                target: .init(host: config.host, port: config.port, username: config.user, credential: .password("wrong-password")),
                hostKeyValidator: HostKeyValidationBridge { _ in true },
                initialSize: (cols: 80, rows: 24),
                events: .init(opened: {}, output: { _ in })
            )
            Issue.record("틀린 비밀번호로 연결이 성공함")
        } catch {
            #expect(error.sshFriendlyMessage.contains("인증에 실패"), "\(error)")
        }
    }

    @Test(.enabled(if: Config.fromEnvironment != nil))
    func rejectedHostKeyStopsConnection() async throws {
        let config = try #require(Config.fromEnvironment)
        let connection = SSHConnection()
        do {
            try await connection.run(
                target: .init(host: config.host, port: config.port, username: config.user, credential: .password(config.password)),
                hostKeyValidator: HostKeyValidationBridge { _ in false },
                initialSize: (cols: 80, rows: 24),
                events: .init(opened: {}, output: { _ in })
            )
            Issue.record("호스트 키를 거부했는데 연결이 성공함")
        } catch {
            #expect(error.sshFriendlyMessage.contains("호스트 키"), "\(error)")
        }
    }

    @Test(.enabled(if: Config.fromEnvironment != nil), arguments: SSHKeyTests.allFixtures + SSHKeyTests.pemFixtures)
    func privateKeyLogin(fixture: String) async throws {
        let config = try #require(Config.fromEnvironment)
        // 앱과 같은 경로: 가져오기(필요하면 PEM 변환) → 키체인에 저장될 값으로 로그인
        let key = try SSHKeyParser.prepareForStorage(
            try SSHKeyTests.fixture(fixture), passphrase: SSHKeyTests.passphrase(for: fixture), comment: fixture
        ).secret
        let collector = Collector()
        let connection = SSHConnection()
        try await connection.run(
            target: .init(host: config.host, port: config.port, username: config.user, credential: .privateKey(key)),
            hostKeyValidator: HostKeyValidationBridge { _ in true },
            initialSize: (cols: 80, rows: 24),
            events: .init(
                opened: { connection.send(Array("echo key-$((2+3))-ok; exit\n".utf8)) },
                output: { await collector.append($0) }
            )
        )
        #expect(await collector.text.contains("key-5-ok"), "\(fixture)")
    }

    /// 서버에 등록되지 않은 키는 거부된다.
    @Test(.enabled(if: Config.fromEnvironment != nil))
    func unregisteredKeyIsRejected() async throws {
        let config = try #require(Config.fromEnvironment)
        let key = StoredPrivateKey(privateKey: SSHKeyParser.generateEd25519(comment: "not-registered"))
        do {
            try await SSHConnection().run(
                target: .init(host: config.host, port: config.port, username: config.user, credential: .privateKey(key)),
                hostKeyValidator: HostKeyValidationBridge { _ in true },
                initialSize: (cols: 80, rows: 24),
                events: .init(opened: {}, output: { _ in })
            )
            Issue.record("등록되지 않은 키로 로그인됨")
        } catch {
            #expect(error.sshFriendlyMessage.contains("인증에 실패"), "\(error)")
        }
    }

    /// 선택한 터미널 종류가 원격의 TERM 으로 전달된다.
    @Test(.enabled(if: Config.fromEnvironment != nil), arguments: [TerminalType.vt100, .linux, .xterm256])
    func terminalTypeIsSentAsTERM(type: TerminalType) async throws {
        let config = try #require(Config.fromEnvironment)
        let collector = Collector()
        let connection = SSHConnection()
        try await connection.run(
            target: .init(host: config.host, port: config.port, username: config.user,
                          credential: .password(config.password), term: type.rawValue),
            hostKeyValidator: HostKeyValidationBridge { _ in true },
            initialSize: (cols: 80, rows: 24),
            events: .init(
                opened: { connection.send(Array("echo TERM=[$TERM]; exit\n".utf8)) },
                output: { await collector.append($0) }
            )
        )
        let output = await collector.text
        #expect(output.contains("TERM=[\(type.rawValue)]"), "\(output)")
    }
}
