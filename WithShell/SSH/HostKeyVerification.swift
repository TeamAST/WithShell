import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import SwiftData

/// 서버가 보낸 호스트 키의 표시용 정보.
struct HostKeyInfo: Sendable, Equatable {
    let algorithm: String
    let openSSHKey: String
    /// `SHA256:...` (ssh-keygen -lf 와 같은 형식)
    let fingerprint: String

    init(_ key: NIOSSHPublicKey) {
        let openSSH = String(openSSHPublicKey: key)
        let parts = openSSH.split(separator: " ")
        algorithm = parts.first.map(String.init) ?? "unknown"
        openSSHKey = parts.prefix(2).joined(separator: " ")

        if parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) {
            let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            fingerprint = "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        } else {
            fingerprint = "알 수 없음"
        }
    }
}

enum HostKeyCheckResult {
    case trusted
    case unknown
    case changed(previous: KnownHost)
}

/// 알려진 호스트 키 저장소.
@MainActor
final class KnownHostStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func check(host: String, port: Int, info: HostKeyInfo) -> HostKeyCheckResult {
        guard let saved = find(host: host, port: port) else { return .unknown }
        return saved.publicKey == info.openSSHKey ? .trusted : .changed(previous: saved)
    }

    func trust(host: String, port: Int, info: HostKeyInfo) {
        if let saved = find(host: host, port: port) {
            context.delete(saved)
        }
        context.insert(KnownHost(endpoint: KnownHost.endpoint(host: host, port: port), info: info))
        try? context.save()
    }

    private func find(host: String, port: Int) -> KnownHost? {
        let endpoint = KnownHost.endpoint(host: host, port: port)
        let descriptor = FetchDescriptor<KnownHost>(predicate: #Predicate { $0.endpoint == endpoint })
        return try? context.fetch(descriptor).first
    }
}

struct HostKeyRejectedError: Error {}

/// swift-nio-ssh의 호스트 키 검증 요청을 async 판단 함수로 연결한다.
final class HostKeyValidationBridge: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let decide: @Sendable (HostKeyInfo) async -> Bool

    init(decide: @escaping @Sendable (HostKeyInfo) async -> Bool) {
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(hostKey)
        let decide = decide
        Task {
            if await decide(info) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejectedError())
            }
        }
    }
}
