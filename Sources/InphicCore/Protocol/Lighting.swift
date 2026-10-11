import Foundation

/// 灯效模式。固件里存 `index << 4`。
public enum LightMode: UInt8, CaseIterable, Sendable, Codable {
    case off = 0x0
    case staticColor = 0x1
    case breathing = 0x2
    case neon = 0x3
    case cycleBreathing = 0x4
    case staticDPI = 0x5
    case breathingDPI = 0x6

    public var title: String {
        switch self {
        case .off: "关闭"
        case .staticColor: "常亮"
        case .breathing: "呼吸"
        case .neon: "霓虹"
        case .cycleBreathing: "循环呼吸"
        case .staticDPI: "DPI 常亮"
        case .breathingDPI: "DPI 呼吸"
        }
    }

    /// 高半字节存放模式。
    public var nibble: UInt8 { rawValue << 4 }
}

/// 灯光 + 电源 + 去抖。固件把三组设置合并在同一条命令里，
/// 改其中任意一项都必须带上其余项的当前值。
///
/// ```text
/// [0]  0x05
/// [1]  15                  载荷长度
/// [2]  profileId
/// [3]  mode << 4
/// [4]  (deepSleepHigh << 4) | (9 - speed)
/// [5]  (deepSleepLow  << 4) | brightness
/// [6]  R   [7] G   [8] B
/// [9]  浅睡分钟 × 2
/// [10] 按键响应时间 ms
/// [11..12] 校验和（覆盖 [3..<11]）
/// [13..14] 保留 0
/// ```
public struct LightingConfiguration: Equatable, Sendable, Codable {
    public var profileId: UInt8
    public var mode: LightMode
    /// 灯效速度 1–8，固件存 `9 - speed`。
    public var speed: Int
    /// 亮度 1–8。
    public var brightness: Int
    public var color: RGB
    /// 浅睡超时，分钟 0.5–30，固件存 `minutes × 2`。
    public var lightSleepMinutes: Double
    /// 深度休眠，分钟 1–60。
    public var deepSleepMinutes: Int
    /// 按键去抖（响应时间），毫秒。IN10 出厂值 3。
    public var debounceMilliseconds: Int

    /// 出厂值取自官方 HUB 在全新 IN10 上发出的启动 profile
    /// `05 0F 01 30 03 58 00 00 FF 01 03 …`（霓虹、蓝色、亮度 8、速度 6、浅睡 0.5 分钟、
    /// 深睡 5 分钟、响应 3ms）。
    public init(
        profileId: UInt8 = 1,
        mode: LightMode = .neon,
        speed: Int = 6,
        brightness: Int = 8,
        color: RGB = RGB(0x00, 0x00, 0xFF),
        lightSleepMinutes: Double = 0.5,
        deepSleepMinutes: Int = 5,
        debounceMilliseconds: Int = 3
    ) {
        self.profileId = profileId
        self.mode = mode
        self.speed = min(max(speed, 1), 8)
        self.brightness = min(max(brightness, 1), 8)
        self.color = color
        self.lightSleepMinutes = min(max(lightSleepMinutes, 0.5), 30)
        self.deepSleepMinutes = min(max(deepSleepMinutes, 1), 60)
        self.debounceMilliseconds = min(max(debounceMilliseconds, 1), 50)
    }

    public func payload() -> [UInt8] {
        let sleepHigh = UInt8((deepSleepMinutes >> 4) & 0x0F)
        let sleepLow = UInt8(deepSleepMinutes & 0x0F)

        var payload = [UInt8](repeating: 0, count: 15)
        payload[0] = CommandType.lighting.rawValue
        payload[1] = 15
        payload[2] = profileId
        payload[3] = mode.nibble
        payload[4] = (sleepHigh << 4) | UInt8(9 - speed)
        payload[5] = (sleepLow << 4) | UInt8(brightness)
        payload[6] = color.red
        payload[7] = color.green
        payload[8] = color.blue
        payload[9] = UInt8((lightSleepMinutes * 2).rounded()) & 0xFF
        payload[10] = UInt8(debounceMilliseconds)
        payload.writeChecksum16(at: 11, over: 3..<11)
        return payload
    }

    /// 从载荷还原，用于读回或抓包比对。
    public init?(payload: [UInt8]) {
        guard payload.count >= 15, payload[0] == CommandType.lighting.rawValue else { return nil }
        let speedByte = payload[4]
        let brightnessByte = payload[5]
        self.init(
            profileId: payload[2],
            mode: LightMode(rawValue: payload[3] >> 4) ?? .off,
            speed: 9 - Int(speedByte & 0x0F),
            brightness: Int(brightnessByte & 0x0F),
            color: RGB(payload[6], payload[7], payload[8]),
            lightSleepMinutes: Double(payload[9]) / 2,
            deepSleepMinutes: Int(speedByte >> 4) << 4 | Int(brightnessByte >> 4),
            debounceMilliseconds: Int(payload[10])
        )
    }
}

/// 轮询率 / 性能命令（`CommandType.parameter`，载荷 9 字节）。
///
/// ```text
/// [0] 0x06   [1] 9   [2] profileId
/// [3] raw      [4] ~raw      [5..8] 0
/// ```
public enum PollingRate: Int, CaseIterable, Sendable, Codable {
    case hz125 = 125, hz250 = 250, hz500 = 500
    case hz1000 = 1000, hz2000 = 2000, hz4000 = 4000, hz8000 = 8000

    /// 固件里的编码。注意不是单调的 —— 8000Hz 反而是 64。
    public var firmwareValue: UInt8 {
        switch self {
        case .hz125: 32
        case .hz250: 16
        case .hz500: 8
        case .hz1000: 4
        case .hz2000: 2
        case .hz4000: 1
        case .hz8000: 64
        }
    }

    public init?(firmwareValue: UInt8) {
        guard let match = Self.allCases.first(where: { $0.firmwareValue == firmwareValue }) else { return nil }
        self = match
    }
}

public struct ParameterCommand: Equatable, Sendable, Codable {
    public var profileId: UInt8
    public var pollingRate: PollingRate

    public init(profileId: UInt8 = 1, pollingRate: PollingRate = .hz1000) {
        self.profileId = profileId
        self.pollingRate = pollingRate
    }

    public func payload() -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 9)
        payload[0] = CommandType.parameter.rawValue
        payload[1] = 9
        payload[2] = profileId
        payload[3] = pollingRate.firmwareValue
        payload[4] = ~pollingRate.firmwareValue
        return payload
    }
}
