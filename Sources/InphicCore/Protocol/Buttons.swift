import Foundation

/// 一个按键绑定的 3 字节动作：`[类型, v1, v2]`。
public struct ButtonAction: Equatable, Sendable, Codable {
    public enum Kind: UInt8, Sendable, Codable {
        case off = 1
        case leftClick = 2
        case rightClick = 3
        case middleClick = 4
        case backward = 5
        case forward = 6
        case doubleClick = 7
        case fire = 8
        case scrollDown = 9
        case scrollUp = 10
        case tiltLeft = 11
        case tiltRight = 12
        case dpiCycle = 13
        case dpiUp = 14
        case dpiDown = 15
        case easyAim = 16
        /// `[17, 修饰键掩码, HID usage]`
        case shortcut = 17
        /// `[18, 0, 宏编号]`
        case macro = 18
        case mediaPlay = 21
        case mediaPrevious = 22
        case mediaNext = 23
        case mediaPlayPause = 24
        case mediaStop = 25
        case mute = 26
        case volumeUp = 27
        case volumeDown = 28
        case calculator = 29
        case email = 30
        case browserForward = 32
        case browserBack = 33
        case browserRefresh = 36
        case browserHome = 37
        case browserSearch = 38
        case profileCycle = 52
        case profileUp = 53
        case profileDown = 54
        case modeKey = 60
    }

    public var kind: Kind
    public var modifier: UInt8
    public var argument: UInt8

    public init(kind: Kind, modifier: UInt8 = 0, argument: UInt8 = 0) {
        self.kind = kind
        self.modifier = modifier
        self.argument = argument
    }

    public static let disabled = ButtonAction(kind: .off)

    public var bytes: [UInt8] { [kind.rawValue, modifier, argument] }
}

/// IN10 固件里的 18 个按键槽位。
///
/// 前 5 个（左/右/中/前/后）可以在官方 Web UI 自定义，其余保持出厂值。
public enum ButtonSlot: Int, CaseIterable, Sendable, Identifiable {
    case leftClick = 0
    case rightClick = 1
    case middleClick = 2
    case dpiCycle = 3
    case dpiUp = 4
    case dpiDown = 5
    case backward = 6
    case forward = 7
    case modeKey = 8
    case spare1 = 9, spare2 = 10, spare3 = 11, spare4 = 12, spare5 = 13, spare6 = 14, spare7 = 15
    case scrollDown = 16
    case scrollUp = 17

    /// 官方 UI 允许用户改的物理按键。
    public static let userEditable: [ButtonSlot] = [
        .leftClick, .rightClick, .middleClick, .forward, .backward,
    ]

    public var title: String {
        switch self {
        case .leftClick: "左键"
        case .rightClick: "右键"
        case .middleClick: "中键"
        case .dpiCycle: "DPI 循环键"
        case .dpiUp: "DPI 加"
        case .dpiDown: "DPI 减"
        case .backward: "后退"
        case .forward: "前进"
        case .modeKey: "模式键"
        case .scrollDown: "滚轮下"
        case .scrollUp: "滚轮上"
        default: "保留 \(rawValue - 8)"
        }
    }

    public var id: Int { rawValue }

    public var isUserEditable: Bool { Self.userEditable.contains(self) }

    /// 出厂动作。
    public var factoryAction: ButtonAction {
        switch self {
        case .leftClick: .init(kind: .leftClick)
        case .rightClick: .init(kind: .rightClick)
        case .middleClick: .init(kind: .middleClick)
        case .backward: .init(kind: .backward)
        case .forward: .init(kind: .forward)
        case .dpiCycle: .init(kind: .dpiCycle)
        case .dpiUp: .init(kind: .dpiUp)
        case .dpiDown: .init(kind: .dpiDown)
        case .scrollDown: .init(kind: .scrollDown)
        case .scrollUp: .init(kind: .scrollUp)
        case .modeKey: .init(kind: .modeKey)
        default: .disabled
        }
    }
}

/// 按键映射命令（`CommandType.buttons`，载荷 59 字节）。
public struct ButtonConfiguration: Equatable, Sendable, Codable {
    public static let slotCount = ButtonSlot.allCases.count

    public var profileId: UInt8
    public private(set) var actions: [ButtonAction]

    public init(profileId: UInt8 = 1, actions: [ButtonAction]? = nil) {
        self.profileId = profileId
        self.actions = actions ?? ButtonSlot.allCases.map(\.factoryAction)
    }

    public subscript(slot: ButtonSlot) -> ButtonAction {
        get { actions[slot.rawValue] }
        set { actions[slot.rawValue] = newValue }
    }

    /// 恢复出厂按键映射。
    public mutating func resetToFactory() {
        actions = ButtonSlot.allCases.map(\.factoryAction)
    }

    public func payload() -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 3 + Self.slotCount * 3 + 2)
        payload[0] = CommandType.buttons.rawValue
        payload[1] = 59
        payload[2] = profileId
        for (index, action) in actions.enumerated() {
            let base = 3 + index * 3
            payload[base] = action.kind.rawValue
            payload[base + 1] = action.modifier
            payload[base + 2] = action.argument
        }
        payload.writeChecksum16(at: 3 + Self.slotCount * 3, over: 3..<(3 + Self.slotCount * 3))
        return payload
    }
}
