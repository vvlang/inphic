# INPHIC 鼠标 HID 协议（IN10 / SDKT 平台）

本文档记录本项目实现的字节级协议。**每一条结论都有来源标注**，分为三档：

- ✅ **实机验证** —— 有真机抓包或实机跑通记录
- 🔬 **二进制确认** —— 从官方 `WebDriver For Mac` 的 Mach-O 二进制里解码出来
- 📄 **交叉验证** —— 第三方同平台实现，与前两者逐字节吻合

---

## 0. 生态结构

`hub.inphic.cn` **不是**完整产品，它只是前端：

```
Chrome ──ws://localhost:10085(HEX 帧)──▶ 原生守护进程 ──▶ IOHIDManager / CoreBluetooth ──▶ 鼠标固件
```

官方在 `hub.inphic.cn/downloads/Inphic_signed.pkg` 里发布该守护进程
（`JluTech.WebDriverForMac`，`LSUIElement`，x86_64 + arm64，macOS 11.5+）。
内部类：`JLUMacHid`(1K) / `JLUMacHid8K` / `JLUMacHidD8K` / `JLUMacHidWire` / `JLUBluetoothManager`。

因此**网页端脱离原生进程无法工作**；它遗留的 WebHID 分支（`device.sendReport(4, …)`）里
`device` 从未定义，是工厂模式的死代码。

本项目不复用 WebSocket，单进程内直接走 HID / BLE。

---

## 1. 设备标识

| 项 | 值 | 来源 |
|---|---|---|
| USB VendorID | `0x1D57`（7511，杰理 Jieli） | 🔬 从二进制 `__DATA_CONST,__objc_dictobj` 的匹配字典解码，并由 `__TEXT,__const` 常量池二次印证 |
| ProductID `0xFA60` | 1K 鼠标 / 2.4G 接收器 / D8K | 🔬 同上 |
| ProductID `0xFA65` | 8K 鼠标（IN10） | 🔬 同上 |
| 厂商 HID 接口 | Usage Page `0xFF00`，Usage `0x0001`（Windows 记作 `COL04`，Linux 记作接口 3 / index 2） | ✅ SignalRGB 插件 `Validate()` 断言 |
| 报告 ID | `0x04`（写在报告首字节内） | ✅ 实机抓包 |
| 报告长度 | 64 或 65 字节（固件不同），运行时读 `MaxOutputReportSize` / `MaxFeatureReportSize` | 🔬 二进制栈上帧长 `0x40`；✅ SignalRGB 写 65 |
| 固件内部型号码 | IN10 = `147`(0x93) | 📄 `hub.js` |

### HID 报告类型（🔬 二进制确认）

官方四个 `IOHIDManager` 各有独立匹配字典，且 `reportType` 编码直接可见：

| PID | 官方类 | reportType |
|---|---|---|
| `0xFA60` | `JLUMacHid` | `2` = `kIOHIDReportTypeFeature` |
| `0xFA60` | `JLUMacHidD8K` | `2` = Feature |
| `0xFA65` | `JLUMacHid8K` | `1` = `kIOHIDReportTypeOutput` |
| （仅 VID） | `JLUMacHidWire` | `2` = Feature |

官方匹配字典**不含** PrimaryUsage/PrimaryUsagePage，只按 VID+PID。
本实现在匹配时额外加上 Usage Page `0xFF00`，避免误开复合设备的 Boot 接口。

> **注意**：官方二进制从未 import `IOHIDDeviceGetReport` —— 守护进程对鼠标是**只写**的。
> 也就是说官方 macOS 版**读不回**当前配置。

---

## 2. 写帧

📄 参考实现 + ✅ 实机验证

```
[0]      0x04                    报告 ID
[1]      payload.count + 5       整帧长度
[2]      0x00                    保留
[3…]     payload                  payload[0] = 命令类型
[n+3]    校验和高字节              sum(bytes[0..<n+3]) & 0xFFFF
[n+4]    校验和低字节
其余补零至设备报告长度
```

### 命令类型（🔬 从 `sendDataToFW:linkedType:deviceID:` 的 cmp/b.eq 分派链解码）

分派键是 `data[0]`，共 **7** 个，其余一律静默丢弃：

