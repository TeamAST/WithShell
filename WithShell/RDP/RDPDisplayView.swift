import AppKit
import Carbon.HIToolbox

/// 원격 화면을 그리고 키보드·마우스 입력을 RDP로 보낸다.
@MainActor
final class RDPDisplayView: NSView {
    weak var connection: RDPConnection?
    /// 창 크기가 바뀌어 원격 해상도를 바꿔야 할 때 (픽셀 단위 크기, 배율)
    var onResizeRequest: ((CGSize, CGFloat) -> Void)?

    private var remoteSize = CGSize.zero
    private var pressedModifiers = Set<UInt16>()
    private var currentCursor: NSCursor = .arrow
    private var lastCursor: RDPCursor = .arrow

    // ⌘ 처리: ⌘만 눌렀다 떼면 Windows 키, ⌘+C/V 등은 Ctrl+C/V 로 보낸다.
    private var commandDown = false
    private var commandUsed = false
    private var swallowedKeyUps = Set<UInt16>()
    private var resizeWorkItem: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var scrollAccumulator = CGPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - 그리기

    func displayFrame() {
        guard let connection, let image = connection.framebuffer.makeImage() else { return }
        let newSize = CGSize(width: image.width, height: image.height)
        let sizeChanged = newSize != remoteSize
        remoteSize = newSize
        if sizeChanged { applyCursor(lastCursor) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    /// 지금 뷰 크기에 맞는 원격 해상도 (픽셀)와 배율
    var preferredRemoteSize: (size: CGSize, scale: CGFloat) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return (CGSize(width: bounds.width * scale, height: bounds.height * scale), scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
        // 창 크기 조절이 끝난 뒤에 한 번만 해상도 변경을 요청한다.
        resizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, bounds.width > 0, bounds.height > 0 else { return }
            let preferred = preferredRemoteSize
            onResizeRequest?(preferred.size, preferred.scale)
        }
        resizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - 커서

    /// 원격 픽셀 1개가 화면에서 차지하는 포인트 크기
    private var displayScale: CGFloat {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return 1 }
        return min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
    }

    func applyCursor(_ cursor: RDPCursor) {
        lastCursor = cursor
        switch cursor {
        case .arrow:
            currentCursor = .arrow
        case .hidden:
            currentCursor = Self.invisibleCursor
        case .image(let data, let width, let height, let hotSpot):
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  )
            else { return }
            let scale = displayScale
            let size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            currentCursor = NSCursor(
                image: NSImage(cgImage: image, size: size),
                hotSpot: NSPoint(x: hotSpot.x * scale, y: hotSpot.y * scale)
            )
        }
        window?.invalidateCursorRects(for: self)
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            currentCursor.set()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    // MARK: - 좌표 변환 (resizeAspect 레이아웃 기준)

    private func remotePoint(for event: NSEvent) -> (x: Int, y: Int) {
        let local = convert(event.locationInWindow, from: nil)
        guard remoteSize.width > 0, remoteSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return (Int(local.x), Int(local.y))
        }
        let scale = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let drawn = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        let origin = CGPoint(x: (bounds.width - drawn.width) / 2, y: (bounds.height - drawn.height) / 2)
        let x = (local.x - origin.x) / scale
        let y = (local.y - origin.y) / scale
        return (
            Int(min(max(0, x), remoteSize.width - 1)),
            Int(min(max(0, y), remoteSize.height - 1))
        )
    }

