import Foundation

/// 붙여 넣거나 파일에서 읽은 개인키의 형식
enum KeySourceFormat: Equatable {
    case openSSH(encrypted: Bool)
    /// label: 예) "PEM (PKCS#1 RSA)"
    case pem(label: String, encrypted: Bool)

    var isEncrypted: Bool {
        switch self {
        case .openSSH(let encrypted), .pem(_, let encrypted): encrypted
        }
    }

    var label: String {
        switch self {
        case .openSSH: "OpenSSH"
        case .pem(let label, _): label
        }
    }
}

/// PEM 개인키를 OpenSSH 형식(암호화 안 됨)으로 바꾼다.
/// 변환된 키는 키체인에만 저장되므로 원본의 패스프레이즈는 다시 필요하지 않다.
enum PEMKeyConverter {
    static func format(of text: String) throws -> KeySourceFormat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw SSHKeyError.empty }
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") { throw SSHKeyError.publicKeyGiven }
        if trimmed.hasPrefix(OpenSSHPrivateKey.header) {
            return .openSSH(encrypted: try OpenSSHPrivateKey.container(from: trimmed).isEncrypted)
        }

        let legacyEncrypted = trimmed.contains("Proc-Type: 4,ENCRYPTED")
        switch true {
        case trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"):
            return .pem(label: "PEM (PKCS#1 RSA)", encrypted: legacyEncrypted)
        case trimmed.hasPrefix("-----BEGIN EC PRIVATE KEY-----"):
            return .pem(label: "PEM (SEC1 EC)", encrypted: legacyEncrypted)
        case trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----"):
            return .pem(label: "PEM (PKCS#8)", encrypted: false)
        case trimmed.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----"):
            return .pem(label: "PEM (PKCS#8)", encrypted: true)
        case trimmed.hasPrefix("-----BEGIN DSA PRIVATE KEY-----"):
            throw SSHKeyError.unsupportedAlgorithm("DSA")
        case trimmed.hasPrefix("-----BEGIN SSH2 ENCRYPTED PRIVATE KEY-----"),
             trimmed.hasPrefix("PuTTY-User-Key-File"):
            throw SSHKeyError.unsupportedFormat
        default:
            throw SSHKeyError.malformed
        }
    }

    /// PEM → OpenSSH 개인키 텍스트
    static func convert(_ text: String, passphrase: String?, comment: String = "") throws -> String {
        guard case .pem(_, let encrypted) = try format(of: text) else { return text }
        if encrypted && (passphrase ?? "").isEmpty { throw SSHKeyError.passphraseRequired }

        var key = ws_pem_key()
        defer { ws_pem_key_clear(&key) }

        let status = text.withCString { pem in
            (passphrase ?? "").withCString { pass in
                ws_pem_decode(pem, encrypted ? pass : nil, &key)
            }
        }
        switch status {
        case WS_PEM_OK: break
        case WS_PEM_DECRYPT_FAILED: throw encrypted ? SSHKeyError.wrongPassphrase : SSHKeyError.malformed
        case WS_PEM_UNSUPPORTED: throw SSHKeyError.unsupportedAlgorithm(errorText(&key))
        default: throw SSHKeyError.malformed
        }

        let publicBlob: Data
        var privatePart = SSHWireWriter()
        switch key.type {
        case WS_PEM_KEY_RSA:
            let (n, e, d, iqmp, p, q) = (part(&key, 0), part(&key, 1), part(&key, 2), part(&key, 3), part(&key, 4), part(&key, 5))
            var pub = SSHWireWriter()
            pub.string("ssh-rsa"); pub.mpint(e); pub.mpint(n)
            publicBlob = pub.data
            privatePart.string("ssh-rsa")
            for value in [n, e, d, iqmp, p, q] { privatePart.mpint(value) }

        case WS_PEM_KEY_EC:
            let curve = withUnsafeBytes(of: key.curve) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let point = part(&key, 0), scalar = part(&key, 1)
            let type = "ecdsa-sha2-\(curve)"
            var pub = SSHWireWriter()
            pub.string(type); pub.string(curve); pub.blob(point)
            publicBlob = pub.data
            privatePart.string(type); privatePart.string(curve); privatePart.blob(point); privatePart.mpint(scalar)

        case WS_PEM_KEY_ED25519:
            let publicKey = part(&key, 0), seed = part(&key, 1)
            var pub = SSHWireWriter()
            pub.string("ssh-ed25519"); pub.blob(publicKey)
            publicBlob = pub.data
            privatePart.string("ssh-ed25519"); privatePart.blob(publicKey); privatePart.blob(seed + publicKey)

        default:
            throw SSHKeyError.malformed
        }
        privatePart.string(comment)

        return OpenSSHPrivateKey.encodeUnencrypted(publicBlob: publicBlob, keyData: privatePart.data)
    }

    private static func part(_ key: inout ws_pem_key, _ index: Int) -> Data {
        withUnsafeBytes(of: &key.parts) { raw in
            let stride = MemoryLayout<ws_pem_component>.stride
            let base = raw.baseAddress! + index * stride
            let component = base.assumingMemoryBound(to: ws_pem_component.self).pointee
            return withUnsafeBytes(of: component.bytes) { Data($0.prefix(component.length)) }
        }
    }

    private static func errorText(_ key: inout ws_pem_key) -> String {
        withUnsafeBytes(of: key.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension OpenSSHPrivateKey {
    /// 암호화하지 않은 OpenSSH 개인키 파일을 만든다 (PROTOCOL.key).
    static func encodeUnencrypted(publicBlob: Data, keyData: Data) -> String {
        var section = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        section.uint32(check)
        section.uint32(check)
        section.raw(keyData)
        // 블록 크기(암호화 없음: 8) 배수가 되도록 1, 2, 3 … 으로 채운다
        var pad: UInt8 = 1
        while section.data.count % 8 != 0 {
            section.raw(Data([pad]))
            pad += 1
        }

        var file = SSHWireWriter()
        file.raw(Data("openssh-key-v1\0".utf8))
        file.string("none")
        file.string("none")
        file.blob(Data())
        file.uint32(1)
        file.blob(publicBlob)
        file.blob(section.data)

        let base64 = file.data.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(70, base64.count - offset))
            return String(base64[start..<end])
        }
        return ([header] + lines + [footer]).joined(separator: "\n") + "\n"
    }
}

/// SSH 바이너리 형식 쓰기 도우미
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func raw(_ bytes: Data) { data.append(bytes) }

    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func blob(_ bytes: Data) {
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func string(_ value: String) { blob(Data(value.utf8)) }

    mutating func mpint(_ value: Data) { blob(value.mpint) }
}