| `data[0]` | 命令 | 载荷长度 |
|---|---|---|
| `0x04` | dpi | 56 |
| `0x05` | lighting | 15 |
| `0x06` | param / 轮询率 | 9 |
| `0x07` | Wireless Setting | — |
| `0x08` | button | 59 |
| `0x09` | macro | 111 |
| `0x0C` | Profile ID | — |

> 官方二进制里 wire 通道的 `0x06` 分支误用了 `8K send param` 日志串，是厂商复制粘贴的 bug，
> 仅影响日志，不影响协议。

### 校验和

大端 16 位累加和。**每条命令自带两层**：

| 位置 | 范围 |
|---|---|
| 载荷内 | `0x04`: [3..<50] → [50..51]<br>`0x05`: [3..<11] → [11..12]<br>`0x08`: [3..<57] → [57..58]<br>`0x09`: [3..<109] → [109..110] |
| 外层帧 | [0..<length-2] → [length-2..length-1] |

🔬 二进制里 `rev32(acc) >> 16` + `sturh`（小端存 u16）等价于上面的「大端存」——
`rev32` 把累加器的字节序翻转后再取高 16 位，落盘就是大端。

---

## 3. DPI 命令 `0x04`（载荷 56 字节）

```
[0]      0x04
[1]      56
[2]      profileId
[3]      liftOffDistance    0 = 1mm, 1 = 2mm
[4]      ripple             涟漪控制
[5]      enabledMask        启用档位位掩码
[6]      angleSnap          角度吸附
[7]      motionSync
[8..23]  8 档 DPI，小端 uint16
[24]     activeStage        当前档位 1–8
[25..48] 8 档指示色 RGB
[49]     indicationType
[50..51] 校验和
```

**DPI 编码**：`raw = (dpi - 50) / 50`，小端 uint16。反函数 `dpi = 50 + 50 × raw`。
范围 50–30000。

**出厂档位**：800 / 1600 / 3200 / 6500 / 13000 / 30000 …
**出厂指示色**：黄 / 青 / 绿 / 品红 / 蓝 / 红 / 橙 / 白

> 📄 另有一套 IN9 系（33 字节）的 DPI↔寄存器换算表，按传感器 `ic_type` 分支
> （见 `RuiShu1024/InphicMouse` 的 `docs/hid-protocol.md`）。IN10 走本文档的线性换算，
> 已由实机向量证实。

---

## 4. 灯光 / 电源 / 响应时间 `0x05`（载荷 15 字节）

固件把三组设置合并在同一条命令里，**改任意一项都必须带上其余项的当前值**。

```
[0]      0x05
[1]      15
[2]      profileId
[3]      mode << 4
[4]      (deepSleepHigh << 4) | (9 - speed)
[5]      (deepSleepLow  << 4) | brightness
[6..8]   R, G, B
[9]      浅睡分钟 × 2
[10]     按键响应时间 ms
[11..12] 校验和（覆盖 [3..<11]）
[13..14] 保留 0
```

**灯效模式**（存 `index << 4`）：`off=0, static=1, breathing=2, neon=3,
cycleBreathing=4, staticDPI=5, breathingDPI=6`

**深睡分钟** = `(payload[4] >> 4) * 16 + (payload[5] >> 4)`
**亮度** = `payload[5] & 0x0F`（1–8）　**速度** = `9 - (payload[4] & 0x0F)`（1–8）

### ✅ 实机黄金向量

`David-Lzy/signalrgb-inphic-in10` 的 `tests/protocol-vectors.mjs` 里是硬编码断言，且插件在真机上跑通：

