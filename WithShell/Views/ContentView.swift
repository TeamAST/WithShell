import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            TabWorkspaceView()
        }
        .sheet(item: $app.editorRequest) { request in
            SessionEditorView(request: request)
        }
    }
}
