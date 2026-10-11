import Foundation

/// 8 位 RGB 颜色。固件按 R,G,B 顺序存。
public struct RGB: Equatable, Hashable, Sendable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = RGB(255, 255, 255)
    public static let black = RGB(0, 0, 0)

    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// 解析 `#RRGGBB`，非法返回 nil。
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
}