```
RGB = (255, 0, 0) → 65 字节输出报告前 20 字节：

04 14 00  05 0F 01 10 03 58 FF 00 00 01 03 01 6E 00 00  02 0A
│  │  │   │  │  │  │  │  │  │  │  │  │  │  │  └─ 内层校验和 = sum(report[6..<14]) = 0x016E
│  │  │   │  │  │  │  │  │  │  │  │  │  │  └──── 保留 0
│  │  │   │  │  │  │  │  │  │  │  │  └─────── 内层校验和高字节
│  │  │   │  │  │  │  │  │  │  │  └────────── 响应时间 = 3ms
│  │  │   │  │  │  │  │  │  │  └───────────── 浅睡 = 0.5 分钟
│  │  │   │  │  │  │  │  │  └─────────────── B = 0
│  │  │   │  │  │  │  │  └────────────────── G = 0
│  │  │   │  │  │  │  └───────────────────── R = 255
│  │  │   │  │  │  └──────────────────────── 亮度 8 (0x58 低半字节)
│  │  │   │  │  └────────────────────────── 速度 6 → 9-6=3 (0x03 低半字节)
│  │  │   │  └───────────────────────────── 深睡 = 5 分钟 (0x58 高半字节)
│  │  │   └──────────────────────────────── 灯效 = static (0x10)
│  │  └──────────────────────────────────── profileId = 1
│  └─────────────────────────────────────── 载荷长度 = 15
└────────────────────────────────────────── 保留 0
                                             （以上为 payload，帧首 3 字节为 04 14 00）

外层校验和 = sum(report[0..<18]) = 0x020A
```

对应的出厂 profile（官方 HUB 在全新 IN10 上发出的启动帧）：
`05 0F 01 30 03 58 00 00 FF 01 03 01 8E 00 00`
——霓虹、纯蓝、亮度 8、速度 6、浅睡 0.5 分钟、深睡 5 分钟、响应 3ms。

> 这两个向量是 `ProtocolVectorTests` 的断言来源，**逐字节比对，不是重新推导**。

---

## 5. 轮询率 `0x06`（载荷 9 字节）

```
[0] 0x06   [1] 9   [2] profileId   [3] raw   [4] ~raw   [5..8] 0
```

| Hz | raw | | Hz | raw |
|---|---|---|---|---|
| 125 | 32 | | 1000 | 4 |
| 250 | 16 | | 2000 | 2 |
| 500 | 8 | | 4000 | 1 |
| | | | **8000** | **64** |

注意 8000Hz 的 raw 是 64，**不是**单调递增。

---

## 6. 按键映射 `0x08`（载荷 59 字节）

`profileId` + **18 个槽位 × 3 字节** `[类型, v1, v2]` + 校验和 `[57..58]`。

槽位顺序（官方 `Zce`）：左、右、中、DPI循环、DPI+、DPI−、后退、前进、模式键、
7 个保留位、滚轮下、滚轮上。
**只有前 5 个物理按键（左/右/中/前/后）在官方 UI 里可改。**

动作类型：

| 值 | 含义 | v1 / v2 |
|---|---|---|
| 1 | 关闭 | — |
| 2–4 | 左键 / 右键 / 中键 | — |
| 5–6 | 后退 / 前进 | — |
| 7–8 | 双击 / 连发 | — |
| 9–12 | 滚轮下 / 滚轮上 / 倾斜左 / 倾斜右 | — |
| 13–15 | DPI 循环 / 加 / 减 | — |
| 16 | EasyAim | `v1=0, v2=3` |
| **17** | **快捷键** | `v1` = 修饰键掩码，`v2` = HID usage |
| **18** | **宏** | `v2` = 宏编号 |
| 21–30 | 媒体播放 / 上一首 / 下一首 / 播放暂停 / 停止 / 静音 / 音量± / 计算器 / 邮件 | — |
| 32–38 | 浏览器 前进/后退/刷新/主页/搜索 | 部分带参数 |
| 52–54 | 配置档 循环 / 上 / 下 | — |
| 60 | 模式键 | — |

**修饰键掩码**：`Ctrl=0x01, Shift=0x02, Alt=0x04, GUI(Cmd)=0x08`

---

## 7. 宏 `0x09`（载荷 111 字节）

```
[0]      0x09
[1]      111 (0x6F)      ← 二进制以此判定「整条下发」而非分片
[2]      macroId (1 起)
[3]      trigger
[4..6]   RGB
[7]      loops
[8]      eventCount
[9…]     事件流（最多 100 字节）
[109..110] 校验和（覆盖 [3..<109]）
```

**触发方式**：`0` 循环播放 · `1` 任意键停止 · `2` 按住播放 · `3` 宏键停止

**事件流编码**：

| 动作 | 字节 |
|---|---|
| 按键按下 | `[delay \| 0x01, usage]` |
| 按键抬起 | `[delay \| 0x80, usage]` |
| 相对移动 | `[delay, 0xF6, x_hi, x_lo, y_hi, y_lo]` |
| 纯等待 | `[delay, 0x03]` |
| 延时 > 127ms | 延时字节改用 `delay % 100`（为 0 时补 1），并追加 `[delay / 100, 0x03]` |

