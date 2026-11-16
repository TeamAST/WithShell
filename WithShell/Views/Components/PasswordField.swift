import AppKit
import SwiftUI

/// 비밀번호 입력 칸.
/// - 입력하는 동안 로마자 입력 소스만 쓰도록 해서 한글 입력기로 바뀌지 않게 한다.
/// - 그래도 들어온 영문 외 문자(한글 등)는 지우고 안내를 표시한다.
struct PasswordField: View {
    let title: String
    @Binding var text: String
    var autoFocus = false
    var onSubmit: () -> Void = {}

    @State private var rejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ASCIISecureTextField(
                placeholder: title,
                text: $text,
                autoFocus: autoFocus,
                onReject: { rejected = true },
                onSubmit: onSubmit
            )
            .frame(height: 22)
            if rejected {
                Label("영문 입력 상태에서 입력하세요. 한글 등 영문 외 문자는 입력되지 않습니다.", systemImage: "character.cursor.ibeam")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty { rejected = false }
        }
    }

    /// 비밀번호로 허용하는 문자: 인쇄 가능한 ASCII (공백~물결표)
    nonisolated static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value)
    }

    nonisolated static func filter(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter(isAllowed)))
    }
}

private struct ASCIISecureTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let autoFocus: Bool
    let onReject: () -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> RomanOnlySecureTextField {
        let field = RomanOnlySecureTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.stringValue = text
        if autoFocus {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: RomanOnlySecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ASCIISecureTextField

        init(parent: ASCIISecureTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let filtered = PasswordField.filter(field.stringValue)
            if filtered != field.stringValue {
                field.stringValue = filtered
                parent.onReject()
            }
            parent.text = filtered
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// 포커스를 받으면 입력 소스를 로마자 계열로 제한한다 (한글 입력기 → 영문으로 동작).
final class RomanOnlySecureTextField: NSSecureTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let editor = currentEditor() as? NSTextView {
            editor.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        return result
    }

    /// 다른 입력 칸에서는 다시 모든 입력 소스(한글 등)를 쓸 수 있게 되돌린다.
    override func textDidEndEditing(_ notification: Notification) {
        (currentEditor() as? NSTextView)?.inputContext?.allowedInputSourceLocales = nil
        super.textDidEndEditing(notification)
    }
}
