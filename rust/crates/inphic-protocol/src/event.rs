//! 上行事件（Input Report）解析。
//!
//! ## 实机确认（2026-10-11，IN10 / 1d57:fa65 / 2.4G 接收器）
//!
//! 厂商接口（`PrimaryUsage` 128）同时承载**三个** Report ID：
//!
//! | Report ID | 内容 |
//! |---|---|
//! | `0` | 标准鼠标移动 `X_lo X_hi Y_lo Y_hi buttons wheel`，鼠标一动就发 |
//! | `3` | 厂商事件包，见下 |
//!
//! 事件包（len = 5）：
//!
//! ```text
//! 03 93 40 01 2E
//! │  │  │  │  └── 电量百分比
//! │  │  │  └───── 充电状态：1 正常 / 2 已满 / 3 充电
//! │  │  └──────── 事件码
//! │  └─────────── 固件型号码，IN10 = 0x93
//! └────────────── 固定 0x03
//! ```
//!
//! 电量约**每 2 秒**上报一次，但只在鼠标**醒着**的时候 —— 鼠标睡着（出厂深睡 5 分钟）
//! 时既不上报，也**丢弃配置写入**，见 [`crate::transport`]。

/// 充电状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatteryStatus {
    Normal,
    Full,
    Charging,
}

impl BatteryStatus {
    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(BatteryStatus::Normal),
            2 => Some(BatteryStatus::Full),
            3 => Some(BatteryStatus::Charging),
            _ => None,
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            BatteryStatus::Normal => "正常",
            BatteryStatus::Full => "已充满",
            BatteryStatus::Charging => "充电中",
        }
    }
}

/// 鼠标上行事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MouseEvent {
    /// 电量上报。
    Battery { status: BatteryStatus, level: u8 },
    /// 写入确认。
    Acknowledgement { success: bool },
    /// 用户按下 DPI 循环键。
    DpiStageChanged(u8),
    /// 震动马达触发。
    Vibration(u8),
    /// 用户切换了配置档。
    ProfileChanged(u8),
    /// 已识别但尚未归类的厂商事件。
    Vendor { code: u8, p1: u8, p2: u8 },
    /// 解析不出来，原样保留。
    Unparsed(Vec<u8>),
}

/// 鼠标移动量。只在 Report ID 0 上出现，本工具不消费它。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct MouseMotion {
    pub dx: i16,
    pub dy: i16,
    pub buttons: u8,
    pub wheel: i8,
}

/// 事件码。
mod code {
    pub const DPI_CYCLE: u8 = 0x10;
    pub const VIBRATION: u8 = 0x11;
    pub const BATTERY: u8 = 0x40;
    pub const BATTERY_ALT: u8 = 0x41;
    pub const ACKNOWLEDGEMENT: u8 = 0x50;
    pub const PROFILE: u8 = 0x80;

    pub const ALL: [u8; 6] = [
        DPI_CYCLE,
        VIBRATION,
        BATTERY,
        BATTERY_ALT,
        ACKNOWLEDGEMENT,
        PROFILE,
    ];

    /// ACK 事件里合法的命令码，用于排除误判。
    pub const COMMAND_CODES: [u8; 9] = [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C];
}

/// 厂商事件包的 Report ID。
pub const EVENT_REPORT_ID: u8 = 3;
/// 标准鼠标移动的 Report ID。
pub const MOTION_REPORT_ID: u8 = 0;
/// 写入确认用的 Report ID。
pub const ACK_REPORT_ID: u8 = 3;

/// 解析一个已剥掉 Report ID 的事件包。
///
/// 包形如 `03 <deviceId> <code> <p1> <p2>`。部分链路前面会多出 1–2 字节，
/// 故按偏移 2/3/4 依次探测，取第一个**参数合法**的命中，避免误判。
#[must_use]
pub fn parse_event_packet(bytes: &[u8]) -> Option<MouseEvent> {
    if bytes.len() < 5 {
        return None;
    }

    for offset in 2..=4 {
        if bytes.len() < offset + 3 {
            continue;
        }
        let code = bytes[offset];
        if !code::ALL.contains(&code) {
            continue;
        }
        let (p1, p2) = (bytes[offset + 1], bytes[offset + 2]);

        match code {
            code::BATTERY | code::BATTERY_ALT => {
                // 状态必须落在 1–3，否则不算命中（这条约束是唯一可靠的过滤器）。
                let Some(status) = BatteryStatus::from_byte(p1) else {
                    continue;
                };
                if p2 > 100 {
                    continue;
                }
                return Some(MouseEvent::Battery { status, level: p2 });
            }
            code::ACKNOWLEDGEMENT => {
                if p1 > 1 || !code::COMMAND_CODES.contains(&p2) {
                    continue;
                }
                return Some(MouseEvent::Acknowledgement { success: p1 == 0 });
            }
            code::DPI_CYCLE => {
                if !(1..=8).contains(&p1) {
                    continue;
                }
                return Some(MouseEvent::DpiStageChanged(p1));
            }
            code::VIBRATION => return Some(MouseEvent::Vibration(p1)),
            code::PROFILE => return Some(MouseEvent::ProfileChanged(p1)),
            _ => continue,
        }
    }
    None
}

