import AppKit
import Foundation
import Observation
import SwiftTerm

/// 탭 하나의 SSH 터미널 상태. 터미널 화면(NSView)도 여기서 소유해서
/// SwiftUI가 화면을 다시 그려도 스크롤백과 화면 내용이 유지된다.
@MainActor
@Observable
final class SSHTerminalSession {
    let snapshot: SessionSnapshot

    private(set) var state: ConnectionState = .idle
    private(set) var hostKeyPrompt: HostKeyPrompt?
    private(set) var remoteTitle: String?
    /// 현재 프리셋의 배경색 (터미널 주변 여백에도 같은 색을 칠하기 위해)
    private(set) var backgroundColor: NSColor = .black

    @ObservationIgnored let terminalView: TerminalView
    @ObservationIgnored private let services: AppServices
    private var knownHosts: KnownHostStore { services.knownHosts }
    @ObservationIgnored private var bridge: TerminalBridge?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var size = (cols: 80, rows: 24)
    /// 단색 프리셋일 때 서버 출력의 색 코드를 지운다
    @ObservationIgnored private var colorStripper: SGRColorStripper?

    init(snapshot: SessionSnapshot, services: AppServices) {
        self.snapshot = snapshot
        self.services = services

        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminalView.optionAsMetaKey = true

        let bridge = TerminalBridge(session: self)
        terminalView.terminalDelegate = bridge
        self.bridge = bridge
        applyAppearance()
    }

    /// 세션(없으면 기본) 색상 프리셋과 글꼴 크기를 터미널에 적용한다.
    func applyAppearance() {
        let store = services.terminalAppearance
        let theme = store.resolvedTheme(id: snapshot.terminalThemeID)

        terminalView.font = NSFont.monospacedSystemFont(ofSize: CGFloat(store.fontSize), weight: .regular)
        terminalView.installColors(theme.ansi.map(HexColor.terminalColor))
        terminalView.nativeBackgroundColor = HexColor.nsColor(theme.background)
        terminalView.nativeForegroundColor = HexColor.nsColor(theme.foreground)
        terminalView.caretColor = HexColor.nsColor(theme.cursor)
        terminalView.selectedTextBackgroundColor = HexColor.nsColor(theme.selection)
        backgroundColor = HexColor.nsColor(theme.background)

        if theme.monochrome {
            if colorStripper == nil {
                colorStripper = SGRColorStripper()
                // 이미 칠해진 색 속성을 지워 이후 출력이 기본색으로 나오게 한다
                terminalView.feed(text: "\u{1B}[39;49m")
            }
        } else {
            colorStripper = nil
        }
        terminalView.needsDisplay = true
    }

    var canConnect: Bool {
        switch state {
        case .idle, .disconnected, .failed: true
        case .connecting, .connected: false
        }
    }

    // MARK: - 연결

    /// 키체인에 저장된 비밀번호나 개인키로 연결한다 (Touch ID로 본인 확인).
    func connectUsingVault() {
        guard canConnect else { return }
        state = .connecting
        let reason = "‘\(snapshot.name)’ 세션에 연결하기 위해"
        Task {
            do {
                let credential: SSHCredential
                switch snapshot.authMethod {
                case .privateKey:
                    guard let keyID = snapshot.keyID else {
                        throw VaultError.notFound
                    }
                    credential = .privateKey(try await services.vault.loadPrivateKey(id: keyID, reason: reason))
                case .password, .agent:
                    credential = .password(try await services.vault.loadPassword(sessionID: snapshot.sessionID, reason: reason))
                }
                state = .idle
                connect(credential: credential)
            } catch {
                state = .failed(error.sshFriendlyMessage)
            }
        }
    }

    func connect(password: String) {
        connect(credential: .password(password))
    }

