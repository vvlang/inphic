import Foundation

/// IN10 的 DPI 相关取值范围。
public enum DPILimit {
    public static let minimum = 50
    public static let maximum = 30_000
    /// 固件固定的档位数。
    public static let stageCount = 8
}

/// 一档 DPI 设置。
public struct DPIStage: Equatable, Sendable, Codable {
    public var value: Int
    public var isEnabled: Bool
    public var color: RGB

    public init(value: Int, isEnabled: Bool = true, color: RGB = .white) {
        self.value = value
        self.isEnabled = isEnabled
        self.color = color
    }
}

/// 官方固件的默认档位指示色。
public enum DPIDefaultColors {
    public static let palette: [RGB] = [
        RGB(255, 255, 0),   // 黄
        RGB(0, 255, 255),   // 青
        RGB(0, 255, 0),     // 绿
        RGB(255, 0, 255),   // 品红
        RGB(0, 0, 255),     // 蓝
        RGB(255, 0, 0),     // 红
        RGB(255, 64, 0),    // 橙
        RGB(255, 255, 255), // 白
    ]
}

/// DPI 命令（`CommandType.dpi`，载荷 56 字节）。
///
/// ```text
/// [0]      0x04
/// [1]      56          载荷长度
/// [2]      profileId
/// [3]      liftOffDistance   0 = 1mm, 1 = 2mm
/// [4]      ripple           涟漪控制
/// [5]      enabledMask      启用档位位掩码
/// [6]      angleSnap        角度吸附
/// [7]      motionSync       Motion Sync
/// [8..23]  8 档 DPI，小端 uint16（低字节在前，高字节在后）
/// [24]     activeStage      当前档位，1–8
/// [25..48] 8 档指示色 RGB
/// [49]     indicationType
/// [50..51] 校验和（覆盖 [3..<50]）
/// ```
public struct DPIConfiguration: Equatable, Sendable, Codable {
    public var profileId: UInt8
    public var liftOffDistance: UInt8
    public var ripple: Bool
    public var angleSnap: Bool
    public var motionSync: Bool
    public var activeStage: Int
    public var stages: [DPIStage]
    public var indicationType: UInt8

    public init(
        profileId: UInt8 = 1,
        liftOffDistance: UInt8 = 0,
        ripple: Bool = true,
        angleSnap: Bool = false,
        motionSync: Bool = false,
        activeStage: Int = 1,
        stages: [DPIStage]? = nil,
        indicationType: UInt8 = 1
    ) {
        self.profileId = profileId
        self.liftOffDistance = liftOffDistance
        self.ripple = ripple
        self.angleSnap = angleSnap
        self.motionSync = motionSync
        self.activeStage = activeStage
        self.indicationType = indicationType

        let fallback = DPIDefaultColors.palette.enumerated().map { index, color in
            DPIStage(value: Self.defaultValue(forStage: index), color: color)
        }
        let resolved = stages ?? fallback
        let padded = resolved + [DPIStage](repeating: DPIStage(value: 0, isEnabled: false), count: DPILimit.stageCount)
        self.stages = Array(padded.prefix(DPILimit.stageCount))
    }

    /// IN10 官方出厂档位：800 / 1600 / 3200 / 6500 / 13000 / 30000 …
    static func defaultValue(forStage index: Int) -> Int {
        let values = [800, 1600, 3200, 6500, 13_000, 30_000, 30_000, 30_000]
        return index < values.count ? values[index] : DPILimit.minimum
    }

    /// 启用档位的位掩码（每档占 1 位）。
    public var enabledMask: UInt8 {
        stages.enumerated().reduce(into: UInt8(0)) { mask, entry in
            if entry.element.isEnabled { mask |= 1 << UInt8(entry.offset) }
        }
    }

    /// 固件 DPI 编码：`raw = (dpi - 50) / 50`，小端 uint16。
    public static func encodeValue(_ dpi: Int) -> (low: UInt8, high: UInt8) {
        guard dpi > DPILimit.minimum else { return (0, 0) }
        let raw = UInt32((dpi - DPILimit.minimum) / 50)
        return (UInt8(truncatingIfNeeded: raw), UInt8(truncatingIfNeeded: raw >> 8))
    }

    /// 固件侧的反函数：50 + 50 × raw。原始值 0 也解成 50，与官方 `GetDPIValueByMouseDPI` 一致。
    public static func decodeValue(low: UInt8, high: UInt8) -> Int {
        let raw = UInt32(low) | UInt32(high) << 8
        return DPILimit.minimum + Int(raw) * 50
    }

    public func payload() -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 56)
        payload[0] = CommandType.dpi.rawValue
        payload[1] = 56
        payload[2] = profileId
        payload[3] = liftOffDistance
        payload[4] = ripple ? 1 : 0
        payload[5] = enabledMask
        payload[6] = angleSnap ? 1 : 0
        payload[7] = motionSync ? 1 : 0

        for index in 0..<DPILimit.stageCount {
            let (low, high) = Self.encodeValue(stages[index].value)
            payload[8 + index] = low
            payload[16 + index] = high
        }

        payload[24] = UInt8(clamping: activeStage)
        for index in 0..<DPILimit.stageCount {
            payload[25 + 3 * index] = stages[index].color.red
            payload[26 + 3 * index] = stages[index].color.green
            payload[27 + 3 * index] = stages[index].color.blue
        }

        payload[49] = indicationType
        payload.writeChecksum16(at: 50, over: 3..<50)
        return payload
    }
}
