import AppKit
import Foundation
import Observation

/// 탭 하나의 RDP 연결 상태. 화면 뷰도 여기서 소유한다.
@MainActor
@Observable
final class RDPSession: RemoteSession {
    let snapshot: SessionSnapshot

    private(set) var state: ConnectionState = .idle
    private(set) var certificatePrompt: RDPCertificatePrompt?
    private(set) var remoteSize: CGSize = .zero

    @ObservationIgnored let displayView = RDPDisplayView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var connection: RDPConnection?
    @ObservationIgnored private var clipboardTimer: Timer?
    @ObservationIgnored private var lastPasteboardChange = -1

    init(snapshot: SessionSnapshot, services: AppServices) {
        self.snapshot = snapshot
        self.services = services
        displayView.onResizeRequest = { [weak self] size, scale in
            self?.requestResize(pixelSize: size, scale: scale)
        }
        displayView.onFocus = { [weak self] in
            self?.syncLocalClipboard()
        }
    }

    var canConnect: Bool {
        switch state {
        case .idle, .disconnected, .failed: true
        case .connecting, .connected: false
        }
    }

    // MARK: - 연결

    func connectUsingVault() {
        guard canConnect else { return }
        state = .connecting
        Task {
            do {
                let password = try await services.vault.loadPassword(
                    sessionID: snapshot.sessionID,
                    reason: "‘\(snapshot.name)’ 원격 데스크톱에 연결하기 위해"
                )
                state = .idle
                connect(password: password)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func connect(password: String) {
        connect(username: snapshot.username, domain: snapshot.domain, password: password)
    }

    /// 사용자 이름이 `DOMAIN\user` 형식이면 도메인을 분리하되, 도메인 칸에 값이 있으면 그 값을 쓴다.
    nonisolated static func resolveCredentials(username: String, domain: String) -> (username: String, domain: String) {
        let (embeddedDomain, user) = splitDomain(username.trimmingCharacters(in: .whitespaces))
        let explicit = domain.trimmingCharacters(in: .whitespaces)
        return (user, explicit.isEmpty ? embeddedDomain : explicit)
    }

    func connect(username rawUsername: String, domain rawDomain: String, password: String) {
        guard canConnect else { return }

        let (username, domain) = Self.resolveCredentials(username: rawUsername, domain: rawDomain)
        let preferred = displayView.preferredRemoteSize
        let scales = Self.scaleFactors(for: preferred.scale)
        let config = RDPConnection.Config(
            host: snapshot.host,
            port: snapshot.port,
            username: username,
            domain: domain,
            password: password,
            width: max(640, Int(preferred.size.width)),
            height: max(480, Int(preferred.size.height)),
            desktopScale: scales.desktop,
            deviceScale: scales.device
        )

        let connection = RDPConnection(
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            },
            onCertificate: { [weak self] info, reply in
                Task { @MainActor in
                    guard let self else { return reply(.reject) }
                    self.certificatePrompt = RDPCertificatePrompt(info: info, reply: reply)
                }
            }
        )
        displayView.connection = connection
        self.connection = connection
        state = .connecting

        if !connection.start(config) {
            self.connection = nil
            state = .failed("RDP 연결을 시작할 수 없습니다.")
        }
    }

    func disconnect() {
        if let prompt = certificatePrompt {
            certificatePrompt = nil
            prompt.reply(.reject)
        }
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        connection?.stop()
        connection = nil
        displayView.applyCursor(.arrow)
        if state == .connecting || state == .connected {
            state = .disconnected
        }
    }

    func answerCertificate(_ decision: RDPCertificateDecision) {
        guard let prompt = certificatePrompt else { return }
        certificatePrompt = nil
        prompt.reply(decision)
    }

    // MARK: - 이벤트

    private func handle(_ event: RDPConnection.Event) {
        switch event {
        case .connecting:
            state = .connecting
        case .connected:
            state = .connected
            displayView.window?.makeFirstResponder(displayView)
            startClipboardSync()
        case .resized(let width, let height):
            remoteSize = CGSize(width: width, height: height)
        case .frameUpdated:
            displayView.displayFrame()
        case .cursor(let cursor):
            displayView.applyCursor(cursor)
        case .remoteClipboard(let text):
            // 원격에서 복사한 텍스트 → Mac 클립보드 (다시 원격으로 되돌려 보내지 않도록 변경 번호 기록)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastPasteboardChange = pasteboard.changeCount
        case .disconnected:
            finish(.disconnected)
        case .failed(let name, let message):
            finish(.failed(Self.friendlyMessage(name: name, message: message)))
        }
    }

    func sendCtrlAltDelete() {
        displayView.sendCtrlAltDelete()
    }

    // MARK: - 클립보드

    private func startClipboardSync() {
        lastPasteboardChange = -1
        syncLocalClipboard()
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncLocalClipboard() }
        }
    }

