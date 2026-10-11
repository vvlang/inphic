//! 灯光 / 电源 / 按键响应时间，以及轮询率。

/// 灯效模式。固件里存 `index << 4`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum LightMode {
    #[default]
    Off = 0x0,
    Static = 0x1,
    Breathing = 0x2,
    Neon = 0x3,
    CycleBreathing = 0x4,
    StaticDpi = 0x5,
    BreathingDpi = 0x6,
}

impl LightMode {
    pub const ALL: [LightMode; 7] = [
        LightMode::Off,
        LightMode::Static,
        LightMode::Breathing,
        LightMode::Neon,
        LightMode::CycleBreathing,
        LightMode::StaticDpi,
        LightMode::BreathingDpi,
    ];

    /// 从**线上原样字节**取出模式（存放在高半字节）。
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte >> 4 {
            0x0 => Some(LightMode::Off),
            0x1 => Some(LightMode::Static),
            0x2 => Some(LightMode::Breathing),
            0x3 => Some(LightMode::Neon),
            0x4 => Some(LightMode::CycleBreathing),
            0x5 => Some(LightMode::StaticDpi),
            0x6 => Some(LightMode::BreathingDpi),
            _ => None,
        }
    }

    /// 高半字节存放模式。
    #[must_use]
    pub const fn nibble(self) -> u8 {
        (self as u8) << 4
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            LightMode::Off => "关闭",
            LightMode::Static => "常亮",
            LightMode::Breathing => "呼吸",
            LightMode::Neon => "霓虹",
            LightMode::CycleBreathing => "循环呼吸",
            LightMode::StaticDpi => "DPI 常亮",
            LightMode::BreathingDpi => "DPI 呼吸",
        }
    }
}

/// 8 位 RGB。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl Rgb {
    #[must_use]
    pub const fn new(red: u8, green: u8, blue: u8) -> Self {
        Self { red, green, blue }
    }

    #[must_use]
    pub fn from_hex(hex: &str) -> Option<Self> {
        let text = hex.trim().trim_start_matches('#');
        if text.len() != 6 {
            return None;
        }
        let value = u32::from_str_radix(text, 16).ok()?;
        Some(Self::new(
            ((value >> 16) & 0xFF) as u8,
            ((value >> 8) & 0xFF) as u8,
            (value & 0xFF) as u8,
        ))
    }

    #[must_use]
    pub fn to_hex(self) -> String {
        format!("#{:02X}{:02X}{:02X}", self.red, self.green, self.blue)
    }
}

/// 官方固件的默认档位指示色。
pub const DPI_DEFAULT_COLORS: [Rgb; 8] = [
    Rgb::new(255, 255, 0),   // 黄
    Rgb::new(0, 255, 255),   // 青
    Rgb::new(0, 255, 0),     // 绿
    Rgb::new(255, 0, 255),   // 品红
    Rgb::new(0, 0, 255),     // 蓝
    Rgb::new(255, 0, 0),     // 红
    Rgb::new(255, 64, 0),    // 橙
    Rgb::new(255, 255, 255), // 白
];

/// 灯光 + 电源 + 去抖。
///
/// 固件把三组设置合并在同一条命令里，改任意一项都必须带上其余项的当前值。
///
/// 出厂值取自官方 HUB 在全新 IN10 上发出的启动 profile
/// `05 0F 01 30 03 58 00 00 FF 01 03 …`（霓虹、蓝色、亮度 8、速度 6、
/// 浅睡 0.5 分钟、深睡 5 分钟、响应 3ms）。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LightingConfig {
    pub profile_id: u8,
    pub mode: LightMode,
    /// 灯效速度 1–8，固件存 `9 - speed`。
    pub speed: u8,
    /// 亮度 1–8。
    pub brightness: u8,
    pub color: Rgb,
    /// 浅睡超时，分钟 0.5–30，固件存 `minutes × 2`。
    pub light_sleep_minutes: f64,
    /// 深度休眠，分钟 1–60。
    pub deep_sleep_minutes: u8,
    /// 按键响应时间（去抖），毫秒。
    pub debounce_ms: u8,
}

