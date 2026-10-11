//! 黄金向量测试。
//!
//! 这里的每一个字节都来自**真机抓包**或**官方二进制反汇编**，不是推导出来的。
//! 它们是整个项目的地基：任何改动只要让这些测试挂掉，就说明协议实现跑偏了。

use inphic_protocol::checksum::hex_dump;
use inphic_protocol::event::{BatteryStatus, MouseEvent};
use inphic_protocol::lighting::{LightMode, LightingConfig, ParameterCommand, PollingRate, Rgb};
use inphic_protocol::{Frame, device};

/// `David-Lzy/signalrgb-inphic-in10` 的 `tests/protocol-vectors.mjs`：
/// RGB = (255, 0, 0) 时 65 字节输出报告的前 20 字节是硬编码断言，且已实机验证。
#[test]
fn 灯光输出报告匹配_signalrgb_实机向量() {
    let config = LightingConfig {
        profile_id: 1,
        mode: LightMode::Static,
        speed: 6,
        brightness: 8,
        color: Rgb::new(0xFF, 0x00, 0x00),
        light_sleep_minutes: 0.5,
        deep_sleep_minutes: 5,
        debounce_ms: 3,
    };
    let report = Frame::encode(&config.payload(), 65);

    assert_eq!(report.len(), 65);
    let expected: Vec<u8> = vec![
        0x04, 0x14, 0x00, 0x05, 0x0F, 0x01, 0x10, 0x03, 0x58, 0xFF, 0x00, 0x00, 0x01, 0x03, 0x01,
        0x6E, 0x00, 0x00, 0x02, 0x0A,
    ];
    assert_eq!(&report[..20], expected.as_slice());
    assert!(report[20..].iter().all(|&b| b == 0), "尾部必须补零");
}

/// 同一个向量的两层校验和，与官方实现独立算出的结果一致。
#[test]
fn 校验和与参考实现一致() {
    let config = LightingConfig {
        profile_id: 1,
        mode: LightMode::Static,
        speed: 6,
        brightness: 8,
        color: Rgb::new(0xFF, 0x00, 0x00),
        light_sleep_minutes: 0.5,
        deep_sleep_minutes: 5,
        debounce_ms: 3,
    };
    let report = Frame::encode(&config.payload(), 65);

    // 内层：profile[3..<11]，即报告坐标的 [6..<14)
    let inner = inphic_protocol::checksum::sum16(&report, 6..14);
    assert_eq!((u16::from(report[14]) << 8) | u16::from(report[15]), inner);
    assert_eq!(inner, 0x016E);

    // 外层：报告 [0..<18]，含报告 ID、长度与整个载荷
    let outer = inphic_protocol::checksum::sum16(&report, 0..18);
    assert_eq!((u16::from(report[18]) << 8) | u16::from(report[19]), outer);
    assert_eq!(outer, 0x020A);
}

/// 官方 HUB 在全新 IN10 上发出的启动 profile：霓虹、纯蓝。
/// 2026-10-11 在本机实测复现：这是鼠标出厂时的灯光状态。
#[test]
fn 出厂灯光profile匹配官方启动抓包() {
    assert_eq!(
        hex_dump(&LightingConfig::default().payload()),
        "05 0F 01 30 03 58 00 00 FF 01 03 01 8E 00 00"
    );
}

/// 本机实测：把灯光改成纯洋红后鼠标真的亮了（用户肉眼确认）。
/// 这个向量把「实机生效」也钉进测试。
#[test]
fn 洋红灯光帧与实测下发内容一致() {
    let config = LightingConfig {
        mode: LightMode::Static,
        color: Rgb::new(0xFF, 0x00, 0xFF),
        ..LightingConfig::default()
    };
    let report = Frame::encode(&config.payload(), device::REPORT_LENGTH);
    assert_eq!(
        hex_dump(&report[..20]),
        "04 14 00 05 0F 01 10 03 58 FF 00 FF 01 03 02 6D 00 00 03 09"
    );
}

/// 2026-10-11 本机抓到的电量输入报告（Report ID 3）。
#[test]
fn 解析实机电量报告() {
    let report = [0x03u8, 0x03, 0x93, 0x40, 0x01, 0x2E];
    assert_eq!(
        inphic_protocol::event::parse_report(&report),
        Some(MouseEvent::Battery {
            status: BatteryStatus::Normal,
            level: 46
        })
    );
}

/// 2026-10-11 本机抓到的标准鼠标移动报告（Report ID 0）。
#[test]
fn 解析实机鼠标移动报告() {
    use inphic_protocol::event::parse_motion;

    let motion = parse_motion(&[0x00, 0x14, 0x00, 0xFD, 0xFF, 0x00, 0x00]).unwrap();
    assert_eq!((motion.dx, motion.dy), (20, -3));

    let motion = parse_motion(&[0x00, 0x6A, 0x00, 0xEB, 0xFF, 0x00, 0x00]).unwrap();
    assert_eq!((motion.dx, motion.dy), (106, -21));
}

/// 实机参数：IN10 就是 1d57:fa65「Inphic KP 8K」，报告 64 字节，型号码 0x93。
#[test]
fn 设备参数与实机一致() {
    assert_eq!(device::VENDOR_ID, 0x1D57);
    assert_eq!(device::PRODUCT_ID_8K, 0xFA65);
    assert_eq!(device::VENDOR_USAGE, 128);
    assert_eq!(device::REPORT_LENGTH, 64);
    assert_eq!(device::MODEL_ID_IN10, 0x93);
}

/// 轮询率载荷：`06 09 01 40 BF …`，第 4 字节是第 3 字节的取反。
#[test]
fn 轮询率载荷匹配参考实现() {
    let command = ParameterCommand {
        profile_id: 1,
        polling_rate: PollingRate::Hz8000,
    };
    assert_eq!(hex_dump(&command.payload()), "06 09 01 40 BF 00 00 00 00");
}

/// 端到端：配置档 → 命令 → 报告帧，长度全部对得上设备。
#[test]
fn 整份配置下发时的帧长度() {
    use inphic_protocol::DeviceProfile;

    let frames = DeviceProfile::default()
        .frames(device::REPORT_LENGTH)
        .unwrap();
    assert_eq!(frames.len(), 4);
    for frame in &frames {
        assert_eq!(frame.len(), device::REPORT_LENGTH);
        assert_eq!(frame[0], Frame::REPORT_ID);
    }

    // 命令顺序：先 DPI，再灯光，再轮询率，最后按键
    assert_eq!(frames[0][3], 0x04);
    assert_eq!(frames[1][3], 0x05);
    assert_eq!(frames[2][3], 0x06);
    assert_eq!(frames[3][3], 0x08);
}
