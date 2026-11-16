import AppKit
import Foundation
import SwiftTerm

/// 터미널 색상 프리셋. 색은 `#RRGGBB` 문자열로 저장한다.
struct TerminalTheme: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isBuiltIn: Bool
    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    /// ANSI 16색: 0~7 기본, 8~15 밝은 색
    var ansi: [String]
    /// 모든 색 지정(ANSI·256색·트루컬러, 글자·배경)을 무시하고 전경색 한 가지로만 표시
    var monochrome: Bool = false

    static let ansiNames = [
        "검정", "빨강", "초록", "노랑", "파랑", "자주", "청록", "흰색",
        "밝은 검정", "밝은 빨강", "밝은 초록", "밝은 노랑", "밝은 파랑", "밝은 자주", "밝은 청록", "밝은 흰색",
    ]

    /// 사용자 정의 프리셋을 만들기 위한 복제본
    func duplicated(name: String) -> TerminalTheme {
        var copy = self
        copy.id = "custom-" + UUID().uuidString
        copy.name = name
        copy.isBuiltIn = false
        return copy
    }
}

// MARK: - 기본 제공 프리셋

extension TerminalTheme {
    static let defaultID = "builtin-dark"

    private static func builtIn(
        _ id: String, _ name: String,
        background: String, foreground: String, cursor: String? = nil, selection: String,
        ansi: [String], monochrome: Bool = false
    ) -> TerminalTheme {
        TerminalTheme(
            id: "builtin-" + id, name: name, isBuiltIn: true,
            background: background, foreground: foreground, cursor: cursor ?? foreground,
            selection: selection, ansi: ansi, monochrome: monochrome
        )
    }

    static let xtermPalette = [
        "#000000", "#CD0000", "#00CD00", "#CDCD00", "#0000EE", "#CD00CD", "#00CDCD", "#E5E5E5",
        "#7F7F7F", "#FF0000", "#00FF00", "#FFFF00", "#5C5CFF", "#FF00FF", "#00FFFF", "#FFFFFF",
    ]

    static let linuxPalette = [
        "#000000", "#AA0000", "#00AA00", "#AA5500", "#0000AA", "#AA00AA", "#00AAAA", "#AAAAAA",
        "#555555", "#FF5555", "#55FF55", "#FFFF55", "#5555FF", "#FF55FF", "#55FFFF", "#FFFFFF",
    ]

    static let builtIns: [TerminalTheme] = [
        builtIn("dark", "검정 배경 / 흰 글자",
                background: "#000000", foreground: "#FFFFFF", selection: "#4D4D4D",
                ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
                       "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF"]),
        builtIn("light", "흰 배경 / 검정 글자",
                background: "#FFFFFF", foreground: "#000000", selection: "#B4D5FE",
                ansi: ["#000000", "#990000", "#00A600", "#999900", "#0000B2", "#B200B2", "#00A6B2", "#BFBFBF",
                       "#666666", "#E50000", "#00D900", "#E5E500", "#0000FF", "#E500E5", "#00E5E5", "#E5E5E5"]),
        builtIn("mono-white", "검정 배경 / 흰색만 (색 무시)",
                background: "#000000", foreground: "#FFFFFF", selection: "#4D4D4D",
                ansi: Array(repeating: "#FFFFFF", count: 16), monochrome: true),
        builtIn("linux", "Linux 콘솔",
                background: "#000000", foreground: "#AAAAAA", selection: "#555555", ansi: linuxPalette),
        builtIn("xterm", "xterm",
                background: "#000000", foreground: "#E5E5E5", selection: "#4D4D4D", ansi: xtermPalette),
        builtIn("green", "녹색 단말기",
                background: "#000000", foreground: "#28FE14", selection: "#0B4A06",
                ansi: ["#000000", "#990000", "#00A600", "#999900", "#0000B2", "#B200B2", "#00A6B2", "#BFBFBF",
                       "#666666", "#E50000", "#00D900", "#E5E500", "#0000FF", "#E500E5", "#00E5E5", "#E5E5E5"]),
        builtIn("tango", "Tango",
                background: "#2E3436", foreground: "#D3D7CF", selection: "#555753",
                ansi: ["#2E3436", "#CC0000", "#4E9A06", "#C4A000", "#3465A4", "#75507B", "#06989A", "#D3D7CF",
                       "#555753", "#EF2929", "#8AE234", "#FCE94F", "#729FCF", "#AD7FA8", "#34E2E2", "#EEEEEC"]),
        builtIn("solarized-dark", "Solarized Dark",
                background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
                ansi: solarized),
        builtIn("solarized-light", "Solarized Light",
                background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5",
                ansi: solarized),
        builtIn("dracula", "Dracula",
                background: "#282A36", foreground: "#F8F8F2", selection: "#44475A",
                ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                       "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        builtIn("monokai", "Monokai",
                background: "#272822", foreground: "#F8F8F2", selection: "#49483E",
                ansi: ["#272822", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
                       "#75715E", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5"]),
        builtIn("nord", "Nord",
                background: "#2E3440", foreground: "#D8DEE9", selection: "#434C5E",
                ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                       "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        builtIn("gruvbox", "Gruvbox Dark",
                background: "#282828", foreground: "#EBDBB2", selection: "#504945",
                ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                       "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
    ]

    private static let solarized = [
        "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
        "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
    ]
}

// MARK: - 터미널 종류 (TERM)

enum TerminalType: String, CaseIterable, Identifiable, Codable, Sendable {
    case xterm256 = "xterm-256color"
    case xterm = "xterm"
    case linux = "linux"
    case vt100 = "vt100"
    case vt220 = "vt220"
    case ansi = "ansi"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .xterm256: "xterm-256color (권장)"
        case .xterm: "xterm"
        case .linux: "Linux"
        case .vt100: "VT100"
        case .vt220: "VT220"
        case .ansi: "ANSI"
        }
    }
}

// MARK: - 색 변환

enum HexColor {
    /// `#RRGGBB` → (r, g, b) 0~255
    static func components(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return (0, 0, 0) }
        return (UInt8(number >> 16 & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF))
    }

    static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = components(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = components(hex)
        return SwiftTerm.Color(red8: UInt16(r), green8: UInt16(g), blue8: UInt16(b))
    }

    static func hex(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