`usage` 是 HID Keyboard/Keypad page (0x07) 的 usage id。

> ⚠️ `0x09` 在 `data[1] != 0x6F` 时官方会走 **3 × 64 字节分片**（步长 0x3C，第 3 片
> 把帧头改写成 `0xC09`）。IN10 的 111 字节载荷走 `0x6F` 分支，单帧即可；
> 但 116 字节的帧**超过 64 字节的报告长度**，需要实机确认固件接受长帧，
> 否则要按官方方式分片。**这一条尚未验证。**

---

## 8. 上行事件（Input Report）— ✅ 实机确认

厂商配置接口（`PrimaryUsage 128`）同时承载**两个** Report ID：

| Report ID | 内容 | 频率 |
|---|---|---|
| `0` | 标准鼠标移动 `X_lo X_hi Y_lo Y_hi buttons wheel` | 鼠标一动就发 |
| `3` | 厂商事件包 | 电量约每 2 秒一次 |

### 事件包（Report ID 3，len = 5）

```
03 93 40 01 2E
│  │  │  │  └── 电量百分比
│  │  │  └───── 充电状态：1 正常 / 2 已满 / 3 充电
│  │  └──────── 事件码
│  └─────────── 固件型号码，IN10 = 0x93
└────────────── 固定 0x03
```

事件码：

| 事件码 | 含义 | p1 | p2 |
|---|---|---|---|
| `0x40` / `0x41` | 电量 | 1=正常 2=已满 3=充电 | 百分比 0–100 |
| `0x50` | 写入确认 | 0 = 成功 | 命令码 |
| `0x10` | DPI 循环事件 | 档位 1–8 | — |
| `0x11` | 震动 | — | — |
| `0x80` | 配置档切换 | — | — |

部分链路前面会多出 1–2 字节，故解析时按偏移 2 / 3 / 4 依次探测。
电量事件要求 `p1 ∈ 1...3` **且** `p2 ≤ 100` 同时成立 —— 这是唯一可靠的过滤器。

### ⚠️ 两个 macOS 特有的坑（都不报错，静默失败）

**坑 1：回调必须注册在设备上，不能注册在 manager 上。**

`IOHIDManagerRegisterInputReportCallback` 只投递 Report ID 0（鼠标移动），
Report ID 3 的厂商事件包（电量 / DPI 档位）**根本收不到**。
必须用 `IOHIDDeviceRegisterInputReportCallback`，且要先挑出配置接口再注册。

**坑 2：HID 管理器必须挂在独立线程的 run loop 上。**

`IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), …)` 在 SwiftUI / AppKit
App 里**收不到任何输入报告** —— 设备能打开、能写，但一个上行包都不来。
同一份代码在 CLI 里（手动泵 run loop）完全正常。

→ 必须 `Thread { … }` + 该线程自己的 run loop，并在里面 `IOHIDManagerOpen`。

这两个坑叠在一起，表现就是「能写、能显示连接，但永远没有电量」。

### 写入确认

```
06 C0|C1 <status> 00 <csum8>        status: 0x01 = 成功, 0x00 = 失败
```

校验和 = `(4 + sum(bytes[0..<4])) & 0xFF`

> ⚠️ **实测中从未收到过 ACK 帧。** 上行只有电量包。所以判断「写入是否生效」
> 不能靠 ACK，只能靠见下一节。

---

## 9. ⚠️ 鼠标睡着会静默丢弃写入 — ✅ 实机确认

**这是本协议最大的坑。**

| 观察 | 说明 |
|---|---|
| `IOHIDDeviceSetReport` 返回 | `0x0`（成功） |
| 固件是否执行 | **不执行** |
| 电量上报 | 停止（鼠标睡着时一个包都不发） |
| 出厂深睡时间 | 5 分钟 |

实测：单发一帧纯绿灯光 → 返回成功 → 灯没反应。
改成每 1 秒连发 20 帧（期间动鼠标）→ 灯立刻变紫。

### 唤醒判据

**输入报告本身就是信号。** 鼠标醒着时每 2 秒发一次电量包，睡着时一个都不发。

