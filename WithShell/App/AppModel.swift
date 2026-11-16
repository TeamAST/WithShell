import Foundation
import Observation

/// 창 전체에서 공유하는 화면 상태 (열린 탭, 편집기 표시 여부).
@MainActor
@Observable
final class AppModel {
    let services: AppServices
    let tabs: TabManager
    var editorRequest: SessionEditorRequest?

    init(services: AppServices) {
        self.services = services
        let tabs = TabManager(services: services)
        self.tabs = tabs
        // 설정에서 색상·글꼴을 바꾸면 열린 터미널에 바로 반영
        services.terminalAppearance.addListener { [weak tabs] in
            tabs?.tabs.forEach { $0.ssh?.applyAppearance() }
        }
    }

    func presentNewSession(folderID: UUID? = nil) {
        editorRequest = .new(folderID: folderID)
    }

    func presentEditor(for session: SessionProfile) {
        editorRequest = .edit(sessionID: session.id)
    }

    func connect(_ session: SessionProfile) {
        session.lastConnectedAt = .now
        let keyName = services.vaultKey(id: session.keyID)?.name
        tabs.open(SessionSnapshot(session, keyName: keyName))
    }
}

enum SessionEditorRequest: Identifiable, Hashable {
    case new(folderID: UUID?)
    case edit(sessionID: UUID)

    var id: String {
        switch self {
        case .new(let folderID): "new-\(folderID?.uuidString ?? "none")"
        case .edit(let sessionID): "edit-\(sessionID.uuidString)"
        }
    }
}
