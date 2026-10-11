//! 配置档。
//!
//! 固件侧**没有读回接口** —— 官方 macOS 驱动也是纯只写的（它的二进制里
//! 根本没有 import `IOHIDDeviceGetReport`）。所以配置以本地为准，
//! 下发时整份重写，避免「改了一项把别的项清零」。

use crate::CommandType;
use crate::buttons::ButtonConfig;
use crate::dpi::DpiConfig;
use crate::lighting::{LightingConfig, ParameterCommand};
use crate::macro_cmd::Macro;

/// 一个完整配置档。
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceProfile {
    pub name: String,
    /// 固件里的配置档号。IN10 官方前端把它硬编码为 1。
    pub firmware_profile_id: u8,
    pub dpi: DpiConfig,
    pub lighting: LightingConfig,
    pub polling: ParameterCommand,
    pub buttons: ButtonConfig,
    pub macros: Vec<Macro>,
}

impl Default for DeviceProfile {
    fn default() -> Self {
        Self {
            name: "配置 1".to_string(),
            firmware_profile_id: 1,
            dpi: DpiConfig::default(),
            lighting: LightingConfig::default(),
            polling: ParameterCommand::default(),
            buttons: ButtonConfig::default(),
            macros: Vec::new(),
        }
    }
}

impl DeviceProfile {
    /// 把整份配置摊平成一串命令载荷。
    ///
    /// 顺序有讲究：先 DPI（决定当前档位与指示灯语义），再灯光/电源，
    /// 再轮询率，最后按键与宏。
    ///
    /// # Errors
    /// 某条宏超出固件上限时返回 [`crate::macro_cmd::MacroError`]。
    pub fn payloads(&self) -> Result<Vec<(CommandType, Vec<u8>)>, crate::macro_cmd::MacroError> {
        let mut commands = Vec::with_capacity(4 + self.macros.len());
        commands.push((CommandType::Dpi, self.dpi.payload()));
        commands.push((CommandType::Lighting, self.lighting.payload()));
        commands.push((CommandType::Parameter, self.polling.payload()));
        commands.push((CommandType::Buttons, self.buttons.payload()));
        for macro_def in &self.macros {
            commands.push((CommandType::Macro, macro_def.payload()?));
        }
        Ok(commands)
    }

    /// 摊平成可以直接下发的完整报告帧。
    ///
    /// # Errors
    /// 见 [`DeviceProfile::payloads`]。
    pub fn frames(
        &self,
        report_length: usize,
    ) -> Result<Vec<Vec<u8>>, crate::macro_cmd::MacroError> {
        Ok(self
            .payloads()?
            .into_iter()
            .map(|(_, payload)| crate::Frame::encode(&payload, report_length))
            .collect())
    }
}

/// 配置档集合。至少保留一条。
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceProfileManager {
    profiles: Vec<DeviceProfile>,
    selected: usize,
}

impl Default for DeviceProfileManager {
    fn default() -> Self {
        Self {
            profiles: vec![DeviceProfile::default()],
            selected: 0,
        }
    }
}

impl DeviceProfileManager {
    #[must_use]
    pub fn new(profiles: Vec<DeviceProfile>, selected: usize) -> Self {
        let profiles = if profiles.is_empty() {
            vec![DeviceProfile::default()]
        } else {
            profiles
        };
        let selected = selected.min(profiles.len() - 1);
        Self { profiles, selected }
    }

    #[must_use]
    pub fn profiles(&self) -> &[DeviceProfile] {
        &self.profiles
    }

    #[must_use]
    pub fn selected_index(&self) -> usize {
        self.selected
    }

    #[must_use]
    pub fn selected(&self) -> &DeviceProfile {
        &self.profiles[self.selected]
    }

    pub fn select(&mut self, index: usize) {
        if index < self.profiles.len() {
            self.selected = index;
        }
    }

    /// 修改当前配置档。
    pub fn edit_selected(&mut self, body: impl FnOnce(&mut DeviceProfile)) {
        body(&mut self.profiles[self.selected]);
    }

    /// 新建一条配置档并选中它。
    pub fn add(&mut self, name: impl Into<String>) -> usize {
        let profile = DeviceProfile {
            name: name.into(),
            ..DeviceProfile::default()
        };
        self.profiles.push(profile);
        self.selected = self.profiles.len() - 1;
        self.selected
    }

    /// 复制当前配置档。同名自动加序号。
    pub fn duplicate_selected(&mut self) -> usize {
        let stem = strip_trailing_number(&self.profiles[self.selected].name);
        let mut copy = self.profiles[self.selected].clone();
        copy.name = unique_name(&stem, &self.profiles);
        self.profiles.push(copy);
        self.selected = self.profiles.len() - 1;
        self.selected
    }