```
写一帧
  ↓
3 秒内有新上报？ → 是 → 写成功，收工
  ↓ 否
每 500ms 重发，最多 15 次；一旦有上报立刻停止
```

实现见 `Sources/InphicCore/Config/DeviceController.swift` 的 `send(_:via:)`。

> 排查「写不进去」时，**先排除鼠标睡眠**，再怀疑帧格式 / 通道 / 报告 ID。
> IOReturn 返回成功极具误导性。

---

## 10. 蓝牙通道

🔬 二进制确认：`JLUBluetoothManager` 只用到三个 16 位 UUID

| UUID | 角色 |
|---|---|
| `FEE3` | 服务 |
| `FEE4` | 可写特征（写入目标） |
| `180A` | Device Information，**仅**用于 `scanForPeripheralsWithServices:` 过滤 |

> 二进制里另有一串 `SKTCUNVEW` 的 ASCII——**不是 BLE UUID**。
> 它落在 `__TEXT,__const` 的一段未被任何指令引用的死数据里
> （枚举了全部 39 个 `adrp`/`add` 落点确认）。

### macOS 上的关键坑

BLE HID 外设一旦被系统 bond，**扫描到的 `CBPeripheral` 与系统持有的不是同一个实例**，
直接 `connect()` 会在 ATT 层「成功」但写入静默失败。
→ 启动时先 `retrieveConnectedPeripherals(withServices: [FEE3, 1812])`，命中就认领系统已有的那个实例。

你的 IN10 在系统里**没有可用的 GAP 名称**（显示为 `Product = "BTM"`），
所以识别只能靠服务指纹 + 记住过的 `CBPeripheral.identifier`，不能靠名字。

IN10 的 BLE 报告描述符（`ioreg` 实测）：

```
Usage Page 0xFF00 / Usage 0x48 (Mouse), Collection Application
  Usage Page 0xFF29, Report ID 1: 2 × 8-bit
  Collection Feature:
    Report ID 2, Usage 0x25: 3 × 8-bit + 4 × 8-bit
MaxInputReportSize = 2004   MaxFeatureReportSize = 144   ReportInterval = 8000
```

⚠️ **尚未确认**：写 FEE4 是否需要分包、以及系统占用的那条链路是否影响我们这条。
→ Spike 0 的核心任务。

---

## 11. 待验证清单

### ✅ 已验证
- [x] `probe hid` 枚举到 IN10（`1d57:fa65`，4 个接口，用 `MaxOutputReportSize > 0` 挑出配置通道）
- [x] 灯光写入生效（用户肉眼确认变紫）
- [x] 电量读取（`03 93 40 01 2E` → 46%）
- [x] 鼠标移动报告解析

### ⬜ 未验证
- [ ] DPI / 轮询率 / 按键映射 / 宏 的实机效果（各自需要肉眼或手感确认）
- [ ] 111 字节宏帧是否被 64 字节报告长度的固件接受，否则按 3× 分片
- [ ] 蓝牙 FEE4 写入是否生效（BLE 完全未测）
- [ ] **设置读回协议未知** —— 官方 macOS 守护进程是只写的（二进制里没有 `GetReport`）。
      电量能读，但 DPI / 灯光 / 按键读不回来。IN9 系有 `0x1X` 读命令，
      IN10 是否同构需要抓包确认。

---

## 附：参考来源

| 来源 | 贡献 |
|---|---|
| `hub.inphic.cn` 前端 bundle（`/tmp/hub.js`） | 帧结构、ACK / 电量 / DPI 事件解析、完整功能清单 |
| 官方 `Inphic_signed.pkg` → `WebDriver For Mac` | VID/PID、reportType、BLE UUID、7 个命令码、校验和算法 |
| [David-Lzy/signalrgb-inphic-in10](https://github.com/David-Lzy/signalrgb-inphic-in10) | **IN10 实机抓包** + 硬编码断言的黄金向量 |
| [JinOxide0/inphic-in6-control-for-linux](https://github.com/JinOxide0/inphic-in6-control-for-linux) | 同 SDKT 平台的完整 Python 编码器 |
| [RuiShu1024/InphicMouse](https://github.com/RuiShu1024/InphicMouse) | IN9 系 33 字节旧协议文档，含 DPI↔寄存器换算表 |
