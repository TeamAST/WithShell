import CoreGraphics
import Foundation

/// 원격 화면 버퍼 (BGRA 32비트). RDP 스레드가 쓰고 메인 스레드가 읽는다.
final class RDPFramebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var width = 0
    private(set) var height = 0
    private var stride: Int { width * 4 }

    var size: CGSize {
        lock.withLock { CGSize(width: width, height: height) }
    }

    func resize(width: Int, height: Int) {
        lock.withLock {
            self.width = width
            self.height = height
            buffer = Data(count: width * height * 4)
        }
    }

    /// FreeRDP 버퍼에서 바뀐 영역만 복사한다.
    func copy(from source: UnsafePointer<UInt8>, sourceWidth: Int, sourceHeight: Int, sourceStride: Int,
              x: Int, y: Int, w: Int, h: Int) {
        lock.withLock {
            if sourceWidth != width || sourceHeight != height {
                width = sourceWidth
                height = sourceHeight
                buffer = Data(count: width * height * 4)
            }
            let x0 = max(0, x), y0 = max(0, y)
            let x1 = min(width, x + w), y1 = min(height, y + h)
            guard x1 > x0, y1 > y0 else { return }
            let rowBytes = (x1 - x0) * 4
            let destStride = stride
            buffer.withUnsafeMutableBytes { dest in
                guard let base = dest.baseAddress else { return }
                for row in y0..<y1 {
                    memcpy(base + row * destStride + x0 * 4, source + row * sourceStride + x0 * 4, rowBytes)
                }
            }
        }
    }

    func makeImage() -> CGImage? {
        lock.withLock {
            guard width > 0, height > 0, let provider = CGDataProvider(data: buffer as CFData) else { return nil }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }
}

/// 서버 인증서 정보
struct RDPCertificateInfo: Sendable {
    let host: String
    let port: Int
    let commonName: String
    let subject: String
    let issuer: String
    let fingerprint: String
    /// 이전에 신뢰했던 인증서의 지문 (바뀐 경우)
    let previousFingerprint: String?
}

enum RDPCertificateDecision: Sendable {
    case reject, acceptPermanently, acceptOnce
}

/// FreeRDP 세션 하나. C 브리지 콜백(RDP 스레드)을 Swift 이벤트로 바꾼다.
final class RDPConnection: @unchecked Sendable {
    struct Config: Sendable {
        let host: String
        let port: Int
        let username: String
        let domain: String
        let password: String
        let width: Int
        let height: Int
        let desktopScale: Int
        let deviceScale: Int
    }

    enum Event: Sendable {
        case connecting
        case connected
        case disconnected
        case failed(name: String, message: String)
        case resized(width: Int, height: Int)
        case frameUpdated
        case cursor(RDPCursor)
        case remoteClipboard(String)
    }

    let framebuffer = RDPFramebuffer()

    private let lock = NSLock()
    private var session: OpaquePointer?
    private var finished = false
    private var pendingCertificate: (semaphore: DispatchSemaphore, decision: RDPCertificateDecision)?
    private var displayScheduled = false

    private let onEvent: @Sendable (Event) -> Void
    private let onCertificate: @Sendable (RDPCertificateInfo, @escaping @Sendable (RDPCertificateDecision) -> Void) -> Void

    init(
        onEvent: @escaping @Sendable (Event) -> Void,
        onCertificate: @escaping @Sendable (RDPCertificateInfo, @escaping @Sendable (RDPCertificateDecision) -> Void) -> Void
    ) {
        self.onEvent = onEvent
        self.onCertificate = onCertificate
    }

