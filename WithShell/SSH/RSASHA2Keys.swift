import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

/// RFC 8332 RSA 서명 (rsa-sha2-512 / rsa-sha2-256).
///
/// swift-nio-ssh의 사용자 정의 키는 공개키 블롭의 형식 이름과 인증 알고리즘 이름을 같은 값으로 쓴다.
/// OpenSSH 서버는 `rsa-sha2-512` 같은 서명 알고리즘 이름도 RSA 키 형식으로 인식하므로
/// 접두사를 알고리즘 이름으로 두면 SHA-2 서명으로 인증할 수 있다.
protocol RSASHA2Algorithm {
    static var name: String { get }
    static func digest(_ data: some DataProtocol) -> any Digest
}

enum RSASHA512: RSASHA2Algorithm {
    static let name = "rsa-sha2-512"
    static func digest(_ data: some DataProtocol) -> any Digest { SHA512.hash(data: data) }
}

enum RSASHA256: RSASHA2Algorithm {
    static let name = "rsa-sha2-256"
    static func digest(_ data: some DataProtocol) -> any Digest { SHA256.hash(data: data) }
}

struct RSASHA2Signature<Algorithm: RSASHA2Algorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.name }
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHBlob(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let blob = buffer.readSSHBlob() else { throw SSHKeyError.malformed }
        return Self(rawRepresentation: blob)
    }
}

struct RSASHA2PublicKey<Algorithm: RSASHA2Algorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }
    /// 부호 없는 빅엔디언 정수
    let n: Data
    let e: Data

    var rawRepresentation: Data {
        var buffer = ByteBufferAllocator().buffer(capacity: n.count + e.count + 16)
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASHA2Signature<Algorithm>,
              let key = try? _RSA.Signing.PublicKey(n: n, e: e) else { return false }
        let rsaSignature = _RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation)
        switch Algorithm.self {
        case is RSASHA512.Type:
            return key.isValidSignature(rsaSignature, for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        default:
            return key.isValidSignature(rsaSignature, for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        }
    }

    /// 형식 이름 뒤의 공개키 본문: mpint e, mpint n
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHBlob(e.mpint) + buffer.writeSSHBlob(n.mpint)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let e = buffer.readSSHBlob(), let n = buffer.readSSHBlob() else { throw SSHKeyError.malformed }
        return Self(n: n.unsigned, e: e.unsigned)
    }
}

final class RSASHA2PrivateKey<Algorithm: RSASHA2Algorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.name }

    private let key: _RSA.Signing.PrivateKey
    private let rsaPublicKey: RSASHA2PublicKey<Algorithm>

    init(key: _RSA.Signing.PrivateKey, n: Data, e: Data) {
        self.key = key
        rsaPublicKey = RSASHA2PublicKey(n: n, e: e)
    }

    var publicKey: NIOSSHPublicKeyProtocol { rsaPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature: _RSA.Signing.RSASignature
        switch Algorithm.self {
        case is RSASHA512.Type:
            signature = try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        default:
            signature = try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
        }
        return RSASHA2Signature<Algorithm>(rawRepresentation: signature.rawRepresentation)
    }
}

extension ByteBuffer {
    @discardableResult
    mutating func writeSSHBlob(_ data: Data) -> Int {
        writeInteger(UInt32(data.count)) + writeBytes(data)
    }

    mutating func readSSHBlob() -> Data? {
        guard let length: UInt32 = readInteger(), let bytes = readBytes(length: Int(length)) else { return nil }
        return Data(bytes)
    }
}
