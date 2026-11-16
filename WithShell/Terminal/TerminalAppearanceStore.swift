import Foundation
import Observation

/// 터미널 색상 프리셋·기본 설정 저장소 (UserDefaults).
@MainActor
@Observable
final class TerminalAppearanceStore {
    private enum Key {
        static let customThemes = "terminal.customThemes"
        static let defaultThemeID = "terminal.defaultThemeID"
        static let defaultType = "terminal.defaultType"
        static let fontSize = "terminal.fontSize"
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var listeners: [() -> Void] = []

    private(set) var customThemes: [TerminalTheme]

    var defaultThemeID: String {
        didSet { save(); notify() }
    }

    var defaultTerminalType: TerminalType {
        didSet { save() }
    }

    var fontSize: Double {
        didSet { save(); notify() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.customThemes),
           let themes = try? JSONDecoder().decode([TerminalTheme].self, from: data) {
            customThemes = themes
        } else {
            customThemes = []
        }
        defaultThemeID = defaults.string(forKey: Key.defaultThemeID) ?? TerminalTheme.defaultID
        defaultTerminalType = defaults.string(forKey: Key.defaultType).flatMap(TerminalType.init) ?? .xterm256
        let size = defaults.double(forKey: Key.fontSize)
        fontSize = size > 0 ? size : 13
    }

    var allThemes: [TerminalTheme] { TerminalTheme.builtIns + customThemes }

    func theme(id: String) -> TerminalTheme? {
        allThemes.first { $0.id == id }
    }

    /// 세션에 지정된 프리셋(없거나 지워졌으면 기본 프리셋)
    func resolvedTheme(id: String?) -> TerminalTheme {
        if let id, !id.isEmpty, let theme = theme(id: id) { return theme }
        return theme(id: defaultThemeID) ?? TerminalTheme.builtIns[0]
    }

    func resolvedType(_ raw: String?) -> TerminalType {
        raw.flatMap(TerminalType.init) ?? defaultTerminalType
    }

    // MARK: - 사용자 정의 프리셋

    @discardableResult
    func duplicate(_ theme: TerminalTheme) -> TerminalTheme {
        let copy = theme.duplicated(name: "\(theme.name) 복사본")
        customThemes.append(copy)
        save(); notify()
        return copy
    }

    func update(_ theme: TerminalTheme) {
        guard !theme.isBuiltIn, let index = customThemes.firstIndex(where: { $0.id == theme.id }) else { return }
        customThemes[index] = theme
        save(); notify()
    }

    func delete(_ theme: TerminalTheme) {
        customThemes.removeAll { $0.id == theme.id }
        if defaultThemeID == theme.id { defaultThemeID = TerminalTheme.defaultID }
        save(); notify()
    }

    // MARK: - 변경 알림 (열린 터미널에 바로 반영)

    func addListener(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }

    private func notify() {
        listeners.forEach { $0() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customThemes) {
            defaults.set(data, forKey: Key.customThemes)
        }
        defaults.set(defaultThemeID, forKey: Key.defaultThemeID)
        defaults.set(defaultTerminalType.rawValue, forKey: Key.defaultType)
        defaults.set(fontSize, forKey: Key.fontSize)
    }
}
