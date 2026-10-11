//! DPI 档位命令。

/// IN10 的 DPI 取值范围与档位数。
pub mod limits {
    pub const MINIMUM: u32 = 50;
    pub const MAXIMUM: u32 = 30_000;
    /// 固件固定的档位数。
    pub const STAGE_COUNT: usize = 8;
}

/// 一档 DPI 设置。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DpiStage {
    pub value: u32,
    pub is_enabled: bool,
    pub color: crate::lighting::Rgb,
}

impl DpiStage {
    #[must_use]
    pub fn new(value: u32) -> Self {
        Self {
            value,
            is_enabled: true,
            color: crate::lighting::Rgb::new(255, 255, 255),
        }
    }

    /// IN10 官方出厂档位。
    #[must_use]
    pub fn factory(index: usize) -> Self {
        let values = [800u32, 1600, 3200, 6500, 13_000, 30_000];
        Self::new(values.get(index).copied().unwrap_or(limits::MINIMUM))
    }
}

/// DPI 命令（56 字节载荷）。
///
/// ```text
/// [0]      0x04
/// [1]      56
/// [2]      profileId
/// [3]      liftOffDistance   0 = 1mm, 1 = 2mm
/// [4]      ripple
/// [5]      enabledMask       每档占 1 位
/// [6]      angleSnap
/// [7]      motionSync
/// [8..23]  8 档 DPI，小端 uint16
/// [24]     activeStage       当前档位 1–8
/// [25..48] 8 档指示色 RGB
/// [49]     indicationType
/// [50..51] 校验和（覆盖 [3..<50]）
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DpiConfig {
    pub profile_id: u8,
    /// 0 = 1mm, 1 = 2mm
    pub lift_off_distance: u8,
    pub ripple: bool,
    pub angle_snap: bool,
    pub motion_sync: bool,
    /// 当前档位，1–8。
    pub active_stage: u8,
    pub stages: Vec<DpiStage>,
    pub indication_type: u8,
}

impl Default for DpiConfig {
    fn default() -> Self {
        let stages = (0..limits::STAGE_COUNT)
            .map(|index| DpiStage {
                color: crate::lighting::DPI_DEFAULT_COLORS[index],
                ..DpiStage::factory(index)
            })
            .collect();
        Self {
            profile_id: 1,
            lift_off_distance: 0,
            ripple: true,
            angle_snap: false,
            motion_sync: false,
            active_stage: 1,
            stages,
            indication_type: 1,
        }
    }
}

impl DpiConfig {
    /// 固件 DPI 编码：`raw = (dpi - 50) / 50`，小端 uint16。
    #[must_use]
    pub fn encode_value(dpi: u32) -> (u8, u8) {
        if dpi <= limits::MINIMUM {
            return (0, 0);
        }
        let raw = (dpi - limits::MINIMUM) / 50;
        ((raw & 0xFF) as u8, ((raw >> 8) & 0xFF) as u8)
    }

    /// 固件侧的反函数：原始值 0 也解成 50，与官方 `GetDPIValueByMouseDPI` 一致。
    #[must_use]
    pub fn decode_value(low: u8, high: u8) -> u32 {
        let raw = u32::from(low) | (u32::from(high) << 8);
        limits::MINIMUM + raw * 50
    }

    /// 启用档位的位掩码。
    #[must_use]
    pub fn enabled_mask(&self) -> u8 {
        self.stages
            .iter()
            .take(limits::STAGE_COUNT)
            .enumerate()
            .fold(0u8, |mask, (index, stage)| {
                if stage.is_enabled {
                    mask | (1 << index)
                } else {
                    mask
                }
            })
    }

    #[must_use]
    pub fn payload(&self) -> Vec<u8> {
        let mut payload = vec![0u8; 56];
        payload[0] = crate::frame::cmd::DPI;
        payload[1] = 56;
        payload[2] = self.profile_id;
        payload[3] = self.lift_off_distance;
        payload[4] = u8::from(self.ripple);
        payload[5] = self.enabled_mask();
        payload[6] = u8::from(self.angle_snap);
        payload[7] = u8::from(self.motion_sync);

        for index in 0..limits::STAGE_COUNT {
            let value = self
                .stages
                .get(index)
                .map_or(limits::MINIMUM, |stage| stage.value);
            let (low, high) = Self::encode_value(value.min(limits::MAXIMUM));
            payload[8 + index] = low;
            payload[16 + index] = high;
        }

        payload[24] = self.active_stage.clamp(1, limits::STAGE_COUNT as u8);
        for index in 0..limits::STAGE_COUNT {
            let color = self
                .stages
                .get(index)
                .map_or(crate::lighting::Rgb::new(255, 255, 255), |stage| {
                    stage.color
                });
            payload[25 + 3 * index] = color.red;
            payload[26 + 3 * index] = color.green;
            payload[27 + 3 * index] = color.blue;
        }

        payload[49] = self.indication_type;
        crate::checksum::write_checksum16(&mut payload, 50, 3..50);
        payload
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpi与原始值换算() {
        // (dpi, low, high)
        let cases = [
            (50u32, 0u8, 0u8),
            (100, 1, 0),
            (800, 15, 0),
            (1600, 31, 0),
            (30000, 87, 2),
            (26000, 7, 2),
        ];
        for (dpi, low, high) in cases {
            assert_eq!(DpiConfig::encode_value(dpi), (low, high), "dpi={dpi}");
            assert_eq!(DpiConfig::decode_value(low, high), dpi, "dpi={dpi}");
        }
    }

    #[test]
    fn 载荷布局与校验位置() {
        let mut config = DpiConfig {
            active_stage: 2,
            ..DpiConfig::default()
        };
        config.stages[0].value = 1600;
        let payload = config.payload();

        assert_eq!(payload.len(), 56);
        assert_eq!(payload[0], 0x04);
        assert_eq!(payload[1], 56);
        assert_eq!(payload[24], 2);
        assert_eq!(payload[5], 0xFF, "8 档全启用 → 掩码 0xFF");
        assert_eq!(payload[8], 0x1F, "1600 → raw 31");
        assert_eq!(payload[16], 0x00);

        let expected = crate::checksum::sum16(&payload, 3..50);
        let actual = (u16::from(payload[50]) << 8) | u16::from(payload[51]);
        assert_eq!(actual, expected);
    }

    #[test]
    fn 关闭某档后掩码对应位清零() {
        let mut config = DpiConfig::default();
        config.stages[2].is_enabled = false;
        config.stages[5].is_enabled = false;
        assert_eq!(config.enabled_mask(), 0b1101_1011);
    }

    #[test]
    fn 出厂档位与指示色() {
        let config = DpiConfig::default();
        assert_eq!(config.stages[0].value, 800);
        assert_eq!(config.stages[1].value, 1600);
        assert_eq!(
            config.stages[0].color,
            crate::lighting::Rgb::new(255, 255, 0)
        );
        assert_eq!(
            config.stages[7].color,
            crate::lighting::Rgb::new(255, 255, 255)
        );
    }
}
