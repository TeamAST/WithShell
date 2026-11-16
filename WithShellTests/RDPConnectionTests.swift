import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import WithShell

/// 실제 RDP 서버(xrdp)에 접속하는 통합 테스트.
/// `scripts/test-rdp.sh up` 후 `scripts/test-rdp.sh test`로 실행한다. 환경 변수가 없으면 건너뛴다.
@Suite(.serialized)
struct RDPConnectionTests {
    struct Config {
        let host: String
        let port: Int
        let user: String
        let password: String

        static var fromEnvironment: Config? {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["WITHSHELL_TEST_RDP_HOST"],
                  let port = env["WITHSHELL_TEST_RDP_PORT"].flatMap(Int.init),
                  let user = env["WITHSHELL_TEST_RDP_USER"],
                  let password = env["WITHSHELL_TEST_RDP_PASSWORD"] else { return nil }
            return Config(host: host, port: port, user: user, password: password)
        }
    }

    actor Recorder {
        var events: [String] = []
        var certificates: [RDPCertificateInfo] = []
        var frames = 0
        var cursors = 0
        var remoteClipboard: [String] = []
        var lastSize: (Int, Int)?

        func record(_ event: RDPConnection.Event) {
            switch event {
            case .frameUpdated: frames += 1
            case .resized(let w, let h): lastSize = (w, h); events.append("resized \(w)x\(h)")
            case .connecting: events.append("connecting")
            case .connected: events.append("connected")
            case .disconnected: events.append("disconnected")
            case .failed(let name, let message): events.append("failed \(name) \(message)")
            case .cursor: cursors += 1
            case .remoteClipboard(let text): remoteClipboard.append(text)
            }
        }

        func record(_ certificate: RDPCertificateInfo) { certificates.append(certificate) }

        func has(_ prefix: String) -> Bool { events.contains { $0.hasPrefix(prefix) } }
        func isClosed() -> Bool { has("disconnected") || has("failed") }
        func isClosedOrConnected() -> Bool { isClosed() || has("connected") }
    }

