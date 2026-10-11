//! 宏命令。
//!
//! 宏由鼠标固件自行播放，不在主机侧回放。

use crate::lighting::Rgb;

/// 宏里的一步动作。每一步都带一个「动作前的延时」。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MacroAction {
    /// `usage` 是 HID Keyboard/Keypad page (0x07) 的 usage id。
    Key { usage: u8, pressed: bool, delay: u8 },
    /// 相对移动。
    Move { dx: i16, dy: i16, delay: u8 },
    /// 纯等待。
    Wait { milliseconds: u8 },
}

impl MacroAction {
    /// 录制时的默认延时。
    pub const DEFAULT_DELAY: u8 = 10;

    #[must_use]
    pub const fn key_down(usage: u8) -> Self {
        Self::Key {
            usage,
            pressed: true,
            delay: Self::DEFAULT_DELAY,
        }
    }

    #[must_use]
    pub const fn key_up(usage: u8) -> Self {
        Self::Key {
            usage,
            pressed: false,
            delay: Self::DEFAULT_DELAY,
        }
    }

    #[must_use]
    pub const fn move_by(dx: i16, dy: i16) -> Self {
        Self::Move { dx, dy, delay: 1 }
    }

    #[must_use]
    pub const fn wait(milliseconds: u8) -> Self {
        Self::Wait { milliseconds }
    }

    #[must_use]
    pub const fn delay(&self) -> u8 {
        match *self {
            Self::Key { delay, .. } | Self::Move { delay, .. } => delay,
            Self::Wait { milliseconds } => milliseconds,
        }
    }
}

/// 宏触发方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum MacroTrigger {
    #[default]
    Loop = 0,
    StopOnAnyKey = 1,
    PlayWhileHeld = 2,
    StopWithButton = 3,
}

impl MacroTrigger {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            MacroTrigger::Loop => "循环播放",
            MacroTrigger::StopOnAnyKey => "任意键停止",
            MacroTrigger::PlayWhileHeld => "按住播放，松开停止",
            MacroTrigger::StopWithButton => "宏键停止",
        }
    }
}

/// 一条宏。`id` 从 1 开始，与按键映射的 `argument` 对应。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Macro {
    pub id: u8,
    pub name: String,
    pub trigger: MacroTrigger,
    /// `trigger == Loop` 时生效，1–255。
    pub loops: u8,
    pub actions: Vec<MacroAction>,
    pub color: Rgb,
}

impl Macro {
    #[must_use]
    pub fn new(id: u8) -> Self {
        Self {
            id,
            name: format!("宏 {id}"),
            trigger: MacroTrigger::Loop,
            loops: 1,
            actions: Vec::new(),
            color: Rgb::new(0, 0, 0),
        }
    }

    /// 编码成宏命令载荷（111 字节）。
    ///
    /// # Errors
    /// 事件流超过固件上限（100 字节）时返回 [`MacroError::TooManyActions`]。
    pub fn payload(&self) -> Result<Vec<u8>, MacroError> {
        let (data, count) = Self::encode_actions(&self.actions)?;

        let mut payload = vec![0u8; Self::PAYLOAD_LENGTH];
        payload[0] = crate::frame::cmd::MACRO;
        payload[1] = Self::SIZE_BYTE;
        payload[2] = self.id;
        payload[3] = self.trigger as u8;
        payload[4] = self.color.red;
        payload[5] = self.color.green;
        payload[6] = self.color.blue;
        payload[7] = self.loops.max(1);
        payload[8] = count as u8;
        payload[9..9 + data.len()].copy_from_slice(&data);
        crate::checksum::write_checksum16(&mut payload, 109, 3..109);
        Ok(payload)
    }

    /// 事件流可用空间。
    pub const MAX_EVENT_BYTES: usize = 100;
    pub const PAYLOAD_LENGTH: usize = 111;
    /// 载荷第 1 字节，也是固件用来判定「整条下发」而非分片的魔数。
    pub const SIZE_BYTE: u8 = 0x6F;

