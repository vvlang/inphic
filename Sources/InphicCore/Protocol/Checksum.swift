import Foundation

/// 英菲克 SDKT 系固件使用的大端 16 位累加和校验。
///
/// 两种长度同时存在：
/// - 载荷内校验（payload 自带，跨命令长度不一）
/// - 外层帧校验（覆盖报告 ID、长度、保留字节和整个 payload）
public enum Checksum {
    /// `sum(bytes[range]) & 0xFFFF`
    public static func sum16(_ bytes: [UInt8], in range: Range<Int>) -> UInt16 {
        var total: UInt32 = 0
        for index in range where bytes.indices.contains(index) {
            total += UInt32(bytes[index])
        }
        return UInt16(truncatingIfNeeded: total)
    }

    /// `sum(bytes[range]) & 0xFF`
    public static func sum8(_ bytes: [UInt8], in range: Range<Int>) -> UInt8 {
        var total: UInt32 = 0
        for index in range where bytes.indices.contains(index) {
            total += UInt32(bytes[index])
        }
        return UInt8(truncatingIfNeeded: total)
    }
}

public extension Array where Element == UInt8 {
    /// 以大端两字节写入校验和。
    mutating func writeChecksum16(at offset: Int, over range: Range<Int>) {
        let value = Checksum.sum16(self, in: range)
        self[offset] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 1] = UInt8(truncatingIfNeeded: value)
    }
}

public extension Data {
    /// 便于调试的十六进制表示，例如 `04 14 00 05 0F …`
    var hexDump: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 连续十六进制转字节数组，非法字符一律忽略。
    static func parseHex(_ text: String) -> Data {
        let cleaned = text.filter { $0.isHexDigit }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let byte = UInt8(cleaned[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return Data(bytes)
    }
}