    /// 연결 스레드를 시작한다. 실패하면 false.
    func start(_ config: Config) -> Bool {
        // 콜백이 살아 있는 동안 self를 유지한다 (destroy 후 해제).
        let user = Unmanaged.passRetained(self).toOpaque()

        var callbacks = ws_rdp_callbacks()
        callbacks.user = user
        callbacks.on_frame = { user, buffer, width, height, stride, x, y, w, h in
            guard let user, let buffer else { return }
            let connection = Unmanaged<RDPConnection>.fromOpaque(user).takeUnretainedValue()
            connection.framebuffer.copy(
                from: buffer, sourceWidth: Int(width), sourceHeight: Int(height), sourceStride: Int(stride),
                x: Int(x), y: Int(y), w: Int(w), h: Int(h)
            )
            connection.scheduleDisplay()
        }
        callbacks.on_resize = { user, width, height in
            guard let user else { return }
            let connection = Unmanaged<RDPConnection>.fromOpaque(user).takeUnretainedValue()
            connection.framebuffer.resize(width: Int(width), height: Int(height))
            connection.onEvent(.resized(width: Int(width), height: Int(height)))
        }
        callbacks.on_state = { user, state, _, name, message in
            guard let user else { return }
            let connection = Unmanaged<RDPConnection>.fromOpaque(user).takeUnretainedValue()
            switch state {
            case WS_RDP_STATE_CONNECTING: connection.onEvent(.connecting)
            case WS_RDP_STATE_CONNECTED: connection.onEvent(.connected)
            case WS_RDP_STATE_FAILED:
                connection.onEvent(.failed(
                    name: name.map { String(cString: $0) } ?? "",
                    message: message.map { String(cString: $0) } ?? ""
                ))
            default: connection.onEvent(.disconnected)
            }
        }
        callbacks.on_cursor = { user, kind, bgra, width, height, hotX, hotY in
            guard let user else { return }
            let connection = Unmanaged<RDPConnection>.fromOpaque(user).takeUnretainedValue()
            let cursor: RDPCursor
            switch kind {
            case 0 where bgra != nil && width > 0 && height > 0:
                let data = Data(bytes: bgra!, count: Int(width * height * 4))
                cursor = .image(data, width: Int(width), height: Int(height), hotSpot: CGPoint(x: Int(hotX), y: Int(hotY)))
            case 1: cursor = .hidden
            default: cursor = .arrow
            }
            connection.onEvent(.cursor(cursor))
        }
        callbacks.on_remote_clipboard = { user, utf8 in
            guard let user, let utf8 else { return }
            let connection = Unmanaged<RDPConnection>.fromOpaque(user).takeUnretainedValue()
            connection.onEvent(.remoteClipboard(String(cString: utf8)))
        }
        callbacks.verify_certificate = { user, host, port, commonName, subject, issuer, fingerprint, oldFingerprint in
            guard let user else { return WS_RDP_CERT_REJECT }
            let connection = Unmanaged<RDPConnection>.fromOpaque(user).takeUnretainedValue()
            let info = RDPCertificateInfo(
                host: host.map { String(cString: $0) } ?? "",
                port: Int(port),
                commonName: commonName.map { String(cString: $0) } ?? "",
                subject: subject.map { String(cString: $0) } ?? "",
                issuer: issuer.map { String(cString: $0) } ?? "",
                fingerprint: fingerprint.map { String(cString: $0) } ?? "",
                previousFingerprint: oldFingerprint.map { String(cString: $0) }
            )
            switch connection.waitForCertificateDecision(info) {
            case .acceptPermanently: return WS_RDP_CERT_ACCEPT_PERMANENTLY
            case .acceptOnce: return WS_RDP_CERT_ACCEPT_ONCE
            case .reject: return WS_RDP_CERT_REJECT
            }
        }

        let created: OpaquePointer? = config.host.withCString { host in
            config.username.withCString { username in
                config.domain.withCString { domain in
                    config.password.withCString { password in
                        var c = ws_rdp_config(
                            host: host, port: UInt16(config.port),
                            username: username, domain: domain, password: password,
                            width: UInt32(config.width), height: UInt32(config.height),
                            desktop_scale: UInt32(config.desktopScale), device_scale: UInt32(config.deviceScale)
                        )
                        return ws_rdp_create(&callbacks, &c)
                    }
                }
            }
        }

        guard let created, ws_rdp_start(created) else {
            if let created { ws_rdp_destroy(created) }
            Unmanaged<RDPConnection>.fromOpaque(user).release()
            return false
        }
        lock.withLock { session = created }
        return true
    }

