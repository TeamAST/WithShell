import SwiftTerm
import SwiftUI

/// 탭 하나의 본문.
struct SessionTabContentView: View {
    let tab: ConnectionTab

    var body: some View {
        if let ssh = tab.ssh {
            SSHTabView(session: ssh)
        } else if let rdp = tab.rdp {
            RDPTabView(session: rdp)
        }
    }
}

private struct SSHTabView: View {
    let session: SSHTerminalSession

    var body: some View {
        ZStack {
            TerminalHostView(terminalView: session.terminalView)
                .padding(.leading, 4)
                .background(Color(nsColor: session.backgroundColor))

            if let prompt = session.hostKeyPrompt {
                overlayBackground
                HostKeyPromptCard(request: prompt.request, host: session.snapshot.host) { trust in
                    session.answerHostKey(trust: trust)
                }
            } else if session.canConnect {
                overlayBackground
                ConnectCard(session: session)
            }
        }
    }

    private var overlayBackground: some View {
        Color.black.opacity(0.35)
            .ignoresSafeArea()
    }
}

/// SwiftTerm 터미널 화면을 SwiftUI에 붙인다. 화면 객체는 세션이 소유한다.
private struct TerminalHostView: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> TerminalView { terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

// MARK: - 연결 카드

struct ConnectCard: View {
    let session: any RemoteSession

    @State private var password = ""
    @State private var usesManualPassword = false
    @State private var promptUsername = ""
    @State private var promptDomain = ""

