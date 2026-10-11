//! 命令类型与输出报告封装。

/// 命令类型（payload 的第 0 字节）。
///
/// 由官方 `WebDriver For Mac` 的 `sendDataToFW:linkedType:deviceID:`
/// 反汇编确认（分派链对 `data[0]` 做 cmp/b.eq），共 7 个，其余一律丢弃。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum CommandType {
    Dpi = 0x04,
    Lighting = 0x05,
    Parameter = 0x06,
    WirelessSetting = 0x07,
    Buttons = 0x08,
    Macro = 0x09,
    ProfileId = 0x0C,
}

/// 载荷首字节的命令码常量。
pub mod cmd {
    pub const DPI: u8 = 0x04;
    pub const LIGHTING: u8 = 0x05;
    pub const PARAMETER: u8 = 0x06;
    pub const BUTTONS: u8 = 0x08;
    pub const MACRO: u8 = 0x09;
}

impl CommandType {
    pub const ALL: [CommandType; 7] = [
        CommandType::Dpi,
        CommandType::Lighting,
        CommandType::Parameter,
        CommandType::WirelessSetting,
        CommandType::Buttons,
        CommandType::Macro,
        CommandType::ProfileId,
    ];

    #[must_use]
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0x04 => Some(CommandType::Dpi),
            0x05 => Some(CommandType::Lighting),
            0x06 => Some(CommandType::Parameter),
            0x07 => Some(CommandType::WirelessSetting),
            0x08 => Some(CommandType::Buttons),
            0x09 => Some(CommandType::Macro),
            0x0C => Some(CommandType::ProfileId),
            _ => None,
        }
    }
}

/// 英菲克 SDKT 系厂商 HID 通道的输出报告封装。
///
/// ```text
/// [0]   0x04        Report ID
/// [1]   payload.len() + 5      整帧长度
/// [2]   0x00        保留
/// [3..] payload      payload[0] = CommandType
/// [n+3] 校验和高字节  sum(bytes[0..n+3]) & 0xFFFF
/// [n+4] 校验和低字节
/// 其余补零至设备报告长度
/// ```
pub struct Frame;

impl Frame {
    /// 厂商 Output Report 的报告 ID。
    pub const REPORT_ID: u8 = 0x04;
    /// 固件不同报告长度可能为 64 或 65，运行时以设备声明的长度为准。
    pub const FALLBACK_REPORT_LENGTH: usize = 65;

    /// 把命令载荷封装成一条输出报告。
    ///
    /// 载荷比报告长度长时**不截断**，而是返回更长的帧 —— 宏命令 111 字节
    /// 载荷会超过 64 字节，静默截断会写坏命令。
    #[must_use]
    pub fn encode(payload: &[u8], report_length: usize) -> Vec<u8> {
        assert!(!payload.is_empty(), "命令载荷不能为空");

        let length = payload.len() + 5;
        let mut frame = vec![0u8; length];
        frame[0] = Self::REPORT_ID;
        frame[1] = u8::try_from(length).expect("载荷过长，帧长度字段溢出");
        frame[2] = 0x00;
        frame[3..3 + payload.len()].copy_from_slice(payload);

        let csum_at = payload.len() + 3;
        let value = crate::checksum::sum16(&frame, 0..csum_at);
        frame[csum_at] = (value >> 8) as u8;
        frame[csum_at + 1] = value as u8;

        let target = report_length.max(length);
        frame.resize(target, 0);
        frame
    }

    /// 从原始报告中剥离外层封装，还原命令载荷。校验不符返回 `None`。
    #[must_use]
    pub fn decode(report: &[u8]) -> Option<Vec<u8>> {
        if report.len() < 5 || report[0] != Self::REPORT_ID {
            return None;
        }
        let length = usize::from(report[1]);
        if length < 5 || length > report.len() {
            return None;
        }

        let payload_end = length - 5;
        if payload_end == 0 {
            return None;
        }

        let expected = crate::checksum::sum16(report, 0..length - 2);
        let actual = (u16::from(report[length - 2]) << 8) | u16::from(report[length - 1]);
        if actual != expected {
            return None;
        }
        Some(report[3..3 + payload_end].to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 长度字段等于载荷加五() {
        for size in [9usize, 15, 56, 59, 111] {
            let frame = Frame::encode(&vec![0xAA; size], 128);
            assert_eq!(frame.len(), 128);
            assert_eq!(frame[1], (size + 5) as u8);
        }
    }

    #[test]
    fn 封装后可原样解回载荷() {
        let payload = crate::lighting::LightingConfig::default().payload();
        let frame = Frame::encode(&payload, 64);
        assert_eq!(Frame::decode(&frame), Some(payload));
    }

    #[test]
    fn 校验和被篡改时拒绝解析() {
        let mut frame = Frame::encode(&crate::lighting::LightingConfig::default().payload(), 64);
        frame[6] ^= 0xFF;
        assert_eq!(Frame::decode(&frame), None);
    }

    #[test]
    fn 载荷比报告长时不截断() {
        let frame = Frame::encode(&vec![0u8; 100], 64);
        assert_eq!(frame.len(), 105);
        assert_eq!(Frame::decode(&frame).map(|p| p.len()), Some(100));
    }

    #[test]
    fn 补零到两种报告长度() {
        let payload = crate::lighting::ParameterCommand::default().payload();
        assert_eq!(Frame::encode(&payload, 64).len(), 64);
        assert_eq!(Frame::encode(&payload, 65).len(), 65);
    }

    #[test]
    fn 命令码与官方反汇编一致() {
        let pairs = [
            (CommandType::Dpi, 0x04u8),
            (CommandType::Lighting, 0x05),
            (CommandType::Parameter, 0x06),
            (CommandType::WirelessSetting, 0x07),
            (CommandType::Buttons, 0x08),
            (CommandType::Macro, 0x09),
            (CommandType::ProfileId, 0x0C),
        ];
        for (command, raw) in pairs {
            assert_eq!(command as u8, raw);
            assert_eq!(CommandType::from_byte(raw), Some(command));
        }
        assert_eq!(CommandType::ALL.len(), 7);
        assert_eq!(CommandType::from_byte(0x0B), None);
    }
}
