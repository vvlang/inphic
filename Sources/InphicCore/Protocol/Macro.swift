import Foundation

/// 宏里的一步动作。每一步都带一个「动作前的延时」，固件把它编码进事件流。
public enum MacroAction: Equatable, Sendable, Codable {
    /// 键盘按键。`usage` 是 HID Keyboard/Keypad page (0x07) 的 usage id。
    /// `delay` 是本次动作前的等待毫秒数。
    case key(usage: UInt8, pressed: Bool, delay: Int)
    /// 相对移动。
    case move(dx: Int16, dy: Int16, delay: Int)
    /// 纯等待。
    case wait(milliseconds: Int)

    /// 录制时的默认延时（毫秒）。
    public static let defaultDelay = 10

    public var delayMilliseconds: Int {
        switch self {
        case let .key(_, _, delay): delay
        case let .move(_, _, delay): delay
        case let .wait(milliseconds): milliseconds
        }
    }

    public static func keyDown(_ usage: UInt8, delay: Int = defaultDelay) -> Self {
        .key(usage: usage, pressed: true, delay: delay)
    }

    public static func keyUp(_ usage: UInt8, delay: Int = defaultDelay) -> Self {
        .key(usage: usage, pressed: false, delay: delay)
    }

    public static func movement(dx: Int16, dy: Int16, delay: Int = 1) -> Self {
        .move(dx: dx, dy: dy, delay: delay)
    }
}

/// 宏触发方式。
public enum MacroTrigger: UInt8, Sendable, Codable, CaseIterable {
    case loop = 0
    case stopOnAnyKey = 1
    case playWhileHeld = 2
    case stopWithButton = 3

    public var title: String {
        switch self {
        case .loop: "循环播放"
        case .stopOnAnyKey: "任意键停止"
        case .playWhileHeld: "按住播放，松开停止"
        case .stopWithButton: "宏键停止"
        }
    }
}

/// 一条宏。`id` 从 1 开始，与按键映射里的 `argument` 对应。
public struct Macro: Equatable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var trigger: MacroTrigger
    /// `trigger == .loop` 时生效，1–255。
    public var loops: Int
    public var actions: [MacroAction]
    public var color: RGB

    public init(
        id: Int,
        name: String? = nil,
        trigger: MacroTrigger = .loop,
        loops: Int = 1,
        actions: [MacroAction] = [],
        color: RGB = .black
    ) {
        self.id = id
        self.name = name ?? "宏 \(id)"
        self.trigger = trigger
        self.loops = loops
        self.actions = actions
        self.color = color
    }
}

/// HID 修饰键掩码。
public struct HIDModifiers: OptionSet, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = HIDModifiers(rawValue: 0x01)
    public static let shift = HIDModifiers(rawValue: 0x02)
    public static let alternate = HIDModifiers(rawValue: 0x04)
    public static let gui = HIDModifiers(rawValue: 0x08)
}

/// 宏命令（`CommandType.macro`，载荷 111 字节）。
///
/// ```text
/// [0]  0x09   [1] 111(0x6F)   ← 官方反汇编以 data[1] == 0x6F 判定「整条下发」
/// [2]  macroId(1 起)  [3] trigger  [4..6] RGB  [7] loops  [8] eventCount
/// [9…] 事件流
/// [109..110] 校验和（覆盖 [3..<109]）
/// ```
public struct MacroCommand: Equatable, Sendable {
    public static let payloadLength = 111
    /// 载荷第 1 字节，也是固件用来区分「整条」与「分片」的魔数。
    public static let sizeByte: UInt8 = 0x6F
    /// 事件流可用空间：载荷 [9..<109]。
    public static let maxEventBytes = 100

    public var macro: Macro

    public init(macro: Macro) {
        self.macro = macro
    }

    public func payload() throws -> [UInt8] {
        let (data, count) = try Self.encodeActions(macro.actions)
        guard data.count <= Self.maxEventBytes else {
            throw MacroError.tooManyActions(byteCount: data.count)
        }

        var payload = [UInt8](repeating: 0, count: Self.payloadLength)
        payload[0] = CommandType.macro.rawValue
        payload[1] = Self.sizeByte
        payload[2] = UInt8(clamping: macro.id)
        payload[3] = macro.trigger.rawValue
        payload[4] = macro.color.red
        payload[5] = macro.color.green
        payload[6] = macro.color.blue
        payload[7] = UInt8(clamping: max(1, macro.loops))
        payload[8] = UInt8(clamping: count)
        for (offset, byte) in data.enumerated() {
            payload[9 + offset] = byte
        }
        payload.writeChecksum16(at: 109, over: 3..<109)
        return payload
    }

    /// 把动作列表编码成事件流，返回 (字节, 事件计数)。
    ///
    /// - 按键：`[delay | 0x01, usage]` 按下 / `[delay | 0x80, usage]` 抬起
    /// - 移动：`[delay, 0xF6, x_hi, x_lo, y_hi, y_lo]`
    /// - 延时 > 127ms：延时字节改用 `delay % 100`，并追加 `[delay / 100, 0x03]`
    public static func encodeActions(_ actions: [MacroAction]) throws -> (data: [UInt8], count: Int) {
        var out = [UInt8]()
        var count = 0

        for action in actions {
            let delay = split(min(max(action.delayMilliseconds, 1), 25_500))

            switch action {
            case let .key(usage, pressed, _):
                out.append(delay.byte | (pressed ? 0x01 : 0x80))
                out.append(usage)
                count += 1
                if delay.isLong {
                    out.append(delay.group)
                    out.append(0x03)
                    count += 1
                }
            case let .move(dx, dy, _):
                out.append(delay.byte)
                out.append(0xF6)
                out.append(UInt8(truncatingIfNeeded: dx >> 8))
                out.append(UInt8(truncatingIfNeeded: dx))
                out.append(UInt8(truncatingIfNeeded: dy >> 8))
                out.append(UInt8(truncatingIfNeeded: dy))
                count += 3
                if delay.isLong {
                    out.append(delay.group)
                    out.append(0x03)
                    count += 1
                }
            case .wait:
                out.append(delay.byte)
                out.append(0x03)
                count += 1
                if delay.isLong {
                    out.append(delay.group)
                    out.append(0x03)
                    count += 1
                }
            }

            guard out.count <= maxEventBytes else {
                throw MacroError.tooManyActions(byteCount: out.count)
            }
        }
        return (out, count)
    }

    /// 长延时拆成「延时字节 + 追加的组数」。
    private static func split(_ delay: Int) -> (byte: UInt8, group: UInt8, isLong: Bool) {
        guard delay > 127 else { return (UInt8(delay), 0, false) }
        return (UInt8(max(1, delay % 100)), UInt8(clamping: delay / 100), true)
    }

    public enum MacroError: LocalizedError, Equatable {
        case tooManyActions(byteCount: Int)

        public var errorDescription: String? {
            switch self {
            case let .tooManyActions(bytes):
                "宏内容过长（\(bytes) 字节），固件单条宏最多 \(maxEventBytes) 字节"
            }
        }
    }
}