    private var snapshot: SessionSnapshot { session.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: snapshot.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(snapshot.kind == .ssh ? Color.green : Color.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name).font(.headline)
                    Text(snapshot.addressDescription)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = session.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.state == .disconnected {
                Label("연결이 종료되었습니다.", systemImage: "bolt.horizontal.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if snapshot.username.isEmpty && snapshot.kind == .rdp {
                credentialPrompt
            } else if snapshot.username.isEmpty {
                Text("세션 편집에서 사용자 이름을 먼저 입력하세요.")
                    .foregroundStyle(.secondary)
            } else {
                authControls
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { promptDomain = snapshot.domain }
    }

    /// RDP 세션에 사용자 이름이 저장되어 있지 않을 때: 사용자 이름·비밀번호·도메인 입력
    private var credentialPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("사용자 이름", text: $promptUsername, prompt: Text("사용자 이름"))
                .textFieldStyle(.roundedBorder)
            PasswordField(title: "비밀번호", text: $password, onSubmit: connectWithPrompt)
            TextField("도메인", text: $promptDomain, prompt: Text("도메인 (선택 · Active Directory)"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(connectWithPrompt)
            HStack {
                Text("입력한 정보는 저장되지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(connectTitle, action: connectWithPrompt)
                    .keyboardShortcut(.defaultAction)
                    .disabled(promptUsername.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
    }

    private func connectWithPrompt() {
        let username = promptUsername.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty, !password.isEmpty, let rdp = session as? RDPSession else { return }
        rdp.connect(username: username, domain: promptDomain, password: password)
        password = ""
    }

    private var connectTitle: String {
        session.state == .idle ? "연결" : "다시 연결"
    }

    @ViewBuilder
    private var authControls: some View {
            switch snapshot.authMethod {
            case .password where snapshot.hasSavedPassword && !usesManualPassword:
                HStack {
                    Button("다른 비밀번호 입력") { usesManualPassword = true }
                        .buttonStyle(.link)
                    Spacer()
                    Button(connectTitle, systemImage: "touchid") { session.connectUsingVault() }
                        .keyboardShortcut(.defaultAction)
                }
            case .password:
                Group {
                    PasswordField(title: "비밀번호", text: $password, autoFocus: true, onSubmit: connect)
                    HStack {
                        Spacer()
                        Button(connectTitle, action: connect)
                            .keyboardShortcut(.defaultAction)
                            .disabled(password.isEmpty)
                    }
                }
            case .privateKey:
                if let keyName = snapshot.keyName {
                    HStack {
                        Label(keyName, systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(connectTitle, systemImage: "touchid") { session.connectUsingVault() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("세션 편집에서 사용할 개인키를 선택하세요.")
                        .foregroundStyle(.secondary)
                }
            case .agent:
                Text("SSH Agent 인증은 아직 지원하지 않습니다.")
                    .foregroundStyle(.secondary)
            }
    }

    private func connect() {
        guard !password.isEmpty else { return }
        session.connect(password: password)
        password = ""
    }
}

// MARK: - 호스트 키 확인 카드

private struct HostKeyPromptCard: View {
    let request: HostKeyPrompt.Request
    let host: String
    let onAnswer: (Bool) -> Void

    private var isChanged: Bool { request.previousFingerprint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                isChanged ? "서버 호스트 키가 바뀌었습니다" : "처음 접속하는 서버입니다",
                systemImage: isChanged ? "exclamationmark.shield.fill" : "questionmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(isChanged ? .red : .primary)

            Text(isChanged
                 ? "저장된 키와 다른 키를 받았습니다. 서버를 다시 설치했거나 키를 바꾼 게 아니라면, 누군가 중간에서 연결을 가로채고 있을 수 있습니다."
                 : "‘\(host)’의 진위를 확인할 수 없습니다. 아래 지문이 서버 관리자가 알려준 값과 같은지 확인하세요.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                if let previous = request.previousFingerprint {
                    fingerprintRow("이전", previous)
                }
                fingerprintRow(isChanged ? "새 키" : request.info.algorithm, request.info.fingerprint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("연결 중단", role: .cancel) { onAnswer(false) }
                    .keyboardShortcut(.cancelAction)
                if isChanged {
                    Button("새 키를 신뢰하고 연결") { onAnswer(true) }
                } else {
                    Button("신뢰하고 연결") { onAnswer(true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
    }

    private func fingerprintRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

// MARK: - RDP

private struct RDPTabView: View {
    let session: RDPSession

    var body: some View {
        ZStack {
            RDPHostView(view: session.displayView)

            if let prompt = session.certificatePrompt {
                Color.black.opacity(0.35).ignoresSafeArea()
                CertificatePromptCard(info: prompt.info) { decision in
                    session.answerCertificate(decision)
                }
            } else if session.canConnect {
                Color.black.opacity(0.35).ignoresSafeArea()
                ConnectCard(session: session)
            } else if session.state == .connecting {
                ProgressView("\(session.snapshot.host)에 연결 중…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .background(Color.black)
    }
}

private struct RDPHostView: NSViewRepresentable {
    let view: RDPDisplayView

    func makeNSView(context: Context) -> RDPDisplayView { view }
    func updateNSView(_ nsView: RDPDisplayView, context: Context) {}
}

private struct CertificatePromptCard: View {
    let info: RDPCertificateInfo
    let onAnswer: (RDPCertificateDecision) -> Void

    private var isChanged: Bool { !(info.previousFingerprint ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                isChanged ? "서버 인증서가 바뀌었습니다" : "서버 인증서를 확인할 수 없습니다",
                systemImage: isChanged ? "exclamationmark.shield.fill" : "questionmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(isChanged ? .red : .primary)

            Text(isChanged
                 ? "이전에 신뢰한 인증서와 다릅니다. 서버 인증서를 새로 발급한 게 아니라면 누군가 연결을 가로채고 있을 수 있습니다."
                 : "‘\(info.host)’의 인증서를 신뢰할 수 있는 기관이 확인하지 않았습니다(자체 서명 인증서 등). 지문이 서버의 인증서와 같은지 확인하세요.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                row("이름", info.commonName)
                row("발급자", info.issuer)
                if let previous = info.previousFingerprint, !previous.isEmpty {
                    row("이전 지문", previous)
                }
                row(isChanged ? "새 지문" : "지문", info.fingerprint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("연결 중단", role: .cancel) { onAnswer(.reject) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("이번만 허용") { onAnswer(.acceptOnce) }
                Button(isChanged ? "새 인증서 신뢰" : "항상 신뢰") { onAnswer(.acceptPermanently) }
                    .keyboardShortcut(isChanged ? nil : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
