import AppKit
import SwiftData
import SwiftUI

@main
struct WithShellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: SessionProfile.self, SessionFolder.self, KnownHost.self, VaultKey.self
            )
        } catch {
            fatalError("데이터 저장소를 열 수 없습니다: \(error)")
        }
        _app = State(initialValue: AppModel(services: AppServices(container: container)))
    }

    var body: some Scene {
        // 탭 상태를 하나의 창에서만 관리하므로 단일 Window 장면을 사용한다.
        Window("WithShell", id: "main") {
            ContentView()
                .environment(app)
        }
        .modelContainer(container)
        .defaultSize(width: 1180, height: 760)
        .commands {
            WithShellCommands(app: app)
        }

        Window("키 관리자", id: KeyManagerView.windowID) {
            KeyManagerView()
                .environment(app)
        }
        .modelContainer(container)
        .defaultSize(width: 760, height: 520)
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