    static func waitUntil(timeout: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    static func makeConnection(_ recorder: Recorder, decision: RDPCertificateDecision) -> RDPConnection {
        RDPConnection(
            onEvent: { event in Task { await recorder.record(event) } },
            onCertificate: { info, reply in
                Task {
                    await recorder.record(info)
                    reply(decision)
                }
            }
        )
    }

    @Test(.enabled(if: Config.fromEnvironment != nil))
    func connectsAndReceivesDesktop() async throws {
        let config = try #require(Config.fromEnvironment)
        let recorder = Recorder()
        let connection = Self.makeConnection(recorder, decision: .acceptOnce)

        #expect(connection.start(.init(
            host: config.host, port: config.port, username: config.user, domain: "", password: config.password,
            width: 1280, height: 800, desktopScale: 100, deviceScale: 100
        )))

        let connected = await Self.waitUntil(timeout: 20) { await recorder.has("connected") }
        let events = await recorder.events
        #expect(connected, "연결되지 않음: \(events)")

        // 자체 서명 인증서 → 확인 요청이 와야 한다.
        let certificates = await recorder.certificates
        #expect(certificates.count == 1)
        print("RDP-CERT \(certificates.first?.commonName ?? "") \(certificates.first?.fingerprint ?? "")")

        // 화면이 실제로 그려지는지: 프레임 수신 + 단색이 아닌 픽셀
        // (원격 데스크톱 세션이 뜨는 데 몇 초 걸린다)
        let drawn = await Self.waitUntil(timeout: 30) {
            guard let image = connection.framebuffer.makeImage() else { return false }
            return Self.distinctColors(in: image) > 10
        }
        let image = try #require(connection.framebuffer.makeImage())
        Self.save(image, name: "rdp-desktop.png")
        let frameCount = await recorder.frames
        #expect(drawn, "화면이 단색임 (프레임 \(frameCount)개)")
        #expect(image.width == 1280 && image.height == 800, "\(image.width)x\(image.height)")

        // 입력이 오류 없이 전송되는지 (마우스 이동, 키 입력)
        connection.sendMouse(flags: UInt16(WS_PTR_MOVE), x: 400, y: 300)
        connection.sendMacKey(0x31, down: true)  // space
        connection.sendMacKey(0x31, down: false)

        // 원격 커서 모양을 받았는지
        let gotCursor = await Self.waitUntil(timeout: 5) { await recorder.cursors > 0 }
        #expect(gotCursor, "커서 이벤트 없음")

        // 해상도 변경 요청 (서버가 Display Control 을 지원할 때만 반영됨)
        try await Task.sleep(for: .seconds(2))
        connection.requestResize(width: 1024, height: 768, desktopScale: 100, deviceScale: 100)
        let resized = await Self.waitUntil(timeout: 10) {
            if let size = await recorder.lastSize { return size == (1024, 768) }
            return false
        }
        print("RDP-RESIZE \(resized ? "applied" : "not supported by server") events=\(await recorder.events)")
        if resized, let resizedImage = connection.framebuffer.makeImage() {
            try await Task.sleep(for: .seconds(2))
            Self.save(connection.framebuffer.makeImage() ?? resizedImage, name: "rdp-resized.png")
        }

        connection.stop()
        let closed = await Self.waitUntil(timeout: 10) { await recorder.isClosed() }
        #expect(closed)
        let finalEvents = await recorder.events
        let failedAtEnd = await recorder.has("failed")
        print("RDP-FINAL \(finalEvents)")
        #expect(!failedAtEnd, "\(finalEvents)")
    }

    /// Mac ↔ 원격 클립보드 텍스트 왕복. scripts/test-rdp.sh test 가 원격 쪽(xclip)을 맡는다.
    @Test(.enabled(if: Config.fromEnvironment != nil && ProcessInfo.processInfo.environment["WITHSHELL_TEST_RDP_CLIPBOARD"] == "1"))
    func clipboardRoundTrip() async throws {
        let config = try #require(Config.fromEnvironment)
        let recorder = Recorder()
        let connection = Self.makeConnection(recorder, decision: .acceptOnce)
        #expect(connection.start(.init(
            host: config.host, port: config.port, username: config.user, domain: "", password: config.password,
            width: 1024, height: 768, desktopScale: 100, deviceScale: 100
        )))
        defer { connection.stop() }
        let connected = await Self.waitUntil(timeout: 20) { await recorder.has("connected") }
        try #require(connected)
        // 원격 세션(X)이 뜰 때까지
        _ = await Self.waitUntil(timeout: 30) {
            guard let image = connection.framebuffer.makeImage() else { return false }
            return Self.distinctColors(in: image) > 10
        }
        try await Task.sleep(for: .seconds(2))

        let signal = URL(fileURLWithPath: NSTemporaryDirectory())
        let local = "withshell-local-\(UUID().uuidString.prefix(8)) 한글 ✓"
        connection.setLocalClipboard(local)
        try await Task.sleep(for: .seconds(1))
        try Data(local.utf8).write(to: signal.appendingPathComponent("clip-request.txt"))

        // Mac → 원격
        let responseURL = signal.appendingPathComponent("clip-response.txt")
        let gotResponse = await Self.waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: responseURL.path) }
        try #require(gotResponse, "스크립트 응답 없음")
        let remoteSaw = try String(contentsOf: responseURL, encoding: .utf8)
        #expect(remoteSaw == local, "원격 클립보드: \(remoteSaw)")
        print("RDP-CLIP local→remote \(remoteSaw == local ? "ok" : "mismatch: \(remoteSaw)")")

        // 원격 → Mac
        let remoteURL = signal.appendingPathComponent("clip-remote.txt")
        _ = await Self.waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: remoteURL.path) }
        let expected = try String(contentsOf: remoteURL, encoding: .utf8)
        let received = await Self.waitUntil(timeout: 15) { await recorder.remoteClipboard.contains(expected) }
        let all = await recorder.remoteClipboard
        #expect(received, "받은 원격 클립보드: \(all)")
        print("RDP-CLIP remote→local \(received ? "ok" : "missing") \(all)")
    }

    /// 진단용: 임의의 서버에 연결해 이벤트와 FreeRDP 로그를 남긴다.
    /// WITH SHELL_DIAG_RDP_HOST / _USER / _PASSWORD 환경 변수가 있을 때만 실행된다.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WITHSHELL_DIAG_RDP_HOST"] != nil))
    func diagnoseServer() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["WITHSHELL_DIAG_RDP_HOST"])
        let recorder = Recorder()
        let connection = Self.makeConnection(recorder, decision: .acceptOnce)
        let (domain, user) = RDPSession.splitDomain(env["WITHSHELL_DIAG_RDP_USER"] ?? "")
        #expect(connection.start(.init(
            host: host, port: Int(env["WITHSHELL_DIAG_RDP_PORT"] ?? "3389") ?? 3389,
            username: user, domain: domain, password: env["WITHSHELL_DIAG_RDP_PASSWORD"] ?? "",
            width: 1280, height: 800, desktopScale: 100, deviceScale: 100
        )))
        _ = await Self.waitUntil(timeout: 30) { await recorder.isClosedOrConnected() }
        let events = await recorder.events
        print("RDP-DIAG \(events)")
        connection.stop()
        try await Task.sleep(for: .seconds(1))
    }

    @Test(.enabled(if: Config.fromEnvironment != nil))
    func rejectedCertificateStopsConnection() async throws {
        let config = try #require(Config.fromEnvironment)
        let recorder = Recorder()
        let connection = Self.makeConnection(recorder, decision: .reject)
        #expect(connection.start(.init(
            host: config.host, port: config.port, username: config.user, domain: "", password: config.password,
            width: 1024, height: 768, desktopScale: 100, deviceScale: 100
        )))
        let failed = await Self.waitUntil(timeout: 20) { await recorder.isClosed() }
        #expect(failed)
        let connectedAnyway = await recorder.has("connected")
        #expect(!connectedAnyway)
        print("RDP-REJECT \(await recorder.events)")
        connection.stop()
    }

    @Test(.enabled(if: Config.fromEnvironment != nil))
    func unreachablePortFails() async throws {
        let recorder = Recorder()
        let connection = Self.makeConnection(recorder, decision: .reject)
        #expect(connection.start(.init(
            host: "127.0.0.1", port: 1, username: "x", domain: "", password: "x",
            width: 1024, height: 768, desktopScale: 100, deviceScale: 100
        )))
        let failed = await Self.waitUntil(timeout: 20) { await recorder.has("failed") }
        let unreachableEvents = await recorder.events
        #expect(failed, "\(unreachableEvents)")
        print("RDP-UNREACHABLE \(await recorder.events)")
        connection.stop()
    }

    @Test func domainSplitting() {
        #expect(RDPSession.splitDomain("CORP\\alice") == ("CORP", "alice"))
        #expect(RDPSession.splitDomain("alice@corp.example") == ("", "alice@corp.example"))
        #expect(RDPSession.scaleFactors(for: 2) == (200, 180))
        #expect(RDPSession.scaleFactors(for: 1) == (100, 100))

        // 도메인 칸이 우선, 비어 있으면 DOMAIN\\user 에서 분리
        #expect(RDPSession.resolveCredentials(username: "alice", domain: "CORP") == ("alice", "CORP"))
        #expect(RDPSession.resolveCredentials(username: "OLD\\alice", domain: "CORP") == ("alice", "CORP"))
        #expect(RDPSession.resolveCredentials(username: "OLD\\alice", domain: " ") == ("alice", "OLD"))
        #expect(RDPSession.resolveCredentials(username: " alice@corp.example ", domain: "") == ("alice@corp.example", ""))
    }

    @Test func passwordFieldAcceptsOnlyASCII() {
        #expect(PasswordField.filter("Passw0rd!@#") == "Passw0rd!@#")
        #expect(PasswordField.filter("ㅔㅁㄴㄴ한글abc") == "abc")
        #expect(PasswordField.filter("a b~") == "a b~")
        #expect(PasswordField.filter("é✓\n\t1") == "1")
    }

    static func save(_ image: CGImage, name: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("RDP-IMAGE \(url.path)")
    }

    static func distinctColors(in image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var colors = Set<UInt32>()
        let stride = image.bytesPerRow
        for y in Swift.stride(from: 0, to: image.height, by: 37) {
            for x in Swift.stride(from: 0, to: image.width, by: 41) {
                let p = bytes + y * stride + x * 4
                colors.insert(UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16)
                if colors.count > 50 { return colors.count }
            }
        }
        return colors.count
    }
}
