import SwiftData
import SwiftUI

struct SessionEditorView: View {
    let request: SessionEditorRequest

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SessionFolder.sortOrder) private var folders: [SessionFolder]
    @Query(sort: \VaultKey.name) private var keys: [VaultKey]

    @State private var draft = SessionDraft()
    @State private var editingSession: SessionProfile?
    @State private var didLoad = false
    @State private var saveError: String?

    private var isNew: Bool { editingSession == nil }
    private var appearance: TerminalAppearanceStore { app.services.terminalAppearance }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("일반") {
                    TextField("이름", text: $draft.name, prompt: Text(draft.host.isEmpty ? "예: 운영 웹 서버" : draft.host))
                    Picker("종류", selection: $draft.kind) {
                        ForEach(ConnectionKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("폴더", selection: $draft.folderID) {
                        Text("없음").tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                }

                Section("연결") {
                    TextField("호스트", text: $draft.host, prompt: Text("example.com 또는 192.168.0.10"))
                    TextField("포트", value: $draft.port, format: .number.grouping(.never))
                    TextField(
                        "사용자 이름",
                        text: $draft.username,
                        prompt: Text(draft.kind == .rdp ? "비워 두면 연결할 때 입력" : "root")
                    )
                    if draft.kind == .rdp {
                        TextField("도메인", text: $draft.domain, prompt: Text("Active Directory 도메인 (예: CORP)"))
                    }
                }

                Section("인증") {
                    Picker("방식", selection: $draft.authMethod) {
                        ForEach(AuthMethod.available(for: draft.kind)) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    authDetail
                }

                if draft.kind == .ssh {
                    Section("터미널") {
                        Picker("색상 프리셋", selection: $draft.terminalThemeID) {
                            Text("기본 설정 따름 (\(appearance.resolvedTheme(id: nil).name))").tag("")
                            Divider()
                            ForEach(appearance.allThemes) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                        Picker("터미널 종류 (TERM)", selection: $draft.terminalType) {
                            Text("기본 설정 따름 (\(appearance.defaultTerminalType.rawValue))").tag("")
                            Divider()
                            ForEach(TerminalType.allCases) { type in
                                Text(type.displayName).tag(type.rawValue)
                            }
                        }
                    }
                }

                Section("메모") {
                    TextField("메모", text: $draft.notes, prompt: Text("선택 사항"), axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let message = saveError ?? validationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "추가" : "저장") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
            .padding()
        }
        .frame(width: 480, height: 660)
        .onAppear(perform: load)
        .onChange(of: draft.kind) { oldKind, newKind in
            if draft.port == oldKind.defaultPort {
                draft.port = newKind.defaultPort
            }
            if !AuthMethod.available(for: newKind).contains(draft.authMethod) {
                draft.authMethod = .password
            }
        }
    }

    @ViewBuilder
    private var authDetail: some View {
        switch draft.authMethod {
        case .password:
            Toggle("비밀번호를 키체인에 저장", isOn: $draft.savePassword)
            if draft.savePassword {
                PasswordField(
                    title: draft.hadSavedPassword ? "비밀번호 (바꿀 때만 입력)" : "비밀번호 (선택)",
                    text: $draft.newPassword
                )
            }
            Text(draft.savePassword
                 ? "키체인에 저장됩니다. 비워 두면 처음 연결할 때 입력한 비밀번호를 저장합니다. 본인 확인(Touch ID)은 앱 실행 후 처음 한 번만 합니다."
                 : "연결할 때마다 비밀번호를 묻습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .privateKey:
            Picker("개인키", selection: $draft.keyID) {
                Text("선택 안 함").tag(UUID?.none)
                ForEach(keys) { key in
                    Text("\(key.name) (\(key.displayType))").tag(Optional(key.id))
                }
            }
            HStack {
                if keys.isEmpty {
                    Text("등록된 키가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let key = keys.first(where: { $0.id == draft.keyID }) {
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("키 관리자 열기…") { openWindow(id: KeyManagerView.windowID) }
            }
        case .agent:
            Text("SSH_AUTH_SOCK의 ssh-agent에 등록된 키를 사용합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var validationMessage: String? {
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "호스트를 입력하세요." }
        if host.contains(where: \.isWhitespace) { return "호스트에 공백을 넣을 수 없습니다." }
        if !(1...65535).contains(draft.port) { return "포트는 1–65535 사이여야 합니다." }
        if draft.authMethod == .privateKey && !keys.contains(where: { $0.id == draft.keyID }) {
            return "사용할 개인키를 선택하세요."
        }
        return nil
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        switch request {
        case .new(let folderID):
            draft.folderID = folderID
        case .edit(let sessionID):
            let descriptor = FetchDescriptor<SessionProfile>(predicate: #Predicate { $0.id == sessionID })
            if let session = try? context.fetch(descriptor).first {
                editingSession = session
                draft = SessionDraft(session)
            }
        }
    }

    private func save() {
        guard validationMessage == nil else { return }
        let session = editingSession ?? {
            let created = SessionProfile(name: "", kind: draft.kind, host: "")
            context.insert(created)
            return created
        }()
        draft.apply(to: session, folders: folders)

        // 비밀번호는 모델이 아니라 키체인에 저장한다.
        let vault = app.services.vault
        do {
            if draft.authMethod == .password && draft.savePassword {
                if !draft.newPassword.isEmpty {
                    try vault.storePassword(draft.newPassword, sessionID: session.id)
                    session.hasSavedPassword = true
                }
            } else if session.hasSavedPassword {
                vault.delete(account: KeychainVault.passwordAccount(session.id))
                session.hasSavedPassword = false
            }
        } catch {
            saveError = error.localizedDescription
            return
        }
        dismiss()
    }
}

/// 편집 중인 값. 저장 버튼을 누르기 전까지 원본 모델을 바꾸지 않는다.
struct SessionDraft {
    var name = ""
    var kind: ConnectionKind = .ssh
    var host = ""
    var port = ConnectionKind.ssh.defaultPort
    var username = ""
    var domain = ""
    var authMethod: AuthMethod = .password
    var folderID: UUID?
    var notes = ""
    var keyID: UUID?
    var terminalThemeID = ""
    var terminalType = ""
    var savePassword = true
    var hadSavedPassword = false
    /// 새로 저장할 비밀번호 (비어 있으면 기존 값 유지)
    var newPassword = ""

    init() {}

    init(_ session: SessionProfile) {
        name = session.name
        kind = session.kind
        host = session.host
        port = session.port
        username = session.username
        domain = session.domain
        authMethod = session.authMethod
        folderID = session.folder?.id
        notes = session.notes
        keyID = session.keyID
        terminalThemeID = session.terminalThemeID
        terminalType = session.terminalType
        savePassword = true
        hadSavedPassword = session.hasSavedPassword
    }

    func apply(to session: SessionProfile, folders: [SessionFolder]) {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        session.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        session.kind = kind
        session.host = trimmedHost
        session.port = port
        session.username = username.trimmingCharacters(in: .whitespaces)
        session.domain = kind == .rdp ? domain.trimmingCharacters(in: .whitespaces) : ""
        session.authMethod = authMethod
        session.folder = folders.first { $0.id == folderID }
        session.notes = notes
        session.keyID = authMethod == .privateKey ? keyID : nil
        session.terminalThemeID = kind == .ssh ? terminalThemeID : ""
        session.terminalType = kind == .ssh ? terminalType : ""
    }
}