    /// Mac 클립보드의 텍스트가 바뀌었으면 원격에 알린다.
    private func syncLocalClipboard() {
        guard state == .connected, let connection else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        connection.setLocalClipboard(pasteboard.string(forType: .string))
    }

    private func finish(_ newState: ConnectionState) {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        certificatePrompt = nil
        connection?.stop()
        connection = nil
        state = newState
    }

    private func requestResize(pixelSize: CGSize, scale: CGFloat) {
        guard state == .connected, let connection else { return }
        let scales = Self.scaleFactors(for: scale)
        connection.requestResize(
            width: Int(pixelSize.width), height: Int(pixelSize.height),
            desktopScale: scales.desktop, deviceScale: scales.device
        )
    }

    // MARK: - 도우미

    /// `DOMAIN\user` 형식이면 도메인을 분리한다. (`user@domain` 은 그대로 둔다)
    nonisolated static func splitDomain(_ value: String) -> (domain: String, username: String) {
        guard let index = value.firstIndex(of: "\\") else { return ("", value) }
        return (String(value[..<index]), String(value[value.index(after: index)...]))
    }

    /// Retina(2배)에서는 원격 데스크톱도 200% 배율로 표시해 글자가 Mac과 같은 크기로 보이게 한다.
    nonisolated static func scaleFactors(for backingScale: CGFloat) -> (desktop: Int, device: Int) {
        let desktop = Int((backingScale * 100).rounded())
        let device = backingScale >= 1.8 ? 180 : (backingScale >= 1.4 ? 140 : 100)
        return (min(500, max(100, desktop)), device)
    }

    nonisolated static func friendlyMessage(name: String, message: String) -> String {
        switch name {
        case "ERRCONNECT_LOGON_FAILURE", "ERRCONNECT_AUTHENTICATION_FAILED", "ERRCONNECT_WRONG_PASSWORD":
            [
                "로그인에 실패했습니다 (NLA). 사용자 이름과 비밀번호를 확인하세요.",
                "· 로컬 계정: 사용자 이름만, 또는 ‘컴퓨터이름\\사용자’",
                "· Microsoft 계정: 이메일 주소와 계정 비밀번호 (Windows Hello PIN은 안 됨)",
                "· 도메인 계정: ‘도메인\\사용자’ 또는 ‘사용자@도메인’",
            ].joined(separator: "\n")
        case "ERRCONNECT_LOGON_TYPE_NOT_GRANTED", "ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES":
            "이 계정은 원격 데스크톱 접속 권한이 없습니다. 서버에서 ‘Remote Desktop Users’ 그룹에 추가하세요."
        case "ERRCONNECT_NO_OR_MISSING_CREDENTIALS":
            "사용자 이름 또는 비밀번호가 비어 있습니다."
        case "ERRCONNECT_SERVER_DENIED_CONNECTION", "ERRINFO_SERVER_DENIED_CONNECTION":
            "서버가 연결을 거부했습니다. 원격 데스크톱이 켜져 있는지 확인하세요."
        case "ERRCONNECT_PASSWORD_EXPIRED", "ERRCONNECT_PASSWORD_MUST_CHANGE", "ERRCONNECT_PASSWORD_CERTAINLY_EXPIRED":
            "비밀번호가 만료되었습니다. 서버에서 비밀번호를 변경하세요."
        case "ERRCONNECT_ACCOUNT_LOCKED_OUT":
            "계정이 잠겼습니다."
        case "ERRCONNECT_ACCOUNT_DISABLED":
            "비활성화된 계정입니다."
        case "ERRCONNECT_DNS_NAME_NOT_FOUND":
            "호스트 이름을 찾을 수 없습니다."
        case "ERRCONNECT_CONNECT_TRANSPORT_FAILED", "ERRCONNECT_CONNECT_FAILED":
            "서버에 연결할 수 없습니다. 호스트와 포트(기본 3389)를 확인하세요."
        case "ERRCONNECT_TLS_CONNECT_FAILED":
            "TLS 연결에 실패했습니다. 서버 인증서를 거부했거나 보안 설정이 맞지 않습니다."
        case "ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED":
            "보안 협상(NLA/TLS)에 실패했습니다. 서버의 보안 설정을 확인하세요."
        case "ERRCONNECT_CONNECT_CANCELLED":
            "연결을 취소했습니다."
        default:
            message.isEmpty ? "연결이 끊어졌습니다 (\(name))." : "\(message) (\(name))"
        }
    }

    /// FreeRDP 로그 파일 위치 (샌드박스 컨테이너 안)
    nonisolated static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WithShell/freerdp.log")
    }
}

struct RDPCertificatePrompt {
    let info: RDPCertificateInfo
    let reply: @Sendable (RDPCertificateDecision) -> Void
}
