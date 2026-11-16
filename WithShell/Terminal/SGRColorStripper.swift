import Foundation

/// 서버 출력에서 색 지정(SGR 색 코드)만 지워, 모든 글자를 기본 전경색으로 보이게 한다.
/// 굵게·밑줄·반전 같은 다른 속성과 커서 이동 등 나머지 제어 문자열은 그대로 둔다.
/// 출력이 여러 조각으로 나뉘어 와도 이어서 처리할 수 있도록 미완성 시퀀스를 기억한다.
struct SGRColorStripper {
    private enum State {
        case normal
        case escape          // ESC 받음
        case csi             // ESC [ … 수집 중
    }

    private var state = State.normal
    private var pending: [UInt8] = []

    private static let esc: UInt8 = 0x1B
    private static let maxSequenceLength = 128

    mutating func process(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)

        for byte in input {
            switch state {
            case .normal:
                if byte == Self.esc {
                    state = .escape
                    pending = [byte]
                } else {
                    output.append(byte)
                }

            case .escape:
                pending.append(byte)
                if byte == UInt8(ascii: "[") {
                    state = .csi
                } else {
                    // CSI 가 아닌 이스케이프는 그대로 내보낸다
                    output.append(contentsOf: pending)
                    pending.removeAll()
                    state = .normal
                }

            case .csi:
                pending.append(byte)
                if (0x40...0x7E).contains(byte) {
                    // 최종 바이트
                    if byte == UInt8(ascii: "m") {
                        output.append(contentsOf: Self.rewriteSGR(pending))
                    } else {
                        output.append(contentsOf: pending)
                    }
                    pending.removeAll()
                    state = .normal
                } else if pending.count > Self.maxSequenceLength {
                    output.append(contentsOf: pending)
                    pending.removeAll()
                    state = .normal
                }
            }
        }
        return output
    }

    /// `ESC [ params m` 에서 색 관련 파라미터를 뺀다. 남는 것이 없으면 시퀀스 자체를 없앤다.
    static func rewriteSGR(_ sequence: [UInt8]) -> [UInt8] {
        let body = sequence.dropFirst(2).dropLast()           // ESC [ 와 m 제외
        // 비공개 시퀀스(ESC [ ? …, ESC [ > … m)는 건드리지 않는다
        if let first = body.first, (0x3C...0x3F).contains(first) { return sequence }
        let text = String(decoding: body, as: UTF8.self)
        if text.isEmpty { return sequence }                    // ESC [ m = 전체 초기화

        let params = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < params.count {
            let param = params[index]
            // 콜론 형식(38:2::r:g:b)은 한 파라미터 안에 들어 있다
            if param.hasPrefix("38:") || param.hasPrefix("48:") || param.hasPrefix("58:") {
                index += 1
                continue
            }
            let code = Int(param) ?? 0
            switch code {
            case 38, 48, 58:
                // 38;5;n 또는 38;2;r;g;b
                let mode = index + 1 < params.count ? Int(params[index + 1]) : nil
                index += mode == 5 ? 3 : (mode == 2 ? 5 : 1)
                continue
            case 30...37, 39, 40...47, 49, 59, 90...97, 100...107:
                index += 1
                continue
            default:
                kept.append(param.isEmpty ? "0" : param)
            }
            index += 1
        }

        if kept.isEmpty { return [] }
        return Array("\u{1B}[\(kept.joined(separator: ";"))m".utf8)
    }
}
