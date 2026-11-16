import Citadel
import Crypto
import Foundation
import NIOSSH

/// 개인키 파일에서 비밀번호(패스프레이즈) 없이 읽을 수 있는 정보.
/// OpenSSH 형식은 공개키 부분이 암호화되지 않으므로 지문을 바로 계산할 수 있다.
struct SSHKeyInfo: Equatable, Sendable {
    let algorithm: String
    /// 예: "Ed25519", "RSA 3072", "ECDSA P-256"
    let displayType: String
    let publicKeyBlob: Data
    let isEncrypted: Bool
    let cipher: String

    var openSSHPublicKey: String {
        "\(algorithm) \(publicKeyBlob.base64EncodedString())"
    }

    var fingerprint: String {
        let digest = Data(SHA256.hash(data: publicKeyBlob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static let supportedAlgorithms: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    var isSupported: Bool {
        Self.supportedAlgorithms.contains(algorithm)
    }

    /// 지원은 되지만 사용자에게 알려야 할 제약
    var compatibilityWarning: String? { nil }
}

enum SSHKeyError: LocalizedError, Equatable {
    case empty
    case publicKeyGiven
    case unsupportedFormat
    case malformed
    case unsupportedAlgorithm(String)
    case unsupportedCipher(String)
    case passphraseRequired
    case wrongPassphrase

    var errorDescription: String? {
        switch self {
        case .empty:
            "개인키를 입력하세요."
        case .publicKeyGiven:
            "공개키(.pub)입니다. 같은 이름의 .pub 없는 개인키 파일을 선택하세요."
        case .unsupportedFormat:
            "PuTTY(.ppk)·SSH2 형식 키는 지원하지 않습니다. OpenSSH 또는 PEM 형식으로 내보낸 뒤 가져오세요."
        case .malformed:
            "OpenSSH·PEM 개인키 형식이 아니거나 손상된 키입니다."
        case .unsupportedAlgorithm(let name):
            "\(name) 키는 지원하지 않습니다."
        case .unsupportedCipher(let name):
            "‘\(name)’ 방식으로 암호화된 키는 지원하지 않습니다. `ssh-keygen -p -Z aes256-ctr -f <키 파일>`로 다시 암호화하세요."
        case .passphraseRequired:
            "암호화된 키입니다. 패스프레이즈를 입력하세요."
        case .wrongPassphrase:
            "패스프레이즈가 올바르지 않습니다."
        }
    }
}

enum SSHKeyParser {
    /// 키 형식을 검사하고 공개키 정보를 꺼낸다 (패스프레이즈 불필요).
    static func inspect(_ text: String) throws -> SSHKeyInfo {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SSHKeyError.empty }
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") { throw SSHKeyError.publicKeyGiven }
        if !trimmed.hasPrefix(OpenSSHPrivateKey.header) {
            // PEM 키: 암호화되지 않았으면 변환해서 정보를 읽는다 (암호화된 PEM은 패스프레이즈가 필요)
            if case .pem = try PEMKeyConverter.format(of: trimmed) {
                return try inspect(PEMKeyConverter.convert(trimmed, passphrase: nil))
            }
        }

        let container = try OpenSSHPrivateKey.container(from: trimmed)
        var publicReader = SSHWireReader(container.publicKeyBlob)
        guard let algorithm = publicReader.readString() else { throw SSHKeyError.malformed }

        let displayType: String
        switch algorithm {
        case "ssh-ed25519":
            displayType = "Ed25519"
        case "ssh-rsa":
            _ = publicReader.readBlob() // e
            let modulus = publicReader.readBlob() ?? Data()
            displayType = "RSA \(modulus.unsigned.count * 8)"
        case "ecdsa-sha2-nistp256": displayType = "ECDSA P-256"
        case "ecdsa-sha2-nistp384": displayType = "ECDSA P-384"
        case "ecdsa-sha2-nistp521": displayType = "ECDSA P-521"
        default: displayType = algorithm
        }

        return SSHKeyInfo(
            algorithm: algorithm,
            displayType: displayType,
            publicKeyBlob: container.publicKeyBlob,
            isEncrypted: container.isEncrypted,
            cipher: container.cipher
        )
    }

    /// 키체인에 저장할 형태로 준비한다.
    /// OpenSSH 키는 그대로(패스프레이즈 함께), PEM 키는 OpenSSH 형식으로 변환해 저장한다.
    static func prepareForStorage(_ text: String, passphrase: String?, comment: String) throws
        -> (info: SSHKeyInfo, secret: StoredPrivateKey, source: KeySourceFormat)
    {
        let source = try PEMKeyConverter.format(of: text)
        switch source {
        case .openSSH(let encrypted):
            let info = try validate(text, passphrase: passphrase)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            return (info, StoredPrivateKey(privateKey: trimmed, passphrase: encrypted ? passphrase : nil), source)
        case .pem:
            let converted = try PEMKeyConverter.convert(text, passphrase: passphrase, comment: comment)
            let info = try validate(converted, passphrase: nil)
            return (info, StoredPrivateKey(privateKey: converted), source)
        }
    }

    /// 실제로 키를 복호화해 보아 사용 가능한지 확인한다.
    @discardableResult
    static func validate(_ text: String, passphrase: String?) throws -> SSHKeyInfo {
        if case .pem = try PEMKeyConverter.format(of: text) {
            return try validate(PEMKeyConverter.convert(text, passphrase: passphrase), passphrase: nil)
        }
        let info = try inspect(text)
        guard info.isSupported else { throw SSHKeyError.unsupportedAlgorithm(info.displayType) }
        _ = try OpenSSHPrivateKey.decode(text, passphrase: info.isEncrypted ? passphrase : nil)
        return info
    }

    /// 인증에 쓸 키 후보 (RSA는 SHA-512, SHA-256 서명을 차례로 시도)
    static func privateKeys(from text: String, passphrase: String?) throws -> [NIOSSHPrivateKey] {
        let info = try inspect(text)
        switch try OpenSSHPrivateKey.decode(text, passphrase: info.isEncrypted ? passphrase : nil) {
        case .ed25519(let key): return [NIOSSHPrivateKey(ed25519Key: key)]
        case .p256(let key): return [NIOSSHPrivateKey(p256Key: key)]
        case .p384(let key): return [NIOSSHPrivateKey(p384Key: key)]
        case .p521(let key): return [NIOSSHPrivateKey(p521Key: key)]
        case .rsa(let key, let n, let e):
            return [
                NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA512>(key: key, n: n, e: e)),
                NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA256>(key: key, n: n, e: e)),
            ]
        }
    }

    static func authenticationMethod(username: String, privateKey text: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let keys = try privateKeys(from: text, passphrase: passphrase)
        return .custom(KeyAuthenticationDelegate(username: username, keys: keys))
    }

    /// 새 Ed25519 키를 만든다. 반환값은 OpenSSH 개인키 텍스트(암호화 안 됨 — 키체인에 보관).
    static func generateEd25519(comment: String) -> String {
        Curve25519.Signing.PrivateKey().makeSSHRepresentation(comment: comment)
    }
}
