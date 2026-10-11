//! 按键映射（18 个固件槽位）。
//!
//! 只有前 5 个物理按键（左 / 右 / 中 / 前 / 后）在官方 UI 里可改。

/// 一个按键绑定的 3 字节动作 `[类型, v1, v2]`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ButtonAction {
    pub kind: ActionKind,
    pub modifier: u8,
    pub argument: u8,
}

/// 动作类型码。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ActionKind {
    Off = 1,
    LeftClick = 2,
    RightClick = 3,
    MiddleClick = 4,
    Backward = 5,
    Forward = 6,
    DoubleClick = 7,
    Fire = 8,
    ScrollDown = 9,
    ScrollUp = 10,
    TiltLeft = 11,
    TiltRight = 12,
    DpiCycle = 13,
    DpiUp = 14,
    DpiDown = 15,
    EasyAim = 16,
    /// `[17, 修饰键掩码, HID usage]`
    Shortcut = 17,
    /// `[18, 0, 宏编号]`
    Macro = 18,
    MediaPlay = 21,
    MediaPrevious = 22,
    MediaNext = 23,
    MediaPlayPause = 24,
    MediaStop = 25,
    Mute = 26,
    VolumeUp = 27,
    VolumeDown = 28,
    Calculator = 29,
    Email = 30,
    BrowserForward = 32,
    BrowserBack = 33,
    BrowserRefresh = 36,
    BrowserHome = 37,
    BrowserSearch = 38,
    ProfileCycle = 52,
    ProfileUp = 53,
    ProfileDown = 54,
    ModeKey = 60,
}

impl ActionKind {
    /// 是否会占用 `argument`。
    #[must_use]
    pub const fn takes_argument(self) -> bool {
        matches!(self, ActionKind::Shortcut | ActionKind::Macro)
    }
}

/// HID 修饰键掩码。
pub mod modifier {
    pub const CTRL: u8 = 0x01;
    pub const SHIFT: u8 = 0x02;
    pub const ALT: u8 = 0x04;
    /// macOS 上是 Command。
    pub const GUI: u8 = 0x08;
}

impl ButtonAction {
    #[must_use]
    pub const fn simple(kind: ActionKind) -> Self {
        Self {
            kind,
            modifier: 0,
            argument: 0,
        }
    }

    #[must_use]
    pub const fn shortcut(modifier: u8, usage: u8) -> Self {
        Self {
            kind: ActionKind::Shortcut,
            modifier,
            argument: usage,
        }
    }

    #[must_use]
    pub const fn macro_slot(id: u8) -> Self {
        Self {
            kind: ActionKind::Macro,
            modifier: 0,
            argument: id,
        }
    }

    pub const DISABLED: Self = Self::simple(ActionKind::Off);
}

/// 固件里的 18 个按键槽位。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(usize)]
pub enum ButtonSlot {
    LeftClick = 0,
    RightClick = 1,
    MiddleClick = 2,
    DpiCycle = 3,
    DpiUp = 4,
    DpiDown = 5,
    Backward = 6,
    Forward = 7,
    ModeKey = 8,
    Spare1 = 9,
    Spare2 = 10,
    Spare3 = 11,
    Spare4 = 12,
    Spare5 = 13,
    Spare6 = 14,
    Spare7 = 15,
    ScrollDown = 16,
    ScrollUp = 17,
}

impl ButtonSlot {
    pub const ALL: [ButtonSlot; 18] = [
        ButtonSlot::LeftClick,
        ButtonSlot::RightClick,
        ButtonSlot::MiddleClick,
        ButtonSlot::DpiCycle,
        ButtonSlot::DpiUp,
        ButtonSlot::DpiDown,
        ButtonSlot::Backward,
        ButtonSlot::Forward,
        ButtonSlot::ModeKey,
        ButtonSlot::Spare1,
        ButtonSlot::Spare2,
        ButtonSlot::Spare3,
        ButtonSlot::Spare4,
        ButtonSlot::Spare5,
        ButtonSlot::Spare6,
        ButtonSlot::Spare7,
        ButtonSlot::ScrollDown,
        ButtonSlot::ScrollUp,
    ];

    /// 官方 UI 允许用户改的物理按键。
    pub const USER_EDITABLE: [ButtonSlot; 5] = [
        ButtonSlot::LeftClick,
        ButtonSlot::RightClick,
        ButtonSlot::MiddleClick,
        ButtonSlot::Forward,
        ButtonSlot::Backward,
    ];

    #[must_use]
    pub const fn index(self) -> usize {
        self as usize
    }

