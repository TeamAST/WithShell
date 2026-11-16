import SwiftUI

struct TabBarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let tabs = app.tabs

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        isSelected: tab.id == tabs.selectedTabID,
                        onSelect: { tabs.select(tab.id) },
                        onClose: { tabs.close(tab.id) }
                    )
                    .draggable(tab.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let draggedID = UUID(uuidString: raw) else { return false }
                        withAnimation(.snappy) { tabs.move(draggedID, before: tab.id) }
                        return true
                    }
                    .contextMenu {
                        Button("탭 닫기") { tabs.close(tab.id) }
                        Button("다른 탭 모두 닫기") { tabs.closeOthers(than: tab.id) }
                            .disabled(tabs.tabs.count < 2)
                        Divider()
                        Button("같은 세션을 새 탭으로 열기") { tabs.duplicate(tab.id) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .frame(height: 34)
        .background(.bar)
    }
}

private struct TabItemView: View {
    let tab: ConnectionTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.session.kind.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovering ? 1 : 0)
            .help("탭 닫기 (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 130, maxWidth: 220, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.primary.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help("\(tab.session.addressDescription) · \(tab.state.description)")
    }

    private var backgroundColor: Color {
        if isSelected { return Color(nsColor: .controlBackgroundColor) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var stateColor: Color {
        switch tab.state {
        case .idle, .disconnected: .gray
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}
