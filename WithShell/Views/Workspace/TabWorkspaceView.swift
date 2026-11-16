import SwiftUI

struct TabWorkspaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let tabs = app.tabs

        Group {
            if tabs.tabs.isEmpty {
                ContentUnavailableView {
                    Label("열린 세션 없음", systemImage: "rectangle.stack")
                } description: {
                    Text("사이드바에서 세션을 더블클릭하면 새 탭으로 열립니다.")
                } actions: {
                    Button("새 세션…") { app.presentNewSession() }
                }
            } else {
                VStack(spacing: 0) {
                    TabBarView()
                    Divider()
                    // 탭을 전환해도 터미널·원격 화면 상태가 유지되도록 모든 탭 화면을 살려 둔다.
                    ZStack {
                        ForEach(tabs.tabs) { tab in
                            let isSelected = tab.id == tabs.selectedTabID
                            SessionTabContentView(tab: tab)
                                .opacity(isSelected ? 1 : 0)
                                .allowsHitTesting(isSelected)
                                .accessibilityHidden(!isSelected)
                        }
                    }
                }
            }
        }
        .navigationTitle(tabs.selectedTab?.title ?? "WithShell")
        .navigationSubtitle(tabs.selectedTab?.session.addressDescription ?? "")
        .toolbar {
            if let tab = tabs.selectedTab, tab.state == .connected {
                ToolbarItemGroup {
                    if let rdp = tab.rdp {
                        Button("Ctrl+Alt+Del", systemImage: "keyboard") { rdp.sendCtrlAltDelete() }
                            .help("원격 컴퓨터에 Ctrl+Alt+Del 보내기")
                    }
                    Button("연결 끊기", systemImage: "bolt.horizontal.circle") { tab.remote?.disconnect() }
                        .help("이 탭의 연결을 끊습니다 (탭은 남아 있어 다시 연결할 수 있음)")
                }
            }
        }
    }
}
