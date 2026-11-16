import Foundation
import Testing
@testable import WithShell

/// 키 해석·지문·패스프레이즈 검사 (ssh-keygen으로 만든 테스트 전용 키 사용)
struct SSHKeyTests {
    static func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: "Fixtures", withExtension: nil)?.appendingPathComponent(name))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func expectedFingerprint(_ name: String) throws -> String {
        let lines = try fixture("expected.txt").split(separator: "\n")
        let line = try #require(lines.first { $0.hasPrefix(name + " ") })
        return String(line.split(separator: " ")[1])
    }

    static let allFixtures = [
        "id_ed25519", "id_ed25519_enc", "id_ed25519_cbc", "id_rsa", "id_rsa_enc",
        "id_ecdsa", "id_ecdsa384", "id_ecdsa521_enc",
    ]

    static func passphrase(for name: String) -> String? {
        name.hasSuffix("_enc") || name.hasSuffix("_cbc") ? "withshell-fixture" : nil
    }

    @Test(arguments: allFixtures)
    func fingerprintMatchesSSHKeygen(name: String) throws {
        let info = try SSHKeyParser.inspect(Self.fixture(name))
        #expect(info.fingerprint == (try Self.expectedFingerprint(name)))
    }

    @Test func ed25519Inspection() throws {
        let info = try SSHKeyParser.validate(Self.fixture("id_ed25519"), passphrase: nil)
        #expect(info.displayType == "Ed25519")
        #expect(!info.isEncrypted)
    }

    @Test func encryptedKeyNeedsCorrectPassphrase() throws {
        let text = try Self.fixture("id_ed25519_enc")
        #expect(try SSHKeyParser.inspect(text).isEncrypted)
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHKeyParser.validate(text, passphrase: nil) }
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHKeyParser.validate(text, passphrase: "nope") }
        _ = try SSHKeyParser.validate(text, passphrase: "withshell-fixture")
    }

    @Test(arguments: allFixtures)
    func everyFixtureDecodes(name: String) throws {
        let text = try Self.fixture(name)
        let info = try SSHKeyParser.validate(text, passphrase: Self.passphrase(for: name))
        #expect(info.isEncrypted == (Self.passphrase(for: name) != nil))
        let keys = try SSHKeyParser.privateKeys(from: text, passphrase: Self.passphrase(for: name))
        #expect(keys.count == (info.algorithm == "ssh-rsa" ? 2 : 1))
    }

    @Test func displayTypes() throws {
        #expect(try SSHKeyParser.inspect(Self.fixture("id_rsa")).displayType == "RSA 3072")
        #expect(try SSHKeyParser.inspect(Self.fixture("id_rsa_enc")).displayType == "RSA 4096")
        #expect(try SSHKeyParser.inspect(Self.fixture("id_ecdsa")).displayType == "ECDSA P-256")
        #expect(try SSHKeyParser.inspect(Self.fixture("id_ecdsa384")).displayType == "ECDSA P-384")
        #expect(try SSHKeyParser.inspect(Self.fixture("id_ecdsa521_enc")).displayType == "ECDSA P-521")
    }

    @Test func wrongPassphraseForEveryEncryptedKey() throws {
        for name in Self.allFixtures where Self.passphrase(for: name) != nil {
            #expect(throws: SSHKeyError.wrongPassphrase, "\(name)") {
                try SSHKeyParser.validate(Self.fixture(name), passphrase: "nope")
            }
        }
    }

    /// 우리가 만든 RSA 서명이 공개키로 검증되는지 (SHA-512 / SHA-256)
    @Test func rsaSHA2SignaturesVerify() throws {
        guard case .rsa(let key, let n, let e) = try OpenSSHPrivateKey.decode(Self.fixture("id_rsa"), passphrase: nil) else {
            Issue.record("RSA 키로 해석되지 않음")
            return
        }
        let message = Data("withshell".utf8)
        let sha512 = RSASHA2PrivateKey<RSASHA512>(key: key, n: n, e: e)
        let sha256 = RSASHA2PrivateKey<RSASHA256>(key: key, n: n, e: e)
        #expect(sha512.publicKey.isValidSignature(try sha512.signature(for: message), for: message))
        #expect(sha256.publicKey.isValidSignature(try sha256.signature(for: message), for: message))
        #expect(!sha512.publicKey.isValidSignature(try sha512.signature(for: message), for: Data("other".utf8)))
    }

    @Test func unsupportedInputsAreExplained() throws {
        #expect(throws: SSHKeyError.publicKeyGiven) { try SSHKeyParser.inspect("ssh-ed25519 AAAAC3Nz test") }
        #expect(throws: SSHKeyError.empty) { try SSHKeyParser.inspect("  \n") }
        #expect(throws: SSHKeyError.unsupportedFormat) { try PEMKeyConverter.format(of: "PuTTY-User-Key-File-3: ssh-rsa") }
        #expect(throws: SSHKeyError.unsupportedAlgorithm("DSA")) {
            try PEMKeyConverter.format(of: "-----BEGIN DSA PRIVATE KEY-----\nAAAA\n-----END DSA PRIVATE KEY-----")
        }
        #expect(throws: SSHKeyError.malformed) {
            try SSHKeyParser.validate("-----BEGIN RSA PRIVATE KEY-----\nnot-base64\n-----END RSA PRIVATE KEY-----", passphrase: nil)
        }
    }

    // MARK: - PEM

    static let pemFixtures = [
        "id_rsa_pem", "pem_rsa_pkcs1_enc", "pem_rsa_pkcs8",
        "pem_ec256_sec1", "pem_ec384_sec1_enc", "pem_ec521_pkcs8_enc",
        "pem_ed25519_pkcs8", "pem_ed25519_pkcs8_enc",
    ]

    @Test(arguments: pemFixtures)
    func pemFingerprintMatchesReference(name: String) throws {
        let text = try Self.fixture(name)
        let info = try SSHKeyParser.validate(text, passphrase: Self.passphrase(for: name))
        #expect(info.fingerprint == (try Self.expectedFingerprint(name)))
    }

    @Test(arguments: pemFixtures)
    func pemConvertsToUsableOpenSSHKey(name: String) throws {
        let text = try Self.fixture(name)
        let prepared = try SSHKeyParser.prepareForStorage(text, passphrase: Self.passphrase(for: name), comment: "fixture")
        #expect(prepared.source.isEncrypted == (Self.passphrase(for: name) != nil))
        // 저장되는 키는 암호화되지 않은 OpenSSH 형식 + 패스프레이즈 없음
        #expect(prepared.secret.privateKey.hasPrefix(OpenSSHPrivateKey.header))
        #expect(prepared.secret.passphrase == nil)
        let reparsed = try SSHKeyParser.validate(prepared.secret.privateKey, passphrase: nil)
        #expect(reparsed.fingerprint == prepared.info.fingerprint)
        #expect(!reparsed.isEncrypted)
        _ = try SSHKeyParser.privateKeys(from: prepared.secret.privateKey, passphrase: nil)
    }

    @Test func pemFormatLabels() throws {
        #expect(try PEMKeyConverter.format(of: Self.fixture("id_rsa_pem")) == .pem(label: "PEM (PKCS#1 RSA)", encrypted: false))
        #expect(try PEMKeyConverter.format(of: Self.fixture("pem_rsa_pkcs1_enc")) == .pem(label: "PEM (PKCS#1 RSA)", encrypted: true))
        #expect(try PEMKeyConverter.format(of: Self.fixture("pem_ec256_sec1")) == .pem(label: "PEM (SEC1 EC)", encrypted: false))
        #expect(try PEMKeyConverter.format(of: Self.fixture("pem_ec384_sec1_enc")) == .pem(label: "PEM (SEC1 EC)", encrypted: true))
        #expect(try PEMKeyConverter.format(of: Self.fixture("pem_rsa_pkcs8")) == .pem(label: "PEM (PKCS#8)", encrypted: false))
        #expect(try PEMKeyConverter.format(of: Self.fixture("pem_ec521_pkcs8_enc")) == .pem(label: "PEM (PKCS#8)", encrypted: true))
        #expect(try PEMKeyConverter.format(of: Self.fixture("id_ed25519")) == .openSSH(encrypted: false))
    }

    @Test func encryptedPEMPassphraseHandling() throws {
        for name in Self.pemFixtures where Self.passphrase(for: name) != nil {
            let text = try Self.fixture(name)
            #expect(throws: SSHKeyError.passphraseRequired, "\(name)") { try SSHKeyParser.validate(text, passphrase: nil) }
            #expect(throws: SSHKeyError.wrongPassphrase, "\(name)") { try SSHKeyParser.validate(text, passphrase: "nope") }
            // 암호화된 PEM 은 패스프레이즈 없이는 정보를 읽을 수 없다
            #expect(throws: SSHKeyError.passphraseRequired, "\(name)") { try SSHKeyParser.inspect(text) }
        }
        // 암호화 안 된 PEM 은 바로 정보를 읽을 수 있다
        #expect(try SSHKeyParser.inspect(Self.fixture("pem_ec256_sec1")).displayType == "ECDSA P-256")
        #expect(try SSHKeyParser.inspect(Self.fixture("pem_rsa_pkcs8")).displayType == "RSA 3072")
        #expect(try SSHKeyParser.inspect(Self.fixture("pem_ed25519_pkcs8")).displayType == "Ed25519")
    }

    @Test func generatedKeyRoundTrips() throws {
        let text = SSHKeyParser.generateEd25519(comment: "unit-test")
        let info = try SSHKeyParser.validate(text, passphrase: nil)
        #expect(info.algorithm == "ssh-ed25519")
        #expect(info.openSSHPublicKey.hasPrefix("ssh-ed25519 AAAA"))
    }
}

final class BundleToken {}