    /// 把动作列表编码成事件流。
    ///
    /// - 按键：`[delay | 0x01, usage]` 按下 / `[delay | 0x80, usage]` 抬起
    /// - 移动：`[delay, 0xF6, x_hi, x_lo, y_hi, y_lo]`
    /// - 延时 > 127ms：延时字节改用 `delay % 100`（为 0 时补 1），追加 `[delay / 100, 0x03]`
    ///
    /// # Errors
    /// 事件流超过固件上限时返回 [`MacroError::TooManyActions`]。
    pub fn encode_actions(actions: &[MacroAction]) -> Result<(Vec<u8>, usize), MacroError> {
        let mut out = Vec::with_capacity(actions.len() * 2);
        let mut count = 0usize;

        for action in actions {
            let delay = split_delay(u16::from(action.delay()));
            match *action {
                MacroAction::Key { usage, pressed, .. } => {
                    out.push(delay.byte | if pressed { 0x01 } else { 0x80 });
                    out.push(usage);
                    count += 1;
                    if delay.is_long {
                        out.push(delay.group);
                        out.push(0x03);
                        count += 1;
                    }
                }
                MacroAction::Move { dx, dy, .. } => {
                    out.push(delay.byte);
                    out.push(0xF6);
                    out.push((dx >> 8) as u8);
                    out.push(dx as u8);
                    out.push((dy >> 8) as u8);
                    out.push(dy as u8);
                    count += 3;
                    if delay.is_long {
                        out.push(delay.group);
                        out.push(0x03);
                        count += 1;
                    }
                }
                MacroAction::Wait { milliseconds } => {
                    out.push(delay.byte);
                    out.push(0x03);
                    count += 1;
                    if delay.is_long {
                        out.push(delay.group);
                        out.push(0x03);
                        count += 1;
                    }
                    let _ = milliseconds;
                }
            }

            if out.len() > Self::MAX_EVENT_BYTES {
                return Err(MacroError::TooManyActions {
                    byte_count: out.len(),
                });
            }
        }
        Ok((out, count))
    }

    /// 事件流实际占用字节数。
    #[must_use]
    pub fn encoded_size(&self) -> usize {
        Self::encode_actions(&self.actions).map_or(0, |(data, _)| data.len())
    }
}

/// 长延时拆成「延时字节 + 追加的组数」。
struct SplitDelay {
    byte: u8,
    group: u8,
    is_long: bool,
}

fn split_delay(delay: u16) -> SplitDelay {
    if delay <= 127 {
        return SplitDelay {
            byte: delay as u8,
            group: 0,
            is_long: false,
        };
    }
    SplitDelay {
        byte: (delay % 100).max(1) as u8,
        group: (delay / 100).min(255) as u8,
        is_long: true,
    }
}

/// 宏编码错误。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MacroError {
    TooManyActions { byte_count: usize },
}

impl std::fmt::Display for MacroError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MacroError::TooManyActions { byte_count } => write!(
                f,
                "宏内容过长（{byte_count} 字节），固件单条宏最多 {} 字节",
                Macro::MAX_EVENT_BYTES
            ),
        }
    }
}

impl std::error::Error for MacroError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 载荷形状与魔数() {
        let macro_def = Macro::new(1);
        let payload = macro_def.payload().unwrap();
        assert_eq!(payload.len(), 111);
        assert_eq!(payload[0], 0x09);
        assert_eq!(payload[1], 0x6F);
        let expected = crate::checksum::sum16(&payload, 3..109);
        let actual = (u16::from(payload[109]) << 8) | u16::from(payload[110]);
        assert_eq!(actual, expected);
    }

    #[test]
    fn 按键按下与抬起用不同标志位() {
        let (data, count) =
            Macro::encode_actions(&[MacroAction::key_down(0x04), MacroAction::key_up(0x04)])
                .unwrap();
        assert_eq!(data, vec![10 | 0x01, 0x04, 10 | 0x80, 0x04]);
        assert_eq!(count, 2);
    }

    #[test]
    fn 移动编码为大端坐标() {
        let (data, _) = Macro::encode_actions(&[MacroAction::Move {
            dx: -2,
            dy: 300,
            delay: 1,
        }])
        .unwrap();
        assert_eq!(data, vec![0x01, 0xF6, 0xFF, 0xFE, 0x01, 0x2C]);
    }

    #[test]
    fn 长延时拆成余数字节加组数() {
        // 127 以上才拆；这里用 0xFF(=255ms) → 余数 55、组数 2
        let action = MacroAction::Key {
            usage: 0x04,
            pressed: true,
            delay: 255,
        };
        let (data, count) = Macro::encode_actions(&[action]).unwrap();
        assert_eq!(data, vec![55 | 0x01, 0x04, 2, 0x03]);
        assert_eq!(count, 2);
    }

    #[test]
    fn 短延时不拆() {
        let (data, count) = Macro::encode_actions(&[MacroAction::key_down(0x04)]).unwrap();
        assert_eq!(data, vec![10 | 0x01, 0x04]);
        assert_eq!(count, 1);
    }

    #[test]
    fn 等待编码为延时字节加三() {
        let (data, count) = Macro::encode_actions(&[MacroAction::wait(20)]).unwrap();
        assert_eq!(data, vec![20, 0x03]);
        assert_eq!(count, 1);
    }

    #[test]
    fn 超过固件上限时报错() {
        let actions: Vec<MacroAction> = (0..80).map(|_| MacroAction::key_down(0x04)).collect();
        let error = Macro::encode_actions(&actions).unwrap_err();
        assert_eq!(error, MacroError::TooManyActions { byte_count: 102 });
    }

    #[test]
    fn 错误信息可读() {
        let error = MacroError::TooManyActions { byte_count: 102 };
        assert!(error.to_string().contains("102"));
        assert!(error.to_string().contains("100"));
    }
}
