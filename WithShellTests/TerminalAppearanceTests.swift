import Foundation
import Testing
@testable import WithShell

struct SGRColorStripperTests {
    static func strip(_ chunks: [String]) -> String {
        var stripper = SGRColorStripper()
        var out: [UInt8] = []
        for chunk in chunks { out += stripper.process(Array(chunk.utf8)) }
        return String(decoding: out, as: UTF8.self)
    }

    static let e = "\u{1B}"

    @Test func plainTextUntouched() {
        #expect(Self.strip(["hello 한글\r\n"]) == "hello 한글\r\n")
    }

    @Test func removesForegroundAndBackgroundColors() {
        #expect(Self.strip(["\(Self.e)[31mred\(Self.e)[0m"]) == "red\(Self.e)[0m")
        #expect(Self.strip(["\(Self.e)[44;97mx"]) == "x")
        #expect(Self.strip(["\(Self.e)[39;49m"]) == "")
    }

    @Test func keepsOtherAttributes() {
        #expect(Self.strip(["\(Self.e)[1;31mbold"]) == "\(Self.e)[1mbold")
        #expect(Self.strip(["\(Self.e)[0;4;32mu"]) == "\(Self.e)[0;4mu")
        #expect(Self.strip(["\(Self.e)[7m"]) == "\(Self.e)[7m")
        #expect(Self.strip(["\(Self.e)[m"]) == "\(Self.e)[m")
    }

    @Test func removes256AndTrueColor() {
        #expect(Self.strip(["\(Self.e)[1;38;5;196;4mX"]) == "\(Self.e)[1;4mX")
        #expect(Self.strip(["\(Self.e)[38;2;10;20;30;48;2;1;2;3mX"]) == "X")
        #expect(Self.strip(["\(Self.e)[38:2::10:20:30;1mX"]) == "\(Self.e)[1mX")
    }

    @Test func otherControlSequencesPassThrough() {
        let screen = "\(Self.e)[2J\(Self.e)[H\(Self.e)[?25l\(Self.e)]0;title\u{07}"
        #expect(Self.strip([screen]) == screen)
    }

    @Test func sequencesSplitAcrossChunks() {
        #expect(Self.strip(["ab\(Self.e)", "[3", "1;1", "mcd"]) == "ab\(Self.e)[1mcd")
        #expect(Self.strip(["\(Self.e)[38;5", ";82mgreen"]) == "green")
    }
}

@MainActor
struct TerminalThemeTests {
    @Test func builtInPresetsAreValid() {
        let ids = Set(TerminalTheme.builtIns.map(\.id))
        #expect(ids.count == TerminalTheme.builtIns.count)
        #expect(ids.contains(TerminalTheme.defaultID))
        for theme in TerminalTheme.builtIns {
            #expect(theme.ansi.count == 16, "\(theme.name)")
            for hex in [theme.background, theme.foreground, theme.cursor, theme.selection] + theme.ansi {
                #expect(hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil, "\(theme.name) \(hex)")
            }
        }
        let names = TerminalTheme.builtIns.map(\.name)
        #expect(names.contains("검정 배경 / 흰 글자"))
        #expect(names.contains("흰 배경 / 검정 글자"))
        #expect(TerminalTheme.builtIns.contains { $0.monochrome && $0.background == "#000000" && $0.foreground == "#FFFFFF" })
    }

    @Test func hexRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#2472C8", "#CD3131"] {
            #expect(HexColor.hex(from: HexColor.nsColor(hex)) == hex)
        }
    }

    @Test func customThemesPersist() throws {
        let suite = "withshell-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = TerminalAppearanceStore(defaults: defaults)
        #expect(store.defaultThemeID == TerminalTheme.defaultID)
        #expect(store.defaultTerminalType == .xterm256)

        var custom = store.duplicate(TerminalTheme.builtIns[0])
        custom.name = "내 프리셋"
        custom.ansi[1] = "#123456"
        store.update(custom)
        store.defaultThemeID = custom.id
        store.defaultTerminalType = .vt100
        store.fontSize = 15

        let reloaded = TerminalAppearanceStore(defaults: defaults)
        #expect(reloaded.customThemes.count == 1)
        #expect(reloaded.customThemes.first?.ansi[1] == "#123456")
        #expect(reloaded.resolvedTheme(id: nil).name == "내 프리셋")
        #expect(reloaded.defaultTerminalType == .vt100)
        #expect(reloaded.fontSize == 15)

        // 기본으로 쓰던 프리셋을 지우면 기본 제공 프리셋으로 돌아간다
        reloaded.delete(custom)
        #expect(reloaded.defaultThemeID == TerminalTheme.defaultID)
        #expect(reloaded.resolvedTheme(id: custom.id).id == TerminalTheme.defaultID)
        #expect(reloaded.resolvedType("vt220") == .vt220)
        #expect(reloaded.resolvedType("") == .vt100)
    }
}

struct OpenSourceLicenseTests {
    /// 앱 번들에 오픈소스 고지가 들어 있고 주요 항목이 빠지지 않았는지
    @Test func bundledNoticesIncludeAllComponents() throws {
        let entries = OpenSourceLicense.loadBundled()
        let names = Set(entries.map(\.name))
        for required in ["WithShell", "FreeRDP", "OpenSSL", "SwiftTerm", "Citadel", "swift-nio", "swift-nio-ssh",
                         "swift-crypto", "BigInt", "Blowfish (OpenBSD)", "bcrypt_pbkdf (OpenBSD, via Citadel)"] {
            #expect(names.contains(required), "\(required) 누락")
        }
        for entry in entries {
            #expect(entry.text.count > 500, "\(entry.name) 라이선스 전문이 너무 짧음")
        }
        #expect(entries.first?.license == "MIT")
        #expect(entries.first { $0.name == "Blowfish (OpenBSD)" }?.text.contains("Niels Provos") == true)
    }
}