impl Default for LightingConfig {
    fn default() -> Self {
        Self {
            profile_id: 1,
            mode: LightMode::Neon,
            speed: 6,
            brightness: 8,
            color: Rgb::new(0x00, 0x00, 0xFF),
            light_sleep_minutes: 0.5,
            deep_sleep_minutes: 5,
            debounce_ms: 3,
        }
    }
}

impl LightingConfig {
    /// 15 字节载荷。
    #[must_use]
    pub fn payload(&self) -> Vec<u8> {
        let deep = self.deep_sleep_minutes.min(60);
        let sleep_high = (deep >> 4) & 0x0F;
        let sleep_low = deep & 0x0F;

        let mut payload = vec![0u8; 15];
        payload[0] = crate::frame::cmd::LIGHTING;
        payload[1] = 15;
        payload[2] = self.profile_id;
        payload[3] = self.mode.nibble();
        payload[4] = (sleep_high << 4) | (9u8.saturating_sub(self.speed.min(8)).min(15) & 0x0F);
        payload[5] = (sleep_low << 4) | (self.brightness.clamp(1, 8) & 0x0F);
        payload[6] = self.color.red;
        payload[7] = self.color.green;
        payload[8] = self.color.blue;
        payload[9] =
            ((self.light_sleep_minutes.clamp(0.5, 30.0) * 2.0).round() as u16 & 0xFF) as u8;
        payload[10] = self.debounce_ms.min(50);
        crate::checksum::write_checksum16(&mut payload, 11, 3..11);
        payload
    }

    /// 从载荷还原。
    #[must_use]
    pub fn from_payload(payload: &[u8]) -> Option<Self> {
        if payload.len() < 15 || payload[0] != crate::frame::cmd::LIGHTING {
            return None;
        }
        Some(Self {
            profile_id: payload[2],
            mode: LightMode::from_byte(payload[3]).unwrap_or(LightMode::Off),
            speed: 9u8.saturating_sub(payload[4] & 0x0F),
            brightness: payload[5] & 0x0F,
            color: Rgb::new(payload[6], payload[7], payload[8]),
            light_sleep_minutes: f64::from(payload[9]) / 2.0,
            deep_sleep_minutes: ((payload[4] >> 4) << 4) | (payload[5] >> 4),
            debounce_ms: payload[10],
        })
    }
}

/// 轮询率 / 性能命令。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PollingRate {
    Hz125,
    Hz250,
    Hz500,
    Hz1000,
    Hz2000,
    Hz4000,
    Hz8000,
}

impl PollingRate {
    pub const ALL: [PollingRate; 7] = [
        PollingRate::Hz125,
        PollingRate::Hz250,
        PollingRate::Hz500,
        PollingRate::Hz1000,
        PollingRate::Hz2000,
        PollingRate::Hz4000,
        PollingRate::Hz8000,
    ];

    #[must_use]
    pub const fn hz(self) -> u16 {
        match self {
            PollingRate::Hz125 => 125,
            PollingRate::Hz250 => 250,
            PollingRate::Hz500 => 500,
            PollingRate::Hz1000 => 1000,
            PollingRate::Hz2000 => 2000,
            PollingRate::Hz4000 => 4000,
            PollingRate::Hz8000 => 8000,
        }
    }

    /// 固件里的编码。注意不是单调的 —— 8000Hz 反而是 64。
    #[must_use]
    pub const fn firmware_value(self) -> u8 {
        match self {
            PollingRate::Hz125 => 32,
            PollingRate::Hz250 => 16,
            PollingRate::Hz500 => 8,
            PollingRate::Hz1000 => 4,
            PollingRate::Hz2000 => 2,
            PollingRate::Hz4000 => 1,
            PollingRate::Hz8000 => 64,
        }
    }

    #[must_use]
    pub const fn from_firmware(byte: u8) -> Option<Self> {
        match byte {
            32 => Some(PollingRate::Hz125),
            16 => Some(PollingRate::Hz250),
            8 => Some(PollingRate::Hz500),
            4 => Some(PollingRate::Hz1000),
            2 => Some(PollingRate::Hz2000),
            1 => Some(PollingRate::Hz4000),
            64 => Some(PollingRate::Hz8000),
            _ => None,
        }
    }
}

