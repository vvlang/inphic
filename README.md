# Inphic Hub for macOS

英菲克（INPHIC）鼠标的 macOS 设置程序。官方只提供 Windows 版 `INPHIC HUB.exe`
和一个网页版 `hub.inphic.cn`，Mac 上没有可用软件 —— 这个项目补上这块。

**非官方工具**，与英菲克无隶属关系。协议由对官方 Windows 驱动、macOS 驱动
与网页版的逆向分析得出。

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-000) ![license](https://img.shields.io/badge/license-MIT-blue) ![author](https://img.shields.io/badge/author-AIYeon-000)

---

## 功能

| 模块 | 说明 |
|---|---|
| DPI | 8 个档位，每档可单独启用并设定指示灯颜色 |
| 灯光 | 7 种灯效、RGB、亮度、速度（鼠标只有一个 RGB 区域，动态效果由固件生成） |
| 性能 | 轮询率 125–8000Hz（按连接方式自动封顶）、去抖时间、涟漪控制、角度吸附、Motion Sync、抬升距离 |
| 按键 | 5 个物理按键可改绑定，支持组合键、媒体键、浏览器、配置档切换 |
| 宏 | 录制 / 编辑、4 种触发方式、循环次数、可绑定到侧键 |
| 电源 | 浅睡 / 深睡时间、实时电量与充电状态 |
| 配置档 | 多档位方案，切换即整份下发，可导入导出 |

菜单栏常驻，可快速切换配置档与 DPI 档位。

## 支持的设备

已在 **IN10**（`1d57:fa65`，「Inphic KP 8K」）上实机验证。

英菲克 SDKT 平台的其他型号（IN9 / IN10 Pro / IN10 R / IN6 …）协议相同，
理论上直接可用，但**未逐一验证**。

## 安装

从 [Releases](https://github.com/vvlang/inphic/releases) 下载 `.dmg`，拖进「应用程序」。

首次打开需**右键 → 打开**（未做 Apple 公证与开发者签名）。

蓝牙功能需要在「系统设置 → 隐私与安全性 → 蓝牙」中授权。

## 从源码构建

```bash
git clone https://github.com/vvlang/inphic.git
cd inphic

./Scripts/build-app.sh release      # 产出 ~/Applications/InphicHub.app
./Scripts/make-dmg.sh               # 产出 dist/InphicHub-<version>.dmg
```

需要 Xcode 16+ 与 Swift 6。Rust 仅用于协议层测试，不参与 App 构建。

> ⚠️ 如果仓库放在同步盘（iCloud / 飞牛 / OneDrive 等）上，
> `.build` 会产生 AppleDouble 文件导致 codesign 失败。
> 用 `INPHIC_SCRATCH=/tmp/inphic-build` 把构建目录挪到本地盘。

## 项目结构

```
Sources/
  InphicCore/            协议编解码 + 传输层（无 UI，可单测）
    Protocol/            DPI、灯光、按键、宏、事件解析
    Transport/           IOHIDManager（USB / 2.4G）、CoreBluetooth（蓝牙）
    Config/              配置档模型、本地存储
  InphicHub/             SwiftUI 界面
  probe/                 命令行诊断工具
rust/crates/
  inphic-protocol/       协议层的 Rust 实现 —— 同时是一份「可执行的协议规范」
docs/
  PROTOCOL.md            字节级协议文档，每条结论标注来源与置信度
  reference/             参考素材（官方图标等）
```

`InphicCore`（Swift）与 `inphic-protocol`（Rust）是同一套协议的两次实现，
黄金向量测试互相印证。

## 探针

排查问题时先用 `probe`，它比 App 更容易观察底层行为：

```bash
swift build --scratch-path /tmp/inphic-build

./probe hid                                   # 枚举英菲克 HID 接口
./probe check                                 # 纯本地协议自检
./probe write --cmd lighting --r 255 --g 0 --b 0 --mode 1
./probe write --cmd dpi --dpi 1600
./probe write --cmd burst --interval 1 --count 20   # 连发，用于唤醒睡着的鼠标
```

## 已知限制

- **固件不支持读回设置。** 能读电量，但读不回 DPI / 灯光 / 按键 ——
  官方 macOS 驱动也是纯只写的（二进制里没有 `IOHIDDeviceGetReport`）。
  因此配置以本地为准，切换配置档即整份下发。
- **鼠标睡着时会静默丢弃写入**，而接口仍然返回成功。
  本工具检测到设备无上报时会自动重发，动一下鼠标即可唤醒。
- **蓝牙通道未实机验证。** macOS 不转发 HID SET_REPORT，蓝牙需要
  CoreBluetooth 直连外设（服务 `FEE3` / 特征 `FEE4`）。

协议细节与踩坑记录见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

## 致谢

- 应用图标取自官方 `Inphic_signed.pkg` 中的 `AppIcon.icns`，版权归英菲克所有。
- 协议参考了社区的逆向成果：
  [signalrgb-inphic-in10](https://github.com/David-Lzy/signalrgb-inphic-in10)、
  [inphic-in6-control-for-linux](https://github.com/JinOxide0/inphic-in6-control-for-linux)、
  [RuiShu1024/InphicMouse](https://github.com/RuiShu1024/InphicMouse)。

## 许可

MIT © 2026 AIYeon
