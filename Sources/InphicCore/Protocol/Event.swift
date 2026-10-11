import Foundation

/// 鼠标上行事件。
public enum MouseEvent: Equatable, Sendable {
    /// 写入确认。
    case acknowledgement(isSuccess: Bool)
    /// 电量上报。
    case battery(status: BatteryStatus, level: Int)
    /// 用户按下了 DPI 循环键。
    case dpiStageChanged(Int)
    /// 震动马达触发。
    case vibration(Int)
    /// 用户切换了配置档。
    case profileChanged(Int)
    /// 已识别但尚未归类的厂商事件。
    case vendor(code: UInt8, p1: UInt8, p2: UInt8)
    /// 无法解析的原始包，保留下来便于抓包排查。
    case unparsed(Data)

    public enum BatteryStatus: UInt8, Sendable {
        case normal = 1, full = 2, charging = 3
    }

    /// 事件码，与官方 `parse_event` 一致。
    enum Code: UInt8 {
        case dpiCycle = 0x10
        case vibration = 0x11
        case battery = 0x40
        case batteryAlt = 0x41
        case acknowledgement = 0x50
        case profile = 0x80
    }

    /// 合法的事件码集合，用于从不同链路的偏移噪声里定位事件字节。
    static let codes: Set<UInt8> = [
        Code.dpiCycle.rawValue, Code.vibration.rawValue,
        Code.battery.rawValue, Code.batteryAlt.rawValue,
        Code.acknowledgement.rawValue, Code.profile.rawValue,
    ]

    /// 命令码白名单，用于校验 ACK 事件里的参数。
    static let commandCodes: Set<UInt8> = [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]
}

/// 解析厂商接口的输入报告。
///
/// 两种已知形态：
/// 1. 写入确认 `06 C0|C1 <status> 00 <csum8>`，校验和 = `(4 + sum(bytes[0..<4])) & 0xFF`
/// 2. 事件包 `03 <deviceId> <code> <p1> <p2>`（部分链路前面会多出 1–2 字节，故按偏移 2/3/4 依次探测）
public enum EventParser {
    public static func parse(_ report: Data) -> MouseEvent {
        let bytes = [UInt8](report)
        guard bytes.count >= 5 else { return .unparsed(report) }

        if let event = parseAcknowledgement(bytes) { return event }
        if let event = parseEventPacket(bytes) { return event }
        return .unparsed(report)
    }

    static func parseAcknowledgement(_ bytes: [UInt8]) -> MouseEvent? {
        guard bytes[0] == 0x06, (0xC0...0xC3).contains(bytes[1]) else { return nil }
        guard bytes[2] == 0x00 || bytes[2] == 0x01 else { return nil }
        guard (4 &+ Checksum.sum8(bytes, in: 0..<4)) == bytes[4] else { return nil }
        return .acknowledgement(isSuccess: bytes[2] == 0x01)
    }

    static func parseEventPacket(_ bytes: [UInt8]) -> MouseEvent? {
        for offset in 2...4 {
            guard bytes.count >= offset + 3 else { continue }
            let code = bytes[offset]
            guard MouseEvent.codes.contains(code) else { continue }
            let p1 = bytes[offset + 1]
            let p2 = bytes[offset + 2]

            switch MouseEvent.Code(rawValue: code) {
            case .battery, .batteryAlt:
                // 电量：状态 1–3，百分比 0–100。两者必须都在合法区间才算命中。
                guard (1...3).contains(p1), p2 <= 100 else { continue }
                return .battery(status: MouseEvent.BatteryStatus(rawValue: p1) ?? .normal, level: Int(p2))

            case .acknowledgement:
                guard p1 == 0 || p1 == 1, MouseEvent.commandCodes.contains(p2) else { continue }
                return .acknowledgement(isSuccess: p1 == 0)

            case .dpiCycle:
                guard (1...8).contains(p1) else { continue }
                return .dpiStageChanged(Int(p1))

            case .vibration:
                return .vibration(Int(p1))

            case .profile:
                return .profileChanged(Int(p1))

            case nil:
                continue
            }
        }
        return nil
    }
}
