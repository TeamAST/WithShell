import SwiftData
import SwiftUI

struct KeyImportDraft: Identifiable {
    let id = UUID()
    var name = ""
    var privateKey = ""
}

/// 개인키 가져오기. 패스프레이즈로 실제 복호화가 되는지 확인한 뒤 키체인에 저장한다.
struct KeyImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existingKeys: [VaultKey]

    @State private var name: String
    @State private var privateKey: String
    @State private var passphrase = ""
    @State private var errorMessage: String?

    init(draft: KeyImportDraft) {
        _name = State(initialValue: draft.name)
        _privateKey = State(initialValue: draft.privateKey)
    }

    private var source: KeySourceFormat? {
        try? PEMKeyConverter.format(of: privateKey)
    }

    private var needsPassphrase: Bool { source?.isEncrypted == true }

    private var isEncryptedPEM: Bool {
        if case .pem(_, true) = source { return true }
        return false
    }

    /// 키 정보. 암호화된 PEM은 패스프레이즈를 넣어야 공개키를 알 수 있다.
    private var inspection: Result<SSHKeyInfo, Error> {
        if isEncryptedPEM {
            guard !passphrase.isEmpty else { return .failure(SSHKeyError.passphraseRequired) }
            return Result { try SSHKeyParser.validate(privateKey, passphrase: passphrase) }
        }
        return Result { try SSHKeyParser.inspect(privateKey) }
    }

    private var info: SSHKeyInfo? { try? inspection.get() }

    private var duplicate: VaultKey? {
        guard let info else { return nil }
        return existingKeys.first { $0.fingerprint == info.fingerprint }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("이름", text: $name, prompt: Text("예: 회사 서버 키"))

                Section {
                    TextEditor(text: $privateKey)
                        .font(.caption.monospaced())
                        .frame(height: 150)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if privateKey.isEmpty {
                                Text("-----BEGIN OPENSSH PRIVATE KEY-----\n또는 -----BEGIN RSA / EC / PRIVATE KEY----- …")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 1)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    inspectionRow
                } header: {
                    Text("개인키")
                } footer: {
                    Text("OpenSSH 형식과 PEM 형식(PKCS#1·SEC1·PKCS#8, 암호화된 키 포함)의 Ed25519·ECDSA·RSA 키를 가져올 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if needsPassphrase {
                    Section {
                        PasswordField(title: "패스프레이즈", text: $passphrase)
                    } footer: {
                        Text(isEncryptedPEM
                             ? "PEM 키는 OpenSSH 형식으로 변환해 키체인에 저장하므로, 패스프레이즈는 가져올 때만 사용합니다. 접속할 때는 Touch ID만 확인합니다."
                             : "패스프레이즈도 개인키와 함께 키체인에 보관되어, 접속할 때는 Touch ID만 확인합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("가져오기", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(info?.isSupported != true || duplicate != nil)
            }
            .padding()
        }
        .frame(width: 540, height: 540)
        .onChange(of: privateKey) { errorMessage = nil }
        .onChange(of: passphrase) { errorMessage = nil }
    }

    @ViewBuilder
    private var inspectionRow: some View {
        switch inspection {
        case .success(let info):
            VStack(alignment: .leading, spacing: 4) {
                if let source {
                    LabeledContent("형식", value: source.label + (source.isEncrypted ? " · 암호화됨" : ""))
                }
                LabeledContent("종류", value: info.displayType)
                LabeledContent("지문") {
                    Text(info.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                if !info.isSupported {
                    Label(SSHKeyError.unsupportedAlgorithm(info.displayType).errorDescription ?? "", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                } else if let duplicate {
                    Label("이미 ‘\(duplicate.name)’ 이름으로 등록된 키입니다.", systemImage: "info.circle")
                        .foregroundStyle(.orange)
                } else if let warning = info.compatibilityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
        case .failure(SSHKeyError.passphraseRequired) where isEncryptedPEM:
            Label("암호화된 \(source?.label ?? "PEM") 키입니다. 패스프레이즈를 입력하면 종류와 지문이 표시됩니다.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failure(let error):
            if !privateKey.isEmpty {
                Label(error.localizedDescription, systemImage: "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func save() {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let prepared = try SSHKeyParser.prepareForStorage(
                privateKey,
                passphrase: needsPassphrase ? passphrase : nil,
                comment: trimmedName
            )
            let key = VaultKey(name: trimmedName.isEmpty ? prepared.info.displayType : trimmedName, info: prepared.info)
            key.wasEncrypted = prepared.source.isEncrypted
            try app.services.vault.storePrivateKey(prepared.secret, id: key.id)
            context.insert(key)
            try? context.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 새 Ed25519 키를 만들어 바로 키체인에 저장한다.
struct KeyGeneratorView: View {
    let onCreated: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 Ed25519 키").font(.headline)
            TextField("이름", text: $name, prompt: Text("예: macbook-withshell"))
                .textFieldStyle(.roundedBorder)
            Text("개인키는 이 Mac의 키체인에만 저장되고 밖으로 내보내지 않습니다. 만든 뒤 공개키를 복사해 서버의 authorized_keys에 추가하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("만들기", action: generate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func generate() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let privateKey = SSHKeyParser.generateEd25519(comment: trimmed)
            let info = try SSHKeyParser.validate(privateKey, passphrase: nil)
            let key = VaultKey(name: trimmed, info: info)
            try app.services.vault.storePrivateKey(StoredPrivateKey(privateKey: privateKey), id: key.id)
            context.insert(key)
            try? context.save()
            onCreated(key.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