    /// 删除当前配置档。至少保留一条，返回是否真的删了。
    pub fn delete_selected(&mut self) -> bool {
        if self.profiles.len() <= 1 {
            return false;
        }
        self.profiles.remove(self.selected);
        self.selected = self.selected.min(self.profiles.len() - 1);
        true
    }

    /// 当前配置档恢复出厂。
    pub fn reset_selected(&mut self) {
        let name = std::mem::take(&mut self.profiles[self.selected].name);
        self.profiles[self.selected] = DeviceProfile {
            name,
            ..DeviceProfile::default()
        };
    }
}

/// 去掉名字末尾的「 3」这类序号。
fn strip_trailing_number(name: &str) -> String {
    let trimmed = name.trim_end();
    match trimmed.rfind(' ') {
        Some(index)
            if trimmed[index + 1..].chars().all(|c| c.is_ascii_digit())
                && index + 1 < trimmed.len() =>
        {
            trimmed[..index].to_string()
        }
        _ => trimmed.to_string(),
    }
}

/// 在已有名字里找一个不冲突的。
fn unique_name(stem: &str, existing: &[DeviceProfile]) -> String {
    let taken = |candidate: &str| existing.iter().any(|p| p.name == candidate);
    let base = if stem.is_empty() {
        "配置".to_string()
    } else {
        stem.to_string()
    };

    let mut index = 2usize;
    let mut candidate = format!("{base} {index}");
    while taken(&candidate) {
        index += 1;
        candidate = format!("{base} {index}");
    }
    candidate
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::macro_cmd::MacroAction;

    #[test]
    fn 默认配置摊平成四条命令() {
        let commands = DeviceProfile::default().payloads().unwrap();
        assert_eq!(commands.len(), 4);
        let types: Vec<CommandType> = commands.iter().map(|(t, _)| *t).collect();
        assert_eq!(
            types,
            vec![
                CommandType::Dpi,
                CommandType::Lighting,
                CommandType::Parameter,
                CommandType::Buttons
            ]
        );
    }

    #[test]
    fn 有宏时每条宏追加一条命令() {
        let mut profile = DeviceProfile::default();
        profile.macros = vec![
            Macro::new(1),
            Macro {
                id: 2,
                ..Macro::new(2)
            },
        ];
        assert_eq!(profile.payloads().unwrap().len(), 6);
    }

    #[test]
    fn 超长的宏会让整份配置下发失败() {
        let mut profile = DeviceProfile::default();
        let mut big = Macro::new(1);
        big.actions = (0..80).map(|_| MacroAction::key_down(0x04)).collect();
        profile.macros = vec![big];
        assert!(profile.payloads().is_err());
    }

    #[test]
    fn 帧长度按报告长度补齐() {
        let frames = DeviceProfile::default().frames(64).unwrap();
        assert_eq!(frames.len(), 4);
        for frame in frames {
            assert_eq!(frame.len(), 64, "DPI/按键帧正好 64，灯光/轮询率应补零");
        }
    }

    #[test]
    fn 至少保留一条配置档() {
        let mut manager = DeviceProfileManager::default();
        assert!(!manager.delete_selected());
        manager.add("游戏");
        assert_eq!(manager.profiles().len(), 2);
        assert_eq!(manager.selected().name, "游戏");
        assert!(manager.delete_selected());
        assert_eq!(manager.profiles().len(), 1);
    }

    #[test]
    fn 复制配置档时同名自动加序号() {
        let mut manager = DeviceProfileManager::default();
        manager.edit_selected(|p| p.name = "配置 1".to_string());
        manager.duplicate_selected();
        assert_eq!(manager.selected().name, "配置 2");
        manager.duplicate_selected();
        assert_eq!(manager.selected().name, "配置 3");
    }

    #[test]
    fn 恢复出厂保留名字() {
        let mut manager = DeviceProfileManager::default();
        manager.edit_selected(|p| {
            p.name = "FPS".to_string();
            p.lighting.mode = crate::LightMode::Breathing;
        });
        manager.reset_selected();
        assert_eq!(manager.selected().name, "FPS");
        assert_eq!(manager.selected().lighting.mode, crate::LightMode::Neon);
    }

    #[test]
    fn 越界选中会被忽略() {
        let mut manager = DeviceProfileManager::new(vec![DeviceProfile::default()], 99);
        assert_eq!(manager.selected_index(), 0);
        manager.select(5);
        assert_eq!(manager.selected_index(), 0);
    }
}
