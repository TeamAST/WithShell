import AppKit
import SwiftUI

struct WithShellCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 세션…") { app.presentNewSession() }
                .keyboardShortcut("n")
        }

        CommandGroup(after: .newItem) {
            Button("탭 닫기") { app.tabs.closeSelected() }
                .keyboardShortcut("w")
                .disabled(app.tabs.selectedTab == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("오픈소스 라이선스") { openWindow(id: OpenSourceLicensesView.windowID) }
        }

        CommandGroup(after: .help) {
            Button("오픈소스 라이선스") { openWindow(id: OpenSourceLicensesView.windowID) }
            Button("RDP 진단 로그 보기") {
                let url = RDPSession.logFileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
        }

        CommandMenu("탭") {
            Button("다음 탭") { app.tabs.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(app.tabs.tabs.count < 2)
            Button("이전 탭") { app.tabs.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(app.tabs.tabs.count < 2)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("탭 \(number)") { app.tabs.select(index: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(app.tabs.tabs.count < number)
            }
        }
    }
}