    #[must_use]
    pub const fn is_user_editable(self) -> bool {
        matches!(
            self,
            ButtonSlot::LeftClick
                | ButtonSlot::RightClick
                | ButtonSlot::MiddleClick
                | ButtonSlot::Forward
                | ButtonSlot::Backward
        )
    }

    /// 出厂动作。
    #[must_use]
    pub const fn factory_action(self) -> ButtonAction {
        match self {
            ButtonSlot::LeftClick => ButtonAction::simple(ActionKind::LeftClick),
            ButtonSlot::RightClick => ButtonAction::simple(ActionKind::RightClick),
            ButtonSlot::MiddleClick => ButtonAction::simple(ActionKind::MiddleClick),
            ButtonSlot::Backward => ButtonAction::simple(ActionKind::Backward),
            ButtonSlot::Forward => ButtonAction::simple(ActionKind::Forward),
            ButtonSlot::DpiCycle => ButtonAction::simple(ActionKind::DpiCycle),
            ButtonSlot::DpiUp => ButtonAction::simple(ActionKind::DpiUp),
            ButtonSlot::DpiDown => ButtonAction::simple(ActionKind::DpiDown),
            ButtonSlot::ScrollDown => ButtonAction::simple(ActionKind::ScrollDown),
            ButtonSlot::ScrollUp => ButtonAction::simple(ActionKind::ScrollUp),
            ButtonSlot::ModeKey => ButtonAction::simple(ActionKind::ModeKey),
            _ => ButtonAction::DISABLED,
        }
    }
}

/// 按键映射命令（59 字节载荷）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ButtonConfig {
    pub profile_id: u8,
    actions: [ButtonAction; 18],
}

impl Default for ButtonConfig {
    fn default() -> Self {
        Self {
            profile_id: 1,
            actions: ButtonSlot::ALL.map(ButtonSlot::factory_action),
        }
    }
}

impl ButtonConfig {
    #[must_use]
    pub fn action(&self, slot: ButtonSlot) -> ButtonAction {
        self.actions[slot.index()]
    }

    pub fn set_action(&mut self, slot: ButtonSlot, action: ButtonAction) {
        self.actions[slot.index()] = action;
    }

    pub fn reset_to_factory(&mut self) {
        self.actions = ButtonSlot::ALL.map(ButtonSlot::factory_action);
    }

    #[must_use]
    pub fn payload(&self) -> Vec<u8> {
        let mut payload = vec![0u8; 59];
        payload[0] = crate::frame::cmd::BUTTONS;
        payload[1] = 59;
        payload[2] = self.profile_id;
        for (index, action) in self.actions.iter().enumerate() {
            let base = 3 + index * 3;
            payload[base] = action.kind as u8;
            payload[base + 1] = action.modifier;
            payload[base + 2] = action.argument;
        }
        crate::checksum::write_checksum16(&mut payload, 57, 3..57);
        payload
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 载荷形状() {
        let payload = ButtonConfig::default().payload();
        assert_eq!(payload.len(), 59);
        assert_eq!(payload[0], 0x08);
        assert_eq!(payload[1], 59);
        let expected = crate::checksum::sum16(&payload, 3..57);
        let actual = (u16::from(payload[57]) << 8) | u16::from(payload[58]);
        assert_eq!(actual, expected);
    }

    #[test]
    fn 出厂动作按槽位写入() {
        let mut config = ButtonConfig::default();
        assert_eq!(
            config.action(ButtonSlot::LeftClick).kind,
            ActionKind::LeftClick
        );
        assert_eq!(config.action(ButtonSlot::Forward).kind, ActionKind::Forward);

        config.set_action(ButtonSlot::Forward, ButtonAction::shortcut(0x03, 0x1C));
        let payload = config.payload();
        // 后退在槽位 6，前进在槽位 7
        assert_eq!(payload[3 + 7 * 3], ActionKind::Shortcut as u8);
        assert_eq!(payload[3 + 7 * 3 + 1], 0x03);
        assert_eq!(payload[3 + 7 * 3 + 2], 0x1C);
    }

    #[test]
    fn 恢复出厂() {
        let mut config = ButtonConfig::default();
        config.set_action(
            ButtonSlot::MiddleClick,
            ButtonAction::simple(ActionKind::BrowserHome),
        );
        config.reset_to_factory();
        assert_eq!(config, ButtonConfig::default());
    }

    #[test]
    fn 只有五个物理按键可改() {
        assert_eq!(ButtonSlot::USER_EDITABLE.len(), 5);
        assert_eq!(
            ButtonSlot::ALL
                .iter()
                .filter(|s| s.is_user_editable())
                .count(),
            5
        );
    }
}
