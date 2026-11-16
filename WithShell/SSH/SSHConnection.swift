import Citadel
import Foundation
import NIOCore
import NIOSSH

/// SSH 연결 하나를 백그라운드에서 실행한다. UI(메인 스레드)와는 콜백과 입력 스트림으로만 통신한다.
final class SSHConnection: Sendable {
    enum Input: Sendable {
        case data([UInt8])
        case resize(cols: Int, rows: Int)
    }

    struct Target: Sendable {
        let host: String
        let port: Int
        let username: String
        let credential: SSHCredential
        var term = TerminalType.xterm256.rawValue
    }

    struct Events: Sendable {
        /// PTY가 열려 셸을 쓸 수 있게 됨
        let opened: @Sendable () async -> Void
        /// 서버 출력 (순서대로 전달됨)
        let output: @Sendable ([UInt8]) async -> Void
    }

    private let inputStream: AsyncStream<Input>
    private let inputContinuation: AsyncStream<Input>.Continuation

    init() {
        (inputStream, inputContinuation) = AsyncStream.makeStream(of: Input.self)
    }

    func send(_ bytes: [UInt8]) {
        inputContinuation.yield(.data(bytes))
    }

    func resize(cols: Int, rows: Int) {
        inputContinuation.yield(.resize(cols: cols, rows: rows))
    }

    /// 입력 스트림을 닫아 세션을 끝낸다. `run`은 채널과 연결을 닫고 반환한다.
    func finish() {
        inputContinuation.finish()
    }

    /// 접속 → 인증 → PTY 셸 열기 → 원격 쪽이 닫히거나 `finish()`가 호출될 때까지 입출력 중계.
    func run(
        target: Target,
        hostKeyValidator: HostKeyValidationBridge,
        initialSize: (cols: Int, rows: Int),
        events: Events
    ) async throws {
        let client = try await SSHClient.connect(
            host: target.host,
            port: target.port,
            authenticationMethod: try target.credential.authenticationMethod(username: target.username),
            hostKeyValidator: .custom(hostKeyValidator),
            reconnect: .never,
            connectTimeout: .seconds(15)
        )

        do {
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: target.term,
                terminalCharacterWidth: initialSize.cols,
                terminalRowHeight: initialSize.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            let inputStream = inputStream
            try await client.withPTY(request) { inbound, outbound in
                // Citadel의 스트림 타입은 Sendable 표시가 없지만, 각각 한 작업에서만 사용한다.
                let inbound = UncheckedSendable(inbound)
                let outbound = UncheckedSendable(outbound)
                await events.opened()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    // 키보드 입력 / 창 크기 변경 → 서버
                    group.addTask {
                        for await input in inputStream {
                            switch input {
                            case .data(let bytes):
                                try await outbound.value.write(ByteBuffer(bytes: bytes))
                            case .resize(let cols, let rows):
                                try await outbound.value.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                            }
                        }
                    }
                    // 서버 출력 → 터미널
                    group.addTask {
                        for try await chunk in inbound.value {
                            switch chunk {
                            case .stdout(let buffer), .stderr(let buffer):
                                await events.output(Array(buffer: buffer))
                            }
                        }
                    }
                    // 둘 중 하나가 끝나면(원격 종료 또는 탭 닫기) 세션을 정리한다.
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch ChannelError.alreadyClosed {
            // 원격 셸이 먼저 종료(exit)하면 Citadel이 이미 닫힌 채널을 다시 닫으려다 이 오류를 낸다. 정상 종료로 본다.
        } catch {
            try? await client.close()
            throw error
        }
        try? await client.close()
    }
}

enum SSHCredential: Sendable {
    case password(String)
    case privateKey(StoredPrivateKey)

    func authenticationMethod(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .password(let password):
            .passwordBased(username: username, password: password)
        case .privateKey(let key):
            try SSHKeyParser.authenticationMethod(username: username, privateKey: key.privateKey, passphrase: key.passphrase)
        }
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension Error {
    /// 사용자에게 보여줄 연결 오류 메시지
    var sshFriendlyMessage: String {
        switch self as Error {
        case let error as SSHKeyError:
            return error.errorDescription ?? "개인키 오류"
        case let error as VaultError:
            return error.errorDescription ?? "키체인 오류"
        case is HostKeyRejectedError:
            return "서버 호스트 키를 신뢰하지 않아 연결을 중단했습니다."
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed:
                return "인증에 실패했습니다. 사용자 이름과 비밀번호(또는 서버에 등록된 공개키)를 확인하세요."
            case .unsupportedPasswordAuthentication:
                return "서버가 비밀번호 인증을 허용하지 않습니다."
            default:
                return String(describing: error)
            }
        default:
            let description = String(describing: self)
            if description.contains("connectTimeout") { return "연결 시간이 초과되었습니다." }
            if description.contains("Connection refused") || description.contains("connectionRefused") {
                return "서버가 연결을 거부했습니다. 호스트와 포트를 확인하세요."
            }
            if description.contains("NXDOMAIN") || description.contains("nodename nor servname") {
                return "호스트 이름을 찾을 수 없습니다."
            }
            return description
        }
    }
}
