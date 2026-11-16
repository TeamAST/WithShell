import Foundation

enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ssh
    case rdp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ssh: "SSH"
        case .rdp: "RDP"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ssh: 22
        case .rdp: 3389
        }
    }

    var systemImage: String {
        switch self {
        case .ssh: "terminal"
        case .rdp: "display"
        }
    }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey
    case agent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: "비밀번호"
        case .privateKey: "개인키 (키 관리자)"
        case .agent: "SSH Agent"
        }
    }

    static func available(for kind: ConnectionKind) -> [AuthMethod] {
        switch kind {
        case .ssh: [.password, .privateKey, .agent]
        case .rdp: [.password]
        }
    }
}