/// 解析写入确认：`06 C0|C1 <status> 00 <csum8>`。
///
/// 校验和 = `(4 + sum(bytes[0..4])) & 0xFF`。
#[must_use]
pub fn parse_acknowledgement(bytes: &[u8]) -> Option<MouseEvent> {
    if bytes.len() < 5 || bytes[0] != 0x06 || !(0xC0..=0xC3).contains(&bytes[1]) {
        return None;
    }
    if bytes[2] > 1 {
        return None;
    }
    let expected = 4u8.wrapping_add(crate::checksum::sum8(bytes, 0..4));
    if expected != bytes[4] {
        return None;
    }
    Some(MouseEvent::Acknowledgement {
        success: bytes[2] == 0x01,
    })
}

/// 解析一条完整的输入报告（**含**首字节 Report ID）。
#[must_use]
pub fn parse_report(report: &[u8]) -> Option<MouseEvent> {
    let Some((&report_id, body)) = report.split_first() else {
        return None;
    };
    match report_id {
        ACK_REPORT_ID => parse_acknowledgement(body).or_else(|| parse_event_packet(body)),
        _ => None,
    }
}

/// 解析标准鼠标移动报告（Report ID 0）。
#[must_use]
pub fn parse_motion(report: &[u8]) -> Option<MouseMotion> {
    if report.len() < 7 || report[0] != MOTION_REPORT_ID {
        return None;
    }
    Some(MouseMotion {
        dx: i16::from_le_bytes([report[1], report[2]]),
        dy: i16::from_le_bytes([report[3], report[4]]),
        buttons: report[5],
        wheel: report[6] as i8,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 解析电量包() {
        // 实机抓到的原始字节：Report ID 3 + 03 93 40 01 2E
        let report = [0x03u8, 0x03, 0x93, 0x40, 0x01, 0x2E];
        assert_eq!(
            parse_report(&report),
            Some(MouseEvent::Battery {
                status: BatteryStatus::Normal,
                level: 46
            })
        );
    }

    #[test]
    fn 电量包前缀噪声不影响识别() {
        let report = [0x03u8, 0xAB, 0x03, 0x93, 0x40, 0x03, 0x64];
        assert_eq!(
            parse_report(&report),
            Some(MouseEvent::Battery {
                status: BatteryStatus::Charging,
                level: 100
            })
        );
    }

    #[test]
    fn 非法状态不会误判成电量() {
        // 0x09 不是合法充电状态
        assert_eq!(parse_event_packet(&[0x03, 0x93, 0x40, 0x09, 0x64]), None);
        // 百分比 > 100 也不认
        assert_eq!(parse_event_packet(&[0x03, 0x93, 0x40, 0x01, 0xC8]), None);
    }

    #[test]
    fn 解析写入确认() {
        let mut success = vec![0x06u8, 0xC0, 0x01, 0x00];
        success.push(4u8.wrapping_add(crate::checksum::sum8(&success, 0..4)));
        assert_eq!(
            parse_acknowledgement(&success),
            Some(MouseEvent::Acknowledgement { success: true })
        );

        let mut failure = vec![0x06u8, 0xC1, 0x00, 0x00];
        failure.push(4u8.wrapping_add(crate::checksum::sum8(&failure, 0..4)));
        assert_eq!(
            parse_acknowledgement(&failure),
            Some(MouseEvent::Acknowledgement { success: false })
        );
    }

    #[test]
    fn 校验和不对时不误判为确认() {
        assert_eq!(parse_acknowledgement(&[0x06, 0xC0, 0x01, 0x00, 0xFF]), None);
    }

    #[test]
    fn 解析鼠标移动() {
        // 实机抓到的：00 14 00 FD FF 00 00  → X=20, Y=-3
        let motion = parse_motion(&[0x00, 0x14, 0x00, 0xFD, 0xFF, 0x00, 0x00]).unwrap();
        assert_eq!(motion.dx, 20);
        assert_eq!(motion.dy, -3);

        // 00 6A 00 EB FF 00 00 → X=106, Y=-21
        let motion = parse_motion(&[0x00, 0x6A, 0x00, 0xEB, 0xFF, 0x00, 0x00]).unwrap();
        assert_eq!(motion.dx, 106);
        assert_eq!(motion.dy, -21);
    }

    #[test]
    fn 解析档位切换事件() {
        assert_eq!(
            parse_event_packet(&[0x03, 0x93, 0x10, 0x04, 0x00]),
            Some(MouseEvent::DpiStageChanged(4))
        );
    }

    #[test]
    fn 过短的包返回空() {
        assert_eq!(parse_event_packet(&[0x03, 0x93]), None);
        assert_eq!(parse_report(&[]), None);
    }
}
