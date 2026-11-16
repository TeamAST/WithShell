import Foundation
import NIOCore
import NIOSSH

/// 개인키 후보를 순서대로 제시한다. 서버가 거부하면 다음 후보로 넘어간다.
/// (RSA 키는 rsa-sha2-512 → rsa-sha2-256 순으로 시도)
final class KeyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var candidates: [NIOSSHPrivateKey]
    private let lock = NSLock()

    init(username: String, keys: [NIOSSHPrivateKey]) {
        self.username = username
        candidates = keys
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        let next: NIOSSHPrivateKey? = lock.withLock {
            candidates.isEmpty ? nil : candidates.removeFirst()
        }
        guard let next else {
            nextChallengePromise.succeed(nil)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: next))
        ))
    }
}