    /// 연결을 끊고 자원을 정리한다 (백그라운드에서 스레드 종료를 기다림).
    func stop() {
        let target: OpaquePointer? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            // 인증서 확인을 기다리는 중이면 거부로 풀어 준다.
            if let pending = pendingCertificate {
                pendingCertificate = (pending.semaphore, .reject)
                pending.semaphore.signal()
            }
            defer { session = nil }
            return session
        }
        guard let target else { return }
        ws_rdp_stop(target)
        // start()에서 passRetained 한 참조를 스레드 정리 후 해제한다.
        let transfer = PointerTransfer(session: target, user: Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.global(qos: .utility).async {
            ws_rdp_destroy(transfer.session)
            Unmanaged<RDPConnection>.fromOpaque(transfer.user).release()
        }
    }

    // MARK: - 입력 (메인 스레드에서 호출)

    private func withSession(_ body: (OpaquePointer) -> Void) {
        lock.withLock {
            if let session, !finished { body(session) }
        }
    }

    func sendMacKey(_ keyCode: UInt16, down: Bool) {
        withSession { ws_rdp_send_mac_key($0, keyCode, down) }
    }

    /// RDP 스캔코드를 직접 보낸다 (Ctrl+Alt+Del 등)
    func sendScancode(_ code: UInt16, extended: Bool = false, down: Bool) {
        withSession { ws_rdp_send_scancode($0, code, extended, down) }
    }

    func setLocalClipboard(_ text: String?) {
        withSession { session in
            if let text {
                text.withCString { ws_rdp_set_local_clipboard(session, $0) }
            } else {
                ws_rdp_set_local_clipboard(session, nil)
            }
        }
    }

    func sendMouse(flags: UInt16, x: Int, y: Int) {
        let x = UInt16(clamping: max(0, x)), y = UInt16(clamping: max(0, y))
        withSession { ws_rdp_send_mouse($0, flags, x, y) }
    }

    func requestResize(width: Int, height: Int, desktopScale: Int, deviceScale: Int) {
        withSession {
            ws_rdp_request_resize($0, UInt32(width), UInt32(height), UInt32(desktopScale), UInt32(deviceScale))
        }
    }

    // MARK: - 내부

    private func scheduleDisplay() {
        let shouldNotify: Bool = lock.withLock {
            if displayScheduled { return false }
            displayScheduled = true
            return true
        }
        guard shouldNotify else { return }
        DispatchQueue.main.async { [self] in
            lock.withLock { displayScheduled = false }
            onEvent(.frameUpdated)
        }
    }

    /// RDP 스레드를 멈추고 사용자의 결정을 기다린다.
    private func waitForCertificateDecision(_ info: RDPCertificateInfo) -> RDPCertificateDecision {
        let semaphore = DispatchSemaphore(value: 0)
        let alreadyFinished: Bool = lock.withLock {
            if finished { return true }
            pendingCertificate = (semaphore, .reject)
            return false
        }
        if alreadyFinished { return .reject }

        onCertificate(info) { [self] decision in
            lock.withLock {
                guard let pending = pendingCertificate, pending.semaphore === semaphore else { return }
                pendingCertificate = (semaphore, decision)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return lock.withLock {
            defer { pendingCertificate = nil }
            return pendingCertificate?.decision ?? .reject
        }
    }
}

/// C 포인터를 정리용 백그라운드 큐로 넘기기 위한 상자
private struct PointerTransfer: @unchecked Sendable {
    let session: OpaquePointer
    let user: UnsafeMutableRawPointer
}

/// 원격 커서 모양 (이미지는 BGRA 32비트, 원격 픽셀 단위)
enum RDPCursor: Sendable {
    case image(Data, width: Int, height: Int, hotSpot: CGPoint)
    case hidden
    case arrow
}
