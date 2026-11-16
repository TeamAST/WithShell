import Foundation
import Observation

enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)

    var description: String {
        switch self {
        case .idle: "대기"
        case .connecting: "연결 중"
        case .connected: "연결됨"
        case .disconnected: "연결 끊김"
        case .failed(let message): "실패: \(message)"
        }
    }
}

@MainActor
@Observable
final class ConnectionTab: Identifiable {
    let id = UUID()
    let session: SessionSnapshot
    var title: String
    /// SSH 탭의 터미널 세션
    let ssh: SSHTerminalSession?
    /// RDP 탭의 원격 데스크톱 세션
    let rdp: RDPSession?

    init(session: SessionSnapshot, title: String, services: AppServices) {
        self.session = session
        self.title = title
        ssh = session.kind == .ssh ? SSHTerminalSession(snapshot: session, services: services) : nil
        rdp = session.kind == .rdp ? RDPSession(snapshot: session, services: services) : nil
    }

    var remote: (any RemoteSession)? {
        ssh ?? rdp
    }

    var state: ConnectionState {
        remote?.state ?? .idle
    }

    func shutdown() {
        remote?.disconnect()
    }
}

/// 열린 세션 탭 목록과 선택 상태를 관리한다.
/// 같은 세션을 여러 탭으로 동시에 열 수 있다.
@MainActor
@Observable
final class TabManager {
    private(set) var tabs: [ConnectionTab] = []
    var selectedTabID: ConnectionTab.ID?
    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var selectedTab: ConnectionTab? {
        tabs.first { $0.id == selectedTabID }
    }

    @discardableResult
    func open(_ session: SessionSnapshot) -> ConnectionTab {
        let sameSessionCount = tabs.filter { $0.session.sessionID == session.sessionID }.count
        let title = sameSessionCount == 0 ? session.name : "\(session.name) (\(sameSessionCount + 1))"
        let tab = ConnectionTab(session: session, title: title, services: services)
        if let index = selectedIndex {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        return tab
    }

    func duplicate(_ id: ConnectionTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        open(tab.session)
    }

    func select(_ id: ConnectionTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    func close(_ id: ConnectionTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index).shutdown()
        if selectedTabID == id {
            // 닫은 탭의 오른쪽 탭, 없으면 왼쪽 탭을 선택한다.
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelected() {
        if let selectedTabID { close(selectedTabID) }
    }

    func closeOthers(than id: ConnectionTab.ID) {
        for tab in tabs where tab.id != id { tab.shutdown() }
        tabs.removeAll { $0.id != id }
        selectedTabID = tabs.first?.id
    }

    func move(_ id: ConnectionTab.ID, before targetID: ConnectionTab.ID) {
        guard id != targetID,
              let from = tabs.firstIndex(where: { $0.id == id }),
              tabs.contains(where: { $0.id == targetID }) else { return }
        let tab = tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0.id == targetID }) ?? tabs.endIndex
        tabs.insert(tab, at: to)
    }

    private var selectedIndex: Int? {
        tabs.firstIndex { $0.id == selectedTabID }
    }

    private func step(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }
}

/// 연결 카드(비밀번호·Touch ID)가 다루는 원격 세션 공통 인터페이스
@MainActor
protocol RemoteSession: AnyObject {
    var snapshot: SessionSnapshot { get }
    var state: ConnectionState { get }
    var canConnect: Bool { get }
    func connect(password: String)
    func connectUsingVault()
    func disconnect()
}

extension SSHTerminalSession: RemoteSession {}