impl Default for PollingRate {
    fn default() -> Self {
        PollingRate::Hz1000
    }
}

/// 轮询率命令，9 字节载荷。第 4 字节是第 3 字节的取反。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ParameterCommand {
    pub profile_id: u8,
    pub polling_rate: PollingRate,
}

impl ParameterCommand {
    #[must_use]
    pub fn payload(&self) -> Vec<u8> {
        let mut payload = vec![0u8; 9];
        payload[0] = crate::frame::cmd::PARAMETER;
        payload[1] = 9;
        payload[2] = self.profile_id;
        payload[3] = self.polling_rate.firmware_value();
        payload[4] = !payload[3];
        payload
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::checksum::hex_dump;

    #[test]
    fn 出厂载荷与官方启动profile逐字节一致() {
        // 官方 HUB 抓包: 05 0F 01 30 03 58 00 00 FF 01 03 01 8E 00 00
        assert_eq!(
            hex_dump(&LightingConfig::default().payload()),
            "05 0F 01 30 03 58 00 00 FF 01 03 01 8E 00 00"
        );
    }

    #[test]
    fn 灯效模式存为高半字节() {
        for mode in LightMode::ALL {
            assert_eq!(mode.nibble() >> 4, mode as u8);
            assert_eq!(mode.nibble() & 0x0F, 0);
            assert_eq!(LightMode::from_byte(mode.nibble()), Some(mode));
        }
    }

    #[test]
    fn 深睡分钟拆到两个字节的高半字节() {
        let mut config = LightingConfig::default();
        config.deep_sleep_minutes = 45;
        config.brightness = 3;
        config.speed = 4;
        let payload = config.payload();
        assert_eq!(payload[4] >> 4, 2, "45 >> 4");
        assert_eq!(payload[5] >> 4, 13, "45 & 0x0F");
        assert_eq!(payload[4] & 0x0F, 9 - 4);
        assert_eq!(payload[5] & 0x0F, 3);
    }

    #[test]
    fn 载荷可原样还原() {
        let original = LightingConfig {
            profile_id: 1,
            mode: LightMode::Breathing,
            speed: 2,
            brightness: 6,
            color: Rgb::new(10, 20, 30),
            light_sleep_minutes: 2.0,
            deep_sleep_minutes: 25,
            debounce_ms: 8,
        };
        assert_eq!(
            LightingConfig::from_payload(&original.payload()),
            Some(original)
        );
    }

    #[test]
    fn 轮询率编码表() {
        let expected = [
            (PollingRate::Hz125, 125u16, 32u8),
            (PollingRate::Hz250, 250, 16),
            (PollingRate::Hz500, 500, 8),
            (PollingRate::Hz1000, 1000, 4),
            (PollingRate::Hz2000, 2000, 2),
            (PollingRate::Hz4000, 4000, 1),
            (PollingRate::Hz8000, 8000, 64),
        ];
        for (rate, hz, raw) in expected {
            assert_eq!(rate.hz(), hz);
            assert_eq!(rate.firmware_value(), raw);
            assert_eq!(PollingRate::from_firmware(raw), Some(rate));
        }
    }

    #[test]
    fn 轮询率载荷第4字节是取反校验() {
        let command = ParameterCommand {
            profile_id: 1,
            polling_rate: PollingRate::Hz8000,
        };
        assert_eq!(hex_dump(&command.payload()), "06 09 01 40 BF 00 00 00 00");
    }

    #[test]
    fn 颜色往返() {
        let color = Rgb::new(0x12, 0x34, 0x56);
        assert_eq!(color.to_hex(), "#123456");
        assert_eq!(Rgb::from_hex("#123456"), Some(color));
        assert_eq!(Rgb::from_hex("123456"), Some(color));
        assert_eq!(Rgb::from_hex("#FFF"), None);
    }
}