    // MARK: - 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func sendMouse(_ flags: Int, _ event: NSEvent) {
        let point = remotePoint(for: event)
        connection?.sendMouse(flags: UInt16(flags), x: point.x, y: point.y)
    }

    override func mouseMoved(with event: NSEvent) { sendMouse(WS_PTR_MOVE, event) }
    override func mouseDragged(with event: NSEvent) { sendMouse(WS_PTR_MOVE, event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(WS_PTR_MOVE, event) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(WS_PTR_MOVE, event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouse(WS_PTR_DOWN | WS_PTR_BUTTON1, event)
    }
    override func mouseUp(with event: NSEvent) { sendMouse(WS_PTR_BUTTON1, event) }
    override func rightMouseDown(with event: NSEvent) { sendMouse(WS_PTR_DOWN | WS_PTR_BUTTON2, event) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(WS_PTR_BUTTON2, event) }
    override func otherMouseDown(with event: NSEvent) { sendMouse(WS_PTR_DOWN | WS_PTR_BUTTON3, event) }
    override func otherMouseUp(with event: NSEvent) { sendMouse(WS_PTR_BUTTON3, event) }

    override func scrollWheel(with event: NSEvent) {
        // 트랙패드는 픽셀 단위, 마우스 휠은 줄 단위. RDP 휠 한 칸 = 120.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 120
        scrollAccumulator.y += event.scrollingDeltaY * factor
        scrollAccumulator.x += event.scrollingDeltaX * factor
        let point = remotePoint(for: event)

        func emit(_ amount: inout CGFloat, flag: Int, invert: Bool) {
            while abs(amount) >= 1 {
                let step = Int(max(-255, min(255, amount.rounded(.towardZero))))
                if step == 0 { break }
                amount -= CGFloat(step)
                let value = invert ? -step : step
                var flags = flag
                if value < 0 {
                    flags |= WS_PTR_WHEEL_NEGATIVE | ((0x100 + value) & 0xFF)
                } else {
                    flags |= value & 0xFF
                }
                connection?.sendMouse(flags: UInt16(flags), x: point.x, y: point.y)
            }
        }
        emit(&scrollAccumulator.y, flag: WS_PTR_WHEEL, invert: false)
        // 가로 휠은 방향이 반대
        emit(&scrollAccumulator.x, flag: WS_PTR_HWHEEL, invert: true)
    }

    // MARK: - 키보드

    /// RDP 스캔코드
    private enum Scan {
        static let control: UInt16 = 0x1D
        static let alt: UInt16 = 0x38
        static let windows: UInt16 = 0x5B  // extended
        static let delete: UInt16 = 0x53   // extended
    }

    /// ⌘ 와 함께 누르면 원격에 Ctrl 조합으로 보내는 키 (A C V X Z Y F S P)
    private static let controlMappedKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_Y, kVK_ANSI_F, kVK_ANSI_S, kVK_ANSI_P,
    ]

    /// ⌘ 조합 중 WithShell 앱이 처리하는 단축키 (탭 닫기·새 세션·탭 이동 등)
    private static let appReservedKeys: Set<Int> = [
        kVK_ANSI_W, kVK_ANSI_T, kVK_ANSI_N, kVK_ANSI_Q, kVK_ANSI_K, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_Comma,
        kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_Tab, kVK_ANSI_Grave,
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              connection != nil
        else { return super.performKeyEquivalent(with: event) }

        let code = Int(event.keyCode)
        if Self.appReservedKeys.contains(code) { return false }

        commandUsed = true
        let modifier = Self.controlMappedKeys.contains(code) ? (Scan.control, false) : (Scan.windows, true)
        connection?.sendScancode(modifier.0, extended: modifier.1, down: true)
        connection?.sendMacKey(event.keyCode, down: true)
        connection?.sendMacKey(event.keyCode, down: false)
        connection?.sendScancode(modifier.0, extended: modifier.1, down: false)
        swallowedKeyUps.insert(event.keyCode)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if commandDown { return } // ⌘ 조합은 performKeyEquivalent 에서 처리
        connection?.sendMacKey(event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if swallowedKeyUps.remove(event.keyCode) != nil { return }
        connection?.sendMacKey(event.keyCode, down: false)
    }

    /// Shift·Control·Option·Command·Caps Lock 은 keyDown 이 오지 않으므로 상태 변화로 처리한다.
    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        let flag: NSEvent.ModifierFlags? = switch Int(code) {
        case kVK_Shift, kVK_RightShift: .shift
        case kVK_Control, kVK_RightControl: .control
        case kVK_Option, kVK_RightOption: .option
        case kVK_Command, kVK_RightCommand: .command
        case kVK_CapsLock: .capsLock
        default: nil
        }
        guard let flag else { return }

        if code == UInt16(kVK_CapsLock) {
            // Caps Lock 은 누를 때마다 토글 신호만 오므로 눌렀다 뗀 것으로 보낸다.
            connection?.sendMacKey(code, down: true)
            connection?.sendMacKey(code, down: false)
            return
        }

        if flag == .command {
            // ⌘ 는 바로 보내지 않는다: 단독으로 눌렀다 떼면 Windows 키(시작 메뉴)
            if event.modifierFlags.contains(.command) {
                if !commandDown { commandDown = true; commandUsed = false }
            } else if commandDown {
                commandDown = false
                if !commandUsed {
                    connection?.sendScancode(Scan.windows, extended: true, down: true)
                    connection?.sendScancode(Scan.windows, extended: true, down: false)
                }
            }
            return
        }

        let isDown = event.modifierFlags.contains(flag) && !pressedModifiers.contains(code)
        if isDown {
            pressedModifiers.insert(code)
        } else {
            pressedModifiers.remove(code)
        }
        connection?.sendMacKey(code, down: isDown)
    }

    func sendCtrlAltDelete() {
        connection?.sendScancode(Scan.control, down: true)
        connection?.sendScancode(Scan.alt, down: true)
        connection?.sendScancode(Scan.delete, extended: true, down: true)
        connection?.sendScancode(Scan.delete, extended: true, down: false)
        connection?.sendScancode(Scan.alt, down: false)
        connection?.sendScancode(Scan.control, down: false)
    }

    /// 포커스를 잃으면 눌린 채로 남은 modifier 를 떼어 준다 (원격에서 Ctrl 이 계속 눌린 상태 방지).
    override func resignFirstResponder() -> Bool {
        for code in pressedModifiers {
            connection?.sendMacKey(code, down: false)
        }
        pressedModifiers.removeAll()
        commandDown = false
        swallowedKeyUps.removeAll()
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    /// 화면에 포커스가 올 때 (클립보드 동기화용)
    var onFocus: (() -> Void)?
}