    private func connect(credential: SSHCredential) {
        guard canConnect else { return }

        let connection = SSHConnection()
        self.connection = connection
        state = .connecting
        feedStatus("\(snapshot.addressDescription)에 연결 중…")

        let target = SSHConnection.Target(
            host: snapshot.host,
            port: snapshot.port,
            username: snapshot.username,
            credential: credential,
            term: services.terminalAppearance.resolvedType(snapshot.terminalType).rawValue
        )
        let validator = HostKeyValidationBridge { [weak self] info in
            await self?.evaluateHostKey(info) ?? false
        }
        let events = SSHConnection.Events(
            opened: { [weak self] in await self?.didOpenShell() },
            output: { [weak self] bytes in await self?.receive(bytes) }
        )
        let initialSize = size

        runTask = Task { [weak self] in
            do {
                try await connection.run(
                    target: target,
                    hostKeyValidator: validator,
                    initialSize: initialSize,
                    events: events
                )
                self?.didClose(error: nil, connection: connection)
            } catch {
                self?.didClose(error: error, connection: connection)
            }
        }
    }

    func disconnect() {
        connection?.finish()
        // 아직 접속·인증 중이면 그 단계를 취소한다.
        if state == .connecting { runTask?.cancel() }
        if let prompt = hostKeyPrompt {
            hostKeyPrompt = nil
            prompt.continuation.resume(returning: false)
        }
    }

    private func didOpenShell() {
        state = .connected
        // 연결 중에 창 크기가 바뀌었을 수 있으므로 현재 크기를 다시 알린다.
        connection?.resize(cols: size.cols, rows: size.rows)
        terminalView.window?.makeFirstResponder(terminalView)
    }

    private func didClose(error: Error?, connection: SSHConnection) {
        guard connection === self.connection else { return }
        self.connection = nil
        runTask = nil
        if let error, !(error is CancellationError) {
            state = .failed(error.sshFriendlyMessage)
            feedStatus("연결 실패: \(error.sshFriendlyMessage)")
        } else {
            state = .disconnected
            feedStatus("연결이 종료되었습니다.")
        }
    }

    private func receive(_ bytes: [UInt8]) {
        if colorStripper != nil {
            let filtered = colorStripper!.process(bytes)
            if !filtered.isEmpty { terminalView.feed(byteArray: filtered[...]) }
            return
        }
        terminalView.feed(byteArray: bytes[...])
    }

    private func feedStatus(_ message: String) {
        // 상태 메시지는 기본 글자색(흰색)으로 출력한다.
        terminalView.feed(text: "\r\n\u{1B}[0m[\(message)]\r\n")
    }

    // MARK: - 호스트 키 확인

    private func evaluateHostKey(_ info: HostKeyInfo) async -> Bool {
        switch knownHosts.check(host: snapshot.host, port: snapshot.port, info: info) {
        case .trusted:
            return true
        case .unknown:
            return await askHostKey(.init(info: info, previousFingerprint: nil))
        case .changed(let previous):
            return await askHostKey(.init(info: info, previousFingerprint: previous.fingerprint))
        }
    }

    private func askHostKey(_ request: HostKeyPrompt.Request) async -> Bool {
        let accepted = await withCheckedContinuation { continuation in
            hostKeyPrompt = HostKeyPrompt(request: request, continuation: continuation)
        }
        return accepted
    }

    func answerHostKey(trust: Bool) {
        guard let prompt = hostKeyPrompt else { return }
        hostKeyPrompt = nil
        if trust {
            knownHosts.trust(host: snapshot.host, port: snapshot.port, info: prompt.request.info)
        }
        prompt.continuation.resume(returning: trust)
    }

    // MARK: - 터미널 이벤트

    fileprivate func terminalDidSend(_ bytes: ArraySlice<UInt8>) {
        connection?.send(Array(bytes))
    }

    fileprivate func terminalDidResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        size = (cols, rows)
        if state == .connected { connection?.resize(cols: cols, rows: rows) }
    }

    fileprivate func terminalDidSetTitle(_ title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }
}

struct HostKeyPrompt {
    struct Request {
        let info: HostKeyInfo
        /// 이전에 저장된 지문. nil이면 처음 접속하는 서버.
        let previousFingerprint: String?
    }

    let request: Request
    let continuation: CheckedContinuation<Bool, Never>
}

/// SwiftTerm의 delegate(약한 참조)를 세션에 연결한다.
@MainActor
private final class TerminalBridge: TerminalViewDelegate {
    weak var session: SSHTerminalSession?

    init(session: SSHTerminalSession) {
        self.session = session
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.terminalDidResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        session?.terminalDidSetTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.terminalDidSend(data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        NSWorkspace.shared.open(url)
    }
}
