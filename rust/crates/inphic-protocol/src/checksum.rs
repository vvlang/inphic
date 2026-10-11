//! 英菲克 SDKT 系固件使用的大端 16 位累加和校验。
//!
//! 两种长度同时存在：
//! - 载荷内校验（payload 自带，跨命令长度不一）
//! - 外层帧校验（覆盖报告 ID、长度、保留字节和整个 payload）

/// `sum(bytes[start..end]) & 0xFFFF`
#[must_use]
pub fn sum16(bytes: &[u8], range: std::ops::Range<usize>) -> u16 {
    let start = range.start.min(bytes.len());
    let end = range.end.min(bytes.len()).max(start);
    bytes[start..end]
        .iter()
        .fold(0u32, |acc, b| acc.wrapping_add(u32::from(*b))) as u16
}

/// `sum(bytes[start..end]) & 0xFF`
#[must_use]
pub fn sum8(bytes: &[u8], range: std::ops::Range<usize>) -> u8 {
    let start = range.start.min(bytes.len());
    let end = range.end.min(bytes.len()).max(start);
    bytes[start..end]
        .iter()
        .fold(0u32, |acc, b| acc.wrapping_add(u32::from(*b))) as u8
}

/// 以大端两字节把校验和写入 `buffer[offset..offset+2]`。
///
/// 越界会被静默忽略 —— 调用方负责保证长度。
pub fn write_checksum16(buffer: &mut [u8], offset: usize, over: std::ops::Range<usize>) {
    let value = sum16(buffer, over);
    if offset + 1 < buffer.len() {
        buffer[offset] = (value >> 8) as u8;
        buffer[offset + 1] = value as u8;
    }
}

/// 连续十六进制转字节数组。
///
/// 容忍空格、逗号、连字符，以及 `0x` / `0X` 前缀；其余非十六进制字符一律忽略。
#[must_use]
pub fn parse_hex(text: &str) -> Vec<u8> {
    let without_prefix: String = text
        .split("0x")
        .flat_map(|s| s.split("0X"))
        .collect::<Vec<_>>()
        .join("");
    let cleaned: String = without_prefix
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();
    let chars: Vec<char> = cleaned.chars().collect();
    chars
        .chunks(2)
        .filter_map(|pair| {
            let s: String = pair.iter().collect();
            u8::from_str_radix(&s, 16).ok()
        })
        .collect()
}

/// 便于调试的十六进制表示，例如 `04 14 00 05 0F …`
#[must_use]
pub fn hex_dump(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 校验和按大端解释() {
        // 0x10 + 0x03 + 0x58 + 0xFF + 0x00 + 0x00 + 0x01 + 0x03 = 366 = 0x016E
        let bytes = [
            0x05u8, 0x0F, 0x01, 0x10, 0x03, 0x58, 0xFF, 0x00, 0x00, 0x01, 0x03,
        ];
        assert_eq!(sum16(&bytes, 3..11), 0x016E);
    }

    #[test]
    fn 八位校验含常量项() {
        // 官方 ACK：csum = (4 + sum(bytes[0..4])) & 0xFF
        let ack = [0x06u8, 0xC0, 0x01, 0x00];
        assert_eq!(4u8.wrapping_add(sum8(&ack, 0..4)), 0xCB);
    }

    #[test]
    fn 越界范围被安全截断() {
        assert_eq!(sum16(&[1, 2, 3], 0..100), 6);
        assert_eq!(sum16(&[1, 2, 3], 50..60), 0);
    }

    #[test]
    fn 十六进制解析容错() {
        assert_eq!(parse_hex("04 14 00"), vec![0x04, 0x14, 0x00]);
        assert_eq!(parse_hex("041400"), vec![0x04, 0x14, 0x00]);
        assert_eq!(parse_hex("0x04,0x14"), vec![0x04, 0x14]);
        assert!(parse_hex("").is_empty());
    }

    #[test]
    fn 十六进制输出大写() {
        assert_eq!(hex_dump(&[0x04, 0x0f, 0xff]), "04 0F FF");
    }
}
