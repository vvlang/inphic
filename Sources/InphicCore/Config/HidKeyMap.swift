import Foundation

/// HID Keyboard/Keypad page (0x07) 的常用 usage，供组合键与宏的 UI 选。
public enum HidKey: UInt8, CaseIterable, Identifiable, Sendable {
    case a = 0x04, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case one = 0x1E, two, three, four, five, six, seven, eight, nine, zero
    case enter = 0x28, escape, backspace, tab, space
    case minus = 0x2D, equal, leftBracket, rightBracket, backslash
    case semicolon, quote, grave, comma, period, slash
    case capsLock = 0x39
    case f1 = 0x3A, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case printScreen = 0x46, scrollLock, pause, insert, home, pageUp
    case delete, end, pageDown
    case right = 0x4F, left, down, up

    public var id: UInt8 { rawValue }

    public var title: String {
        switch self {
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        case .zero: "0"
        case .enter: "↩ 回车"
        case .escape: "⎋ 退出"
        case .backspace: "⌫ 退格"
        case .tab: "⇥ Tab"
        case .space: "空格"
        case .capsLock: "⇪ Caps"
        case .right: "→"
        case .left: "←"
        case .down: "↓"
        case .up: "↑"
        default: String(describing: self).uppercased()
        }
    }
}

/// 按钮动作的本地化描述，给 UI 用。
public extension ButtonAction.Kind {
    /// 是否会占用 `argument`（宏号 / HID usage）。
    var takesArgument: Bool {
        self == .shortcut || self == .macro
    }
}

/// UI 分组，方便弹出菜单按语义排序。
public enum ButtonActionGroup: String, CaseIterable, Identifiable {
    case mouse = "鼠标"
    case scroll = "滚轮与倾斜"
    case dpi = "DPI"
    case media = "多媒体"
    case browser = "浏览器"
    case system = "系统"
    case profile = "配置档"

    public var id: String { rawValue }
}
