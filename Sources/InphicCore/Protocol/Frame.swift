import Foundation

/// 命令类型（payload 的第 0 字节）。
///
/// 由官方 `WebDriver For Mac` 的 `sendDataToFW:linkedType:deviceID:`
/// 反汇编确认（分派链对 `data[0]` 做 cmp/b.eq），共 7 个，其余一律丢弃。
public enum CommandType: UInt8, CaseIterable, Sendable {
    case dpi = 0x04
    case lighting = 0x05
    case parameter = 0x06
    case wirelessSetting = 0x07
    case buttons = 0x08
    case macro = 0x09
    case profileID = 0x0C
}

/// 英菲克 SDKT 系厂商 HID 通道的输出报告封装。
///
/// ```text
/// [0]   0x04        Report ID
/// [1]   payload.count + 5      整帧长度
/// [2]   0x00        保留
/// [3…]  payload      payload[0] = CommandType
/// [n+3] 校验和高字节  sum(bytes[0..<n+3]) & 0xFFFF
/// [n+4] 校验和低字节
/// 其余补零至设备报告长度
/// ```
public enum Frame {
    /// 厂商 Output Report 的报告 ID。
    public static let reportID: UInt8 = 0x04

    /// IN10 厂商接口的报告长度。不同固件报 64 或 65，运行时以
    /// `kIOHIDReportSizeOutputReport` 为准，这里取两者较大值作为兜底。
    public static let fallbackReportLength = 65

    /// 把命令载荷封装成一条输出报告。
    public static func encode(payload: [UInt8], reportLength: Int = fallbackReportLength) -> Data {
        precondition(!payload.isEmpty, "命令载荷不能为空")

        let length = payload.count + 5
        var frame = [UInt8](repeating: 0, count: length)
        frame[0] = reportID
        frame[1] = UInt8(length)
        frame[2] = 0x00
        for (offset, byte) in payload.enumerated() {
            frame[3 + offset] = byte
        }
        frame.writeChecksum16(at: payload.count + 3, over: 0..<(payload.count + 3))

        return pad(frame, to: max(reportLength, length))
    }

    /// 补零到固定长度。设备按固定长度收，不足会拒收。
    public static func pad(_ bytes: [UInt8], to length: Int) -> Data {
        precondition(bytes.count <= length, "帧 \(bytes.count) 字节超出报告长度 \(length)")
        return Data(bytes + [UInt8](repeating: 0, count: length - bytes.count))
    }

    /// 从原始报告中剥离外层封装，还原命令载荷。校验不符返回 nil。
    public static func decode(_ report: Data, expectedReportID: UInt8 = reportID) -> [UInt8]? {
        let bytes = [UInt8](report)
        guard bytes.count >= 5, bytes[0] == expectedReportID else { return nil }
        let length = Int(bytes[1])
        guard length >= 5, length <= bytes.count else { return nil }

        let payloadEnd = length - 5
        guard payloadEnd > 0 else { return nil }
        let payload = Array(bytes[3..<(3 + payloadEnd)])

        let expected = Checksum.sum16(bytes, in: 0..<(length - 2))
        guard UInt16(bytes[length - 2]) << 8 | UInt16(bytes[length - 1]) == expected else { return nil }
        return payload
    }
}
