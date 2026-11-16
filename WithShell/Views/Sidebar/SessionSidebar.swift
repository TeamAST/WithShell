import SwiftData
import SwiftUI

struct SessionSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    @Query(sort: \SessionFolder.sortOrder) private var folders: [SessionFolder]
    @Query(sort: \SessionProfile.name) private var sessions: [SessionProfile]

    @State private var selection = Set<UUID>()
    @State private var searchText = ""
    @State private var collapsedFolders = Set<UUID>()

    @State private var folderPrompt: FolderPrompt?
    @State private var folderNameInput = ""
    @State private var sessionsPendingDeletion: [SessionProfile] = []
    @State private var folderPendingDeletion: SessionFolder?

    var body: some View {
        List(selection: $selection) {
            if searchText.isEmpty {
                groupedRows
            } else {
                ForEach(searchResults) { session in
                    SessionRow(session: session, showsFolder: true).tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            sessionMenu(for: ids)
        } primaryAction: { ids in
            connect(ids)
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "세션 검색")
        .overlay { emptyState }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("새 세션…", systemImage: "plus") { app.presentNewSession() }
                    Button("새 폴더…", systemImage: "folder.badge.plus") { promptFolder(.create) }
                } label: {
                    Label("추가", systemImage: "plus")
                }
            }
        }
        .alert(folderPrompt?.title ?? "", isPresented: folderPromptBinding, presenting: folderPrompt) { prompt in
            TextField("폴더 이름", text: $folderNameInput)
            Button("취소", role: .cancel) {}
            Button(prompt.confirmTitle) { commitFolderPrompt(prompt) }
                .disabled(trimmedFolderName.isEmpty)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: sessionDeletionBinding
        ) {
            Button("삭제", role: .destructive) { deletePendingSessions() }
        } message: {
            Text("저장된 접속 정보가 삭제됩니다. 이미 열려 있는 탭은 그대로 유지됩니다.")
        }
        .confirmationDialog(
            "‘\(folderPendingDeletion?.name ?? "")’ 폴더를 삭제할까요?",
            isPresented: folderDeletionBinding
        ) {
            Button("폴더 삭제", role: .destructive) { deletePendingFolder() }
        } message: {
            Text("폴더 안의 세션은 삭제되지 않고 ‘폴더 없음’으로 이동합니다.")
        }
    }

    // MARK: - 목록

    @ViewBuilder
    private var groupedRows: some View {
        ForEach(folders) { folder in
            Section(isExpanded: expansionBinding(for: folder.id)) {
                ForEach(sessions.filter { $0.folder?.id == folder.id }) { session in
                    SessionRow(session: session).tag(session.id)
                }
            } header: {
                Text(folder.name)
                    .contextMenu {
                        Button("이 폴더에 새 세션…") { app.presentNewSession(folderID: folder.id) }
                        Button("이름 변경…") { promptFolder(.rename(folder)) }
                        Divider()
                        Button("폴더 삭제…", role: .destructive) { folderPendingDeletion = folder }
                    }
            }
        }

        let ungrouped = sessions.filter { $0.folder == nil }
        if !ungrouped.isEmpty {
            Section(folders.isEmpty ? "세션" : "폴더 없음") {
                ForEach(ungrouped) { session in
                    SessionRow(session: session).tag(session.id)
                }
            }
        }
    }

    private var searchResults: [SessionProfile] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return sessions.filter { session in
            [session.name, session.host, session.username, session.folder?.name ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if sessions.isEmpty && folders.isEmpty {
            ContentUnavailableView {
                Label("저장된 세션 없음", systemImage: "server.rack")
            } description: {
                Text("SSH 또는 RDP 접속 정보를 추가하세요.")
            } actions: {
                Button("새 세션…") { app.presentNewSession() }
            }
        } else if !searchText.isEmpty && searchResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedFolders.contains(id) },
            set: { expanded in
                if expanded { collapsedFolders.remove(id) } else { collapsedFolders.insert(id) }
            }
        )
    }

    // MARK: - 세션 동작

    @ViewBuilder
    private func sessionMenu(for ids: Set<UUID>) -> some View {
        let targets = profiles(for: ids)
        if !targets.isEmpty {
            Button(targets.count == 1 ? "연결" : "\(targets.count)개 세션 연결") { connect(ids) }
            if targets.count == 1, let session = targets.first {
                Button("편집…") { app.presentEditor(for: session) }
                Button("복제") { duplicate(session) }
            }
            if !folders.isEmpty {
                Menu("폴더로 이동") {
                    Button("폴더 없음") { move(targets, to: nil) }
                    Divider()
                    ForEach(folders) { folder in
                        Button(folder.name) { move(targets, to: folder) }
                    }
                }
            }
            Divider()
            Button("삭제…", role: .destructive) { sessionsPendingDeletion = targets }
        }
    }

    private func profiles(for ids: Set<UUID>) -> [SessionProfile] {
        sessions.filter { ids.contains($0.id) }
    }

    private func connect(_ ids: Set<UUID>) {
        for session in profiles(for: ids) {
            app.connect(session)
        }
    }

    private func duplicate(_ session: SessionProfile) {
        let copy = SessionProfile(
            name: "\(session.name) 복사본",
            kind: session.kind,
            host: session.host,
            port: session.port,
            username: session.username,
            authMethod: session.authMethod,
            keyID: session.keyID,
            notes: session.notes,
            folder: session.folder
        )
        copy.domain = session.domain
        copy.terminalThemeID = session.terminalThemeID
        copy.terminalType = session.terminalType
        context.insert(copy)
        selection = [copy.id]
    }

    private func move(_ targets: [SessionProfile], to folder: SessionFolder?) {
        for session in targets { session.folder = folder }
        if let folder { collapsedFolders.remove(folder.id) }
    }

    private var deletionTitle: String {
        if sessionsPendingDeletion.count == 1, let session = sessionsPendingDeletion.first {
            return "‘\(session.name)’ 세션을 삭제할까요?"
        }
        return "\(sessionsPendingDeletion.count)개 세션을 삭제할까요?"
    }

    private var sessionDeletionBinding: Binding<Bool> {
        Binding(
            get: { !sessionsPendingDeletion.isEmpty },
            set: { if !$0 { sessionsPendingDeletion = [] } }
        )
    }

    private func deletePendingSessions() {
        for session in sessionsPendingDeletion {
            selection.remove(session.id)
            app.services.deleteSession(session)
        }
        sessionsPendingDeletion = []
    }

    // MARK: - 폴더 동작

    private enum FolderPrompt: Identifiable {
        case create
        case rename(SessionFolder)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let folder): "rename-\(folder.id)"
            }
        }

        var title: String {
            switch self {
            case .create: "새 폴더"
            case .rename: "폴더 이름 변경"
            }
        }

        var confirmTitle: String {
            switch self {
            case .create: "만들기"
            case .rename: "변경"
            }
        }
    }

    private var trimmedFolderName: String {
        folderNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var folderPromptBinding: Binding<Bool> {
        Binding(
            get: { folderPrompt != nil },
            set: { if !$0 { folderPrompt = nil } }
        )
    }

    private var folderDeletionBinding: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )
    }

    private func promptFolder(_ prompt: FolderPrompt) {
        switch prompt {
        case .create: folderNameInput = ""
        case .rename(let folder): folderNameInput = folder.name
        }
        folderPrompt = prompt
    }

    private func commitFolderPrompt(_ prompt: FolderPrompt) {
        let name = trimmedFolderName
        guard !name.isEmpty else { return }
        switch prompt {
        case .create:
            let nextOrder = (folders.map(\.sortOrder).max() ?? -1) + 1
            context.insert(SessionFolder(name: name, sortOrder: nextOrder))
        case .rename(let folder):
            folder.name = name
        }
        folderPrompt = nil
    }

    private func deletePendingFolder() {
        if let folder = folderPendingDeletion {
            context.delete(folder)
        }
        folderPendingDeletion = nil
    }
}
