//! # INPHIC 鼠标 HID 协议
//!
//! IN10 / SDKT 平台的字节级协议实现。
//!
//! 这个 crate **不含任何 I/O**，只负责「把设置编码成字节」和「把上报解析成事件」。
//! 它同时是一份**可执行的协议规范** —— 每条结论都有对应的测试钉死。
//!
//! ## 帧格式
//!
//! ```text
//! [0]   0x04                 报告 ID
//! [1]   payload.len() + 5    整帧长度
//! [2]   0x00                 保留
//! [3..] payload              payload[0] = 命令码
//! [n+3] 校验和高字节           sum(bytes[0..n+3]) & 0xFFFF
//! [n+4] 校验和低字节
//! 其余补零至设备报告长度（IN10 为 64）
//! ```
//!
//! ## 实机确认的事实
//!
//! - 设备：`USB 1d57:fa65`「Inphic KP 8K」，复合设备，厂商配置接口 `PrimaryUsage 128`，
//!   `MaxOutputReportSize = MaxInputReportSize = 64`，`reportType = Output`
//! - 写入只认 `Output` 报告；官方二进制对 `0xfa60` 那一支用的是 `Feature`
//! - **鼠标睡着时会丢弃配置写入**（出厂深睡 5 分钟）。写入需要重试到生效，
//!   期间用鼠标移动来唤醒
//! - 输入报告：`Report ID 0` 是标准鼠标移动，`Report ID 3` 是厂商事件包
//!   （电量约每 2 秒一次，仅在鼠标醒着时）
//!
//! ## 来源
//!
//! | 来源 | 贡献 |
//! |---|---|
//! | 官方网页版 bundle | 帧结构、事件解析 |
//! | 官方 `WebDriver For Mac` 二进制反汇编 | VID/PID、reportType、命令码、校验和算法 |
//! | `signalrgb-inphic-in10` 实机抓包 | IN10 输出报告黄金向量 |
//! | 本机实测（2026-10-11） | 设备参数、输入报告、电量包、睡眠丢写 |

pub mod buttons;
pub mod checksum;
pub mod dpi;
pub mod event;
pub mod frame;
pub mod lighting;
pub mod macro_cmd;
pub mod profile;

pub use buttons::{ActionKind, ButtonAction, ButtonConfig, ButtonSlot};
pub use dpi::{DpiConfig, DpiStage};
pub use event::{BatteryStatus, MouseEvent, MouseMotion};
pub use frame::{CommandType, Frame};
pub use lighting::{LightMode, LightingConfig, ParameterCommand, PollingRate, Rgb};
pub use macro_cmd::{Macro, MacroAction, MacroTrigger};
pub use profile::{DeviceProfile, DeviceProfileManager};

/// 设备标识。与官方 `WebDriver For Mac` 的匹配字典一致。
pub mod device {
    /// 英菲克（杰理 Jieli）VID。
    pub const VENDOR_ID: i32 = 0x1D57;
    /// 1K 鼠标 / 2.4G 接收器。
    pub const PRODUCT_ID_1K: i32 = 0xFA60;
    /// 8K 鼠标（IN10）。
    pub const PRODUCT_ID_8K: i32 = 0xFA65;

    /// 厂商配置接口的 PrimaryUsage（usage page 0x0001）。
    pub const VENDOR_USAGE: i32 = 128;

    /// IN10 的固件内部型号码，出现在事件包的第 2 字节。
    pub const MODEL_ID_IN10: u8 = 0x93;

    /// 实测的输出报告长度。
    pub const REPORT_LENGTH: usize = 64;
}
