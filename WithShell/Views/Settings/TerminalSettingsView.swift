import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TerminalSettingsView()
                .tabItem { Label("터미널", systemImage: "terminal") }
        }
        .frame(width: 820, height: 600)
    }
}

/// 터미널 기본 설정과 색상 프리셋 관리
struct TerminalSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedThemeID: String?

    private var store: TerminalAppearanceStore { app.services.terminalAppearance }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            Form {
                Picker("기본 색상 프리셋", selection: $store.defaultThemeID) {
                    ForEach(store.allThemes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Picker("기본 터미널 종류 (TERM)", selection: $store.defaultTerminalType) {
                    ForEach(TerminalType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                LabeledContent("글꼴 크기") {
                    Stepper(value: $store.fontSize, in: 9...28, step: 1) {
                        Text("\(Int(store.fontSize))pt").monospacedDigit()
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 170)

            Divider()

            HStack(spacing: 0) {
                themeList
                    .frame(width: 240)
                Divider()
                themeDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selectedThemeID = selectedThemeID ?? store.defaultThemeID }
    }

    // MARK: - 목록

    private var themeList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedThemeID) {
                Section("기본 제공") {
                    ForEach(TerminalTheme.builtIns) { row($0) }
                }
                if !store.customThemes.isEmpty {
                    Section("사용자 정의") {
                        ForEach(store.customThemes) { row($0) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button {
                    if let theme = selectedTheme {
                        selectedThemeID = store.duplicate(theme).id
                    }
                } label: { Image(systemName: "plus") }
                .help("선택한 프리셋을 복제해 사용자 정의 프리셋 만들기")
                .disabled(selectedTheme == nil)

                Button {
                    if let theme = selectedTheme, !theme.isBuiltIn {
                        store.delete(theme)
                        selectedThemeID = store.defaultThemeID
                    }
                } label: { Image(systemName: "minus") }
                .help("사용자 정의 프리셋 삭제")
                .disabled(selectedTheme?.isBuiltIn != false)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func row(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: HexColor.nsColor(theme.background)))
                .overlay(
                    Text("A")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: HexColor.nsColor(theme.foreground)))
                )
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2)))
                .frame(width: 22, height: 16)
            Text(theme.name)
                .lineLimit(1)
            if theme.id == store.defaultThemeID {
                Spacer()
                Text("기본").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(theme.id)
    }

    private var selectedTheme: TerminalTheme? {
        selectedThemeID.flatMap { store.theme(id: $0) }
    }

    // MARK: - 상세

    @ViewBuilder
    private var themeDetail: some View {
        if let theme = selectedTheme {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TerminalThemePreview(theme: theme)

                    HStack {
                        if theme.id != store.defaultThemeID {
                            Button("기본으로 사용") { store.defaultThemeID = theme.id }
                        }
                        Spacer()
                        if theme.isBuiltIn {
                            Button("복제해서 편집") { selectedThemeID = store.duplicate(theme).id }
                        }
                    }

                    if theme.isBuiltIn {
                        Text("기본 제공 프리셋은 수정할 수 없습니다. ‘복제해서 편집’으로 사용자 정의 프리셋을 만들어 색을 바꾸세요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        TerminalThemeEditor(theme: theme) { store.update($0) }
                            .id(theme.id)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("프리셋을 선택하세요", systemImage: "paintpalette")
        }
    }
}

// MARK: - 미리보기

struct TerminalThemePreview: View {
    let theme: TerminalTheme

    private func color(_ index: Int) -> Color {
        let hex = theme.monochrome ? theme.foreground : theme.ansi[index]
        return Color(nsColor: HexColor.nsColor(hex))
    }

    private var foreground: Color { Color(nsColor: HexColor.nsColor(theme.foreground)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text("root@server").foregroundColor(color(10)) + Text(":").foregroundColor(foreground)
                + Text("~").foregroundColor(color(12)) + Text("# ls -l --color").foregroundColor(foreground))
            (Text("drwxr-xr-x  ").foregroundColor(foreground) + Text("projects").foregroundColor(color(12)).bold())
            (Text("-rwxr-xr-x  ").foregroundColor(foreground) + Text("deploy.sh").foregroundColor(color(10)).bold())
            (Text("lrwxrwxrwx  ").foregroundColor(foreground) + Text("current -> releases/42").foregroundColor(color(14)))
            (Text("-rw-r--r--  ").foregroundColor(foreground) + Text("backup.tar.gz").foregroundColor(color(9)))
            Text("error: 연결이 거부되었습니다").foregroundColor(color(1))
            Text("warning: 디스크 사용량 91%").foregroundColor(color(3))
            HStack(spacing: 0) {
                Text("root@server:~# ").foregroundColor(foreground)
                Rectangle()
                    .fill(Color(nsColor: HexColor.nsColor(theme.cursor)))
                    .frame(width: 8, height: 15)
            }
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { index in
                    Rectangle()
                        .fill(Color(nsColor: HexColor.nsColor(theme.ansi[index])))
                        .frame(height: 12)
                        .help(TerminalTheme.ansiNames[index])
                }
            }
            .padding(.top, 6)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: HexColor.nsColor(theme.background)), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
    }
}

// MARK: - 편집기

struct TerminalThemeEditor: View {
    @State private var draft: TerminalTheme
    let onChange: (TerminalTheme) -> Void

    init(theme: TerminalTheme, onChange: @escaping (TerminalTheme) -> Void) {
        _draft = State(initialValue: theme)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("이름", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    colorPicker("배경", \.background)
                    colorPicker("글자", \.foreground)
                }
                GridRow {
                    colorPicker("커서", \.cursor)
                    colorPicker("선택 영역", \.selection)
                }
            }

            Toggle("모든 글자를 글자색 한 가지로 표시 (서버가 보내는 색 무시)", isOn: $draft.monochrome)

            Text("ANSI 16색 (Linux 컬러셋)")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<8, id: \.self) { column in
                            let index = row * 8 + column
                            VStack(spacing: 2) {
                                ColorPicker("", selection: ansiBinding(index), supportsOpacity: false)
                                    .labelsHidden()
                                Text(TerminalTheme.ansiNames[index])
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .help("\(index)번 · \(TerminalTheme.ansiNames[index])")
                        }
                    }
                }
            }

            HStack {
                Menu("ANSI 색 불러오기") {
                    Button("Linux 콘솔") { draft.ansi = TerminalTheme.linuxPalette }
                    Button("xterm") { draft.ansi = TerminalTheme.xtermPalette }
                    ForEach(TerminalTheme.builtIns.filter { !$0.monochrome }) { theme in
                        Button(theme.name) { draft.ansi = theme.ansi }
                    }
                }
                .fixedSize()
            }
        }
        .onChange(of: draft) { _, newValue in onChange(newValue) }
    }

    private func colorPicker(_ title: String, _ keyPath: WritableKeyPath<TerminalTheme, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(nsColor: HexColor.nsColor(draft[keyPath: keyPath])) },
            set: { draft[keyPath: keyPath] = HexColor.hex(from: NSColor($0)) }
        ), supportsOpacity: false)
    }

    private func ansiBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: HexColor.nsColor(draft.ansi[index])) },
            set: { draft.ansi[index] = HexColor.hex(from: NSColor($0)) }
        )
    }
}
