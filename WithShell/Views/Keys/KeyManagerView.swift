import AppKit
import SwiftData
import SwiftUI

/// SSH 개인키 목록. 개인키는 키체인에만 있고, 여기서는 공개 정보만 보여 준다.
struct KeyManagerView: View {
    static let windowID = "key-manager"

    @Environment(AppModel.self) private var app
    @Query(sort: \VaultKey.name) private var keys: [VaultKey]
    @Query private var sessions: [SessionProfile]

    @State private var selection: VaultKey.ID?
    @State private var importDraft: KeyImportDraft?
    @State private var showsGenerator = false
    @State private var keyPendingDeletion: VaultKey?
    @State private var copiedKeyID: UUID?

    private var selectedKey: VaultKey? {
        keys.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(keys, selection: $selection) {
                TableColumn("이름", value: \.name)
                TableColumn("종류", value: \.displayType)
                    .width(min: 70, ideal: 90, max: 120)
                TableColumn("지문") { key in
                    Text(key.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .width(min: 180, ideal: 300)
                TableColumn("사용 세션") { key in
                    Text("\(usage(of: key).count)")
                }
                .width(60)
            }
            .contextMenu(forSelectionType: VaultKey.ID.self) { ids in
                if let id = ids.first, let key = keys.first(where: { $0.id == id }) {
                    Button("공개키 복사") { copyPublicKey(key) }
                    Divider()
                    Button("삭제…", role: .destructive) { keyPendingDeletion = key }
                }
            }
            .overlay {
                if keys.isEmpty {
                    ContentUnavailableView {
                        Label("등록된 키 없음", systemImage: "key")
                    } description: {
                        Text("기존 개인키(Ed25519·ECDSA·RSA)를 가져오거나 새 Ed25519 키를 만드세요.\n개인키는 macOS 키체인에 저장되고, 앱 실행 후 처음 사용할 때 한 번만 Touch ID로 확인합니다.")
                    } actions: {
                        HStack {
                            Button("파일에서 가져오기…", action: importFromFile)
                            Button("새 키 만들기…") { showsGenerator = true }
                        }
                    }
                }
            }

            if let key = selectedKey {
                Divider()
                KeyDetailView(
                    key: key,
                    usedBy: usage(of: key),
                    copied: copiedKeyID == key.id,
                    onCopy: { copyPublicKey(key) }
                )
            }
        }
        .navigationTitle("키 관리자")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("파일에서 가져오기…", systemImage: "doc", action: importFromFile)
                    Button("붙여 넣어 가져오기…", systemImage: "doc.on.clipboard") {
                        importDraft = KeyImportDraft()
                    }
                    Divider()
                    Button("새 Ed25519 키 만들기…", systemImage: "wand.and.stars") { showsGenerator = true }
                } label: {
                    Label("키 추가", systemImage: "plus")
                }

                Button("키체인 잠그기", systemImage: "lock") { app.services.vault.lock() }
                    .help("본인 확인 상태를 해제합니다. 다음에 저장된 비밀번호·키를 쓸 때 다시 Touch ID로 확인합니다.")
            }
        }
        .sheet(item: $importDraft) { draft in
            KeyImportView(draft: draft)
        }
        .sheet(isPresented: $showsGenerator) {
            KeyGeneratorView { newID in selection = newID }
        }
        .confirmationDialog(
            "‘\(keyPendingDeletion?.name ?? "")’ 키를 삭제할까요?",
            isPresented: Binding(get: { keyPendingDeletion != nil }, set: { if !$0 { keyPendingDeletion = nil } })
        ) {
            Button("삭제", role: .destructive) {
                if let key = keyPendingDeletion { app.services.deleteKey(key) }
                keyPendingDeletion = nil
            }
        } message: {
            let count = keyPendingDeletion.map { usage(of: $0).count } ?? 0
            Text(count > 0
                 ? "키체인에서 개인키가 영구히 삭제되고, 이 키를 쓰던 세션 \(count)개는 키 선택이 해제됩니다. 되돌릴 수 없습니다."
                 : "키체인에서 개인키가 영구히 삭제됩니다. 되돌릴 수 없습니다.")
        }
    }

    private func usage(of key: VaultKey) -> [SessionProfile] {
        sessions.filter { $0.keyID == key.id && $0.authMethod == .privateKey }
    }

    private func copyPublicKey(_ key: VaultKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.authorizedKeysLine, forType: .string)
        copiedKeyID = key.id
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "가져올 개인키 선택"
        panel.message = "OpenSSH 또는 PEM 개인키 파일을 선택하세요 (예: ~/.ssh/id_ed25519, server.pem). 숨김 폴더는 ⌘⇧. 으로 표시됩니다."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".ssh")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        importDraft = KeyImportDraft(name: url.lastPathComponent, privateKey: text)
    }
}

private struct KeyDetailView: View {
    let key: VaultKey
    let usedBy: [SessionProfile]
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("공개키").font(.headline)
                Spacer()
                Button(copied ? "복사됨" : "공개키 복사", systemImage: copied ? "checkmark" : "doc.on.doc", action: onCopy)
            }
            Text(key.authorizedKeysLine)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text("서버의 ~/.ssh/authorized_keys 에 위 한 줄을 추가하면 이 키로 접속할 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !usedBy.isEmpty {
                Text("사용 중인 세션: " + usedBy.map(\.name).sorted().joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
