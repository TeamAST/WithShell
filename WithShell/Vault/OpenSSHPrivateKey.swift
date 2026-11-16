import CommonCrypto
import Crypto
import Foundation
import _CryptoExtras

/// OpenSSH 개인키 파일(`-----BEGIN OPENSSH PRIVATE KEY-----`) 해독기.
/// 형식: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
enum OpenSSHPrivateKey {
    static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let footer = "-----END OPENSSH PRIVATE KEY-----"

    /// 복호화된 개인키
    enum Decoded {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        case rsa(_RSA.Signing.PrivateKey, n: Data, e: Data)
    }

    /// 파일 구조 (공개 부분은 암호화되어 있지 않다)
    struct Container {
        let cipher: String
        let kdfName: String
        let kdfOptions: Data
        let publicKeyBlob: Data
        let privateSection: Data

        var isEncrypted: Bool { cipher != "none" }
    }

    static func container(from text: String) throws -> Container {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(header), trimmed.hasSuffix(footer) else { throw SSHKeyError.malformed }
        let base64 = trimmed.dropFirst(header.count).dropLast(footer.count).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)) else { throw SSHKeyError.malformed }

        var reader = SSHWireReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard reader.readBytes(magic.count) == magic,
              let cipher = reader.readString(),
              let kdfName = reader.readString(),
              let kdfOptions = reader.readBlob(),
              reader.readUInt32() == 1,
              let publicBlob = reader.readBlob(),
              let privateSection = reader.readBlob()
        else { throw SSHKeyError.malformed }

        return Container(
            cipher: cipher,
            kdfName: kdfName,
            kdfOptions: kdfOptions,
            publicKeyBlob: publicBlob,
            privateSection: privateSection
        )
    }

    static func decode(_ text: String, passphrase: String?) throws -> Decoded {
        let container = try container(from: text)
        let plain = try decrypt(container, passphrase: passphrase)

        var reader = SSHWireReader(plain)
        guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32() else { throw SSHKeyError.malformed }
        // 두 검사값이 다르면 복호화 결과가 틀린 것 = 패스프레이즈가 틀림
        guard check1 == check2 else {
            throw container.isEncrypted ? SSHKeyError.wrongPassphrase : SSHKeyError.malformed
        }
        guard let type = reader.readString() else { throw SSHKeyError.malformed }

        switch type {
        case "ssh-ed25519":
            guard reader.readBlob() != nil, // 공개키
                  let secret = reader.readBlob(), secret.count == 64
            else { throw SSHKeyError.malformed }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard reader.readString() != nil, // 곡선 이름
                  reader.readBlob() != nil,   // 공개점 Q
                  let d = reader.readBlob()
            else { throw SSHKeyError.malformed }
            switch type {
            case "ecdsa-sha2-nistp256": return .p256(try P256.Signing.PrivateKey(rawRepresentation: d.fixedWidth(32)))
            case "ecdsa-sha2-nistp384": return .p384(try P384.Signing.PrivateKey(rawRepresentation: d.fixedWidth(48)))
            default: return .p521(try P521.Signing.PrivateKey(rawRepresentation: d.fixedWidth(66)))
            }

        case "ssh-rsa":
            guard let n = reader.readBlob(),
                  let e = reader.readBlob(),
                  let d = reader.readBlob(),
                  reader.readBlob() != nil, // iqmp
                  let p = reader.readBlob(),
                  let q = reader.readBlob()
            else { throw SSHKeyError.malformed }
            do {
                let key = try _RSA.Signing.PrivateKey(n: n.unsigned, e: e.unsigned, d: d.unsigned, p: p.unsigned, q: q.unsigned)
                return .rsa(key, n: n.unsigned, e: e.unsigned)
            } catch {
                throw SSHKeyError.unsupportedAlgorithm("2048비트 미만 RSA")
            }

        default:
            throw SSHKeyError.unsupportedAlgorithm(type)
        }
    }

    // MARK: - 복호화

    private static func decrypt(_ container: Container, passphrase: String?) throws -> Data {
        guard container.isEncrypted else { return container.privateSection }
        guard let passphrase, !passphrase.isEmpty else { throw SSHKeyError.passphraseRequired }

        let (keyLength, mode): (Int, CCMode)
        switch container.cipher {
        case "aes128-ctr": (keyLength, mode) = (16, CCMode(kCCModeCTR))
        case "aes192-ctr": (keyLength, mode) = (24, CCMode(kCCModeCTR))
        case "aes256-ctr": (keyLength, mode) = (32, CCMode(kCCModeCTR))
        case "aes128-cbc": (keyLength, mode) = (16, CCMode(kCCModeCBC))
        case "aes192-cbc": (keyLength, mode) = (24, CCMode(kCCModeCBC))
        case "aes256-cbc": (keyLength, mode) = (32, CCMode(kCCModeCBC))
        default: throw SSHKeyError.unsupportedCipher(container.cipher)
        }
        guard container.kdfName == "bcrypt" else { throw SSHKeyError.unsupportedCipher(container.kdfName) }

        var options = SSHWireReader(container.kdfOptions)
        guard let salt = options.readBlob(), let rounds = options.readUInt32() else { throw SSHKeyError.malformed }

        let ivLength = kCCBlockSizeAES128
        var derived = [UInt8](repeating: 0, count: keyLength + ivLength)
        let password = Array(passphrase.utf8)
        let saltBytes = Array(salt)
        let kdfStatus = ws_bcrypt_pbkdf(password, password.count, saltBytes, saltBytes.count, &derived, derived.count, rounds)
        guard kdfStatus == 0 else { throw SSHKeyError.malformed }
        defer { derived.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) } }

        let key = Array(derived[..<keyLength])
        let iv = Array(derived[keyLength...])
        let input = Array(container.privateSection)
        var output = [UInt8](repeating: 0, count: input.count)

        var cryptor: CCCryptorRef?
        var status = CCCryptorCreateWithMode(
            CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            iv, key, key.count, nil, 0, 0,
            CCModeOptions(mode == CCMode(kCCModeCTR) ? kCCModeOptionCTR_BE : 0),
            &cryptor
        )
        guard status == kCCSuccess, let cryptor else { throw SSHKeyError.malformed }
        defer { CCCryptorRelease(cryptor) }

        var moved = 0
        status = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw SSHKeyError.malformed }
        return Data(output[..<moved])
    }
}

// MARK: - 바이너리 도우미

/// SSH 바이너리 형식(uint32 길이 + 바이트) 읽기 도우미
struct SSHWireReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readBlob() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }

    mutating func readString() -> String? {
        readBlob().flatMap { String(data: $0, encoding: .utf8) }
    }
}

extension Data {
    /// mpint 앞의 부호용 0x00 바이트를 제거한 값
    var unsigned: Data {
        let trimmed = drop { $0 == 0 }
        return trimmed.isEmpty ? Data([0]) : Data(trimmed)
    }

    /// 큰 정수를 고정 길이(빅엔디언)로 맞춘다.
    func fixedWidth(_ width: Int) throws -> Data {
        let value = unsigned
        guard value.count <= width else { throw SSHKeyError.malformed }
        return Data(repeating: 0, count: width - value.count) + value
    }

    /// SSH mpint 인코딩용: 최상위 비트가 1이면 0x00을 앞에 붙인다.
    var mpint: Data {
        let value = unsigned
        return (value.first ?? 0) & 0x80 != 0 ? Data([0]) + value : value
    }
}
