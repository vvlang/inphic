import Foundation
import Testing
@testable import InphicCore

// MARK: - 实机抓包黄金向量

/// 全部来自真机验证过的字节，不是推导出来的。
/// 来源见 `docs/PROTOCOL.md`。
@Suite("协议黄金向量")
struct ProtocolVectorTests {
    /// `David-Lzy/signalrgb-inphic-in10` 的 `tests/protocol-vectors.mjs`：
    /// RGB = (255, 0, 0) 时，65 字节输出报告的前 20 字节是硬编码断言，且已实机验证。
    @Test("灯光输出报告 — SignalRGB 实机向量")
    func lightingOutputReportMatchesCapture() {
        let configuration = LightingConfiguration(
            mode: .staticColor, speed: 6, brightness: 8,
            color: RGB(255, 0, 0), lightSleepMinutes: 0.5,
            deepSleepMinutes: 5, debounceMilliseconds: 3
        )
        let report = Frame.encode(payload: configuration.payload(), reportLength: 65)

        #expect(report.count == 65)
        let expected: [UInt8] = [
            0x04, 0x14, 0x00,
            0x05, 0x0F, 0x01, 0x10, 0x03, 0x58, 0xFF, 0x00, 0x00, 0x01, 0x03, 0x01, 0x6E, 0x00, 0x00,
            0x02, 0x0A,
        ]
        #expect(Array(report.prefix(20)) == expected)
        #expect(report.dropFirst(20).allSatisfy { $0 == 0 })
    }

    /// 官方 HUB 在全新 IN10 上发出的启动 profile：霓虹、纯蓝。
    @Test("灯光出厂 profile — 官方 HUB 启动抓包")
    func lightingFactoryProfileMatchesCapture() {
        let factory = LightingConfiguration()
        let payload = factory.payload()

        #expect(factory.mode == .neon)
        #expect(payload == [0x05, 0x0F, 0x01, 0x30, 0x03, 0x58, 0x00, 0x00, 0xFF, 0x01, 0x03, 0x01, 0x8E, 0x00, 0x00])
    }

    /// 该向量的两层校验和都与官方实现独立算出的结果一致。
    @Test("两层校验和")
    func checksumsMatchReference() {
        let configuration = LightingConfiguration(
            mode: .staticColor, speed: 6, brightness: 8,
            color: RGB(255, 0, 0), lightSleepMinutes: 0.5,
            deepSleepMinutes: 5, debounceMilliseconds: 3
        )
        let payload = configuration.payload()
        let report = [UInt8](Frame.encode(payload: payload, reportLength: 65))

        // 内层：profile[3..<11] 的大端和，即 report 坐标的 [6..<14)
        let inner = Checksum.sum16(report, in: 6..<14)
        #expect(UInt16(report[14]) << 8 | UInt16(report[15]) == inner)
        #expect(inner == 0x016E)

        // 外层：report[0..<18]（含报告 ID、长度、载荷）的大端和
        let outer = Checksum.sum16(report, in: 0..<18)
        #expect(UInt16(report[18]) << 8 | UInt16(report[19]) == outer)
        #expect(outer == 0x020A)
    }
}

// MARK: - 帧封装

@Suite("帧封装")
struct FrameTests {
    @Test("长度字段等于载荷 + 5")
    func lengthField() {
        for size in [9, 15, 56, 59, 111] {
            let frame = Frame.encode(payload: [UInt8](repeating: 0xAA, count: size), reportLength: 128)
            #expect(frame.count == 128)
            #expect(frame[1] == UInt8(size + 5))
        }
    }

    @Test("封装后可原样解回载荷")
    func roundTrip() throws {
        let payload = LightingConfiguration(color: RGB(1, 2, 3)).payload()
        let frame = Frame.encode(payload: payload, reportLength: 64)
        #expect(Frame.decode(frame) == payload)
    }

    @Test("校验和被篡改时拒绝解析")
    func rejectsCorruptedChecksum() {
        var frame = [UInt8](Frame.encode(payload: LightingConfiguration().payload(), reportLength: 64))
        frame[6] ^= 0xFF
        #expect(Frame.decode(Data(frame)) == nil)
    }

    @Test("载荷比报告长时返回更长的帧，绝不截断")
    func oversizedPayloadIsNotTruncated() {
        // 宏命令 111 字节载荷会超过 64 字节的报告长度，此时宁可发长帧也不能悄悄截断。
        let frame = Frame.encode(payload: [UInt8](repeating: 0, count: 100), reportLength: 64)
        #expect(frame.count == 105)
        #expect(Frame.decode(frame)?.count == 100)
    }

    @Test("补零到 64 与 65 两种报告长度都可用")
    func padsToReportLength() {
        let payload = ParameterCommand().payload()
        #expect(Frame.encode(payload: payload, reportLength: 64).count == 64)
        #expect(Frame.encode(payload: payload, reportLength: 65).count == 65)
    }
}

// MARK: - DPI

@Suite("DPI 编码")
struct DPITests {
    /// 官方 `za()`：`raw = (dpi - 50) / 50`，小端。
    @Test("DPI ↔ 原始值换算")
    func valueEncoding() {
        let cases: [(Int, UInt8, UInt8)] = [
            (50, 0, 0), (100, 1, 0), (800, 15, 0), (1600, 31, 0),
            (30000, 87, 2), (26000, 7, 2),
        ]
        for (dpi, low, high) in cases {
            #expect(DPIConfiguration.encodeValue(dpi).low == low)
            #expect(DPIConfiguration.encodeValue(dpi).high == high)
            #expect(DPIConfiguration.decodeValue(low: low, high: high) == dpi)
        }
    }

    @Test("载荷布局与校验位置")
    func payloadLayout() {
        var configuration = DPIConfiguration(activeStage: 2)
        configuration.stages[0].value = 1600
        let payload = configuration.payload()

        #expect(payload.count == 56)
        #expect(payload[0] == CommandType.dpi.rawValue)
        #expect(payload[1] == 56)
        #expect(payload[24] == 2)
        // 8 档全部启用 → 掩码 0xFF
        #expect(payload[5] == 0xFF)
        // 档 1 = 1600 → raw 31 = 0x1F
        #expect(payload[8] == 0x1F)
        #expect(payload[16] == 0x00)
        // 校验和覆盖 [3..<50]
        let expected = Checksum.sum16(payload, in: 3..<50)
        #expect(UInt16(payload[50]) << 8 | UInt16(payload[51]) == expected)
    }

    @Test("关闭某档后掩码对应位清零")
    func enabledMask() {
        var configuration = DPIConfiguration()
        configuration.stages[2].isEnabled = false
        configuration.stages[5].isEnabled = false
        #expect(configuration.enabledMask == 0b1101_1011)
    }

    @Test("始终输出 8 档，短输入会被补齐")
    func alwaysEightStages() {
        let configuration = DPIConfiguration(stages: [DPIStage(value: 800)])
        #expect(configuration.stages.count == DPILimit.stageCount)
        #expect(configuration.payload().count == 56)
    }
}

// MARK: - 灯光 / 轮询率

@Suite("灯光与轮询率")
struct LightingAndPollingTests {
    @Test("灯效模式存为高半字节")
    func modeNibble() {
        for mode in LightMode.allCases {
            #expect(mode.nibble >> 4 == mode.rawValue)
            #expect(mode.nibble & 0x0F == 0)
        }
    }

    @Test("深睡分钟拆到两个字节的高半字节")
    func deepSleepPacking() {
        let payload = LightingConfiguration(speed: 4, brightness: 3, deepSleepMinutes: 45).payload()
        #expect(payload[4] >> 4 == 2)   // 45 >> 4
        #expect(payload[5] >> 4 == 13)  // 45 & 0x0F
        #expect(payload[4] & 0x0F == 9 - 4)
        #expect(payload[5] & 0x0F == 3)
    }

    @Test("载荷可原样还原")
    func lightingRoundTrip() throws {
        let original = LightingConfiguration(
            mode: .breathing, speed: 2, brightness: 6, color: RGB(10, 20, 30),
            lightSleepMinutes: 2, deepSleepMinutes: 25, debounceMilliseconds: 8
        )
        let decoded = try #require(LightingConfiguration(payload: original.payload()))
        #expect(decoded == original)
    }

    @Test("轮询率编码表")
    func pollingTable() {
        let expected: [(PollingRate, UInt8)] = [
            (.hz125, 32), (.hz250, 16), (.hz500, 8), (.hz1000, 4),
            (.hz2000, 2), (.hz4000, 1), (.hz8000, 64),
        ]
        for (rate, raw) in expected {
            #expect(rate.firmwareValue == raw)
            #expect(PollingRate(firmwareValue: raw) == rate)
        }
    }

    @Test("轮询率载荷第 4 字节是取反校验")
    func pollingPayload() {
        let payload = ParameterCommand(pollingRate: .hz8000).payload()
        #expect(payload.count == 9)
        #expect(payload == [0x06, 0x09, 0x01, 0x40, 0xBF, 0x00, 0x00, 0x00, 0x00])
    }
}

// MARK: - 按键

@Suite("按键映射")
struct ButtonTests {
    @Test("18 个槽位，载荷 59 字节")
    func payloadShape() {
        let payload = ButtonConfiguration().payload()
        #expect(ButtonSlot.allCases.count == 18)
        #expect(payload.count == 59)
        #expect(payload[0] == CommandType.buttons.rawValue)
        #expect(payload[1] == 59)
    }

    @Test("出厂动作按槽位写入")
    func factoryActions() {
        var configuration = ButtonConfiguration()
        #expect(configuration[.leftClick].kind == .leftClick)
        #expect(configuration[.forward].kind == .forward)

        configuration[.forward] = ButtonAction(kind: .shortcut, modifier: 0x03, argument: 0x1C)
        let payload = configuration.payload()
        // 后退在槽位 6，前进在槽位 7
        #expect(payload[3 + 7 * 3] == 0x11)
        #expect(payload[3 + 7 * 3 + 1] == 0x03)
        #expect(payload[3 + 7 * 3 + 2] == 0x1C)
    }

    @Test("校验和覆盖 [3..<57]")
    func checksumRange() {
        let payload = ButtonConfiguration().payload()
        let expected = Checksum.sum16(payload, in: 3..<57)
        #expect(UInt16(payload[57]) << 8 | UInt16(payload[58]) == expected)
    }

    @Test("恢复出厂")
    func reset() {
        var configuration = ButtonConfiguration()
        configuration[.middleClick] = ButtonAction(kind: .browserHome)
        configuration.resetToFactory()
        #expect(configuration == ButtonConfiguration())
    }

    @Test("只有 5 个物理按键对用户开放")
    func userEditableSlots() {
        #expect(ButtonSlot.userEditable.count == 5)
        #expect(ButtonSlot.allCases.filter(\.isUserEditable).count == 5)
    }
}

// MARK: - 宏

@Suite("宏")
struct MacroTests {
    @Test("载荷 111 字节，第 1 字节是固件魔数 0x6F")
    func payloadShape() throws {
        let payload = try MacroCommand(macro: Macro(id: 1)).payload()
        #expect(payload.count == MacroCommand.payloadLength)
        #expect(payload[0] == CommandType.macro.rawValue)
        #expect(payload[1] == 0x6F)
    }

    @Test("按键按下 / 抬起用 0x01 / 0x80 区分")
    func keyEncoding() throws {
        let (data, count) = try MacroCommand.encodeActions([
            .keyDown(0x04), .keyUp(0x04),
        ])
        #expect(data == [10 | 0x01, 0x04, 10 | 0x80, 0x04])
        #expect(count == 2)
    }

    @Test("移动编码为大端 X / Y")
    func moveEncoding() throws {
        let (data, _) = try MacroCommand.encodeActions([.move(dx: -2, dy: 300, delay: 1)])
        #expect(data == [0x01, 0xF6, 0xFF, 0xFE, 0x01, 0x2C])
    }

    @Test("长延时拆成余数字节 + 追加组数")
    func longDelaySplit() throws {
        // 500 = 5×100 + 0，余数 0 会被官方实现补成 1
        let (data, count) = try MacroCommand.encodeActions([.keyDown(0x04, delay: 500)])
        #expect(data == [1 | 0x01, 0x04, 5, 0x03])
        #expect(count == 2)
    }

    @Test("纯等待编码为延时字节 + 0x03")
    func waitEncoding() throws {
        let (data, count) = try MacroCommand.encodeActions([.wait(milliseconds: 20)])
        #expect(data == [20, 0x03])
        #expect(count == 1)
    }

    @Test("超过固件上限时抛错")
    func rejectsOversizedMacro() {
        // 每个按键动作 2 字节，第 51 个动作让总量首次越过 100 字节上限
        let actions = (0..<80).map { _ in MacroAction.keyDown(0x04) }
        #expect(throws: MacroCommand.MacroError.tooManyActions(byteCount: 102)) {
            try MacroCommand.encodeActions(actions)
        }
    }

    @Test("校验和覆盖 [3..<109]")
    func checksumRange() throws {
        let payload = try MacroCommand(macro: Macro(id: 3, actions: [.keyDown(0x1C)])).payload()
        let expected = Checksum.sum16(payload, in: 3..<109)
        #expect(UInt16(payload[109]) << 8 | UInt16(payload[110]) == expected)
    }
}

// MARK: - 上行事件

@Suite("上行事件解析")
struct EventTests {
    /// ACK：`06 C0|C1 <status> 00 <csum>`，校验和 = `(4 + sum(bytes[0..<4])) & 0xFF`
    @Test("解析写入确认")
    func acknowledgement() {
        // status = 0x01 → 成功
        let success: [UInt8] = [0x06, 0xC0, 0x01, 0x00]
        var report = success
        report.append((4 &+ Checksum.sum8(success, in: 0..<4)))
        #expect(EventParser.parse(Data(report)) == .acknowledgement(isSuccess: true))

        let failure: [UInt8] = [0x06, 0xC1, 0x00, 0x00]
        var badReport = failure
        badReport.append((4 &+ Checksum.sum8(failure, in: 0..<4)))
        #expect(EventParser.parse(Data(badReport)) == .acknowledgement(isSuccess: false))
    }

    @Test("校验和不对时不误判为 ACK")
    func rejectsBadChecksum() {
        let report: [UInt8] = [0x06, 0xC0, 0x01, 0x00, 0xFF]
        #expect(EventParser.parse(Data(report)) == .unparsed(Data(report)))
    }

    @Test("解析电量上报")
    func battery() {
        #expect(EventParser.parse(Data([0x03, 0x00, 0x40, 0x03, 0x64]))
            == .battery(status: .charging, level: 100))
        #expect(EventParser.parse(Data([0x03, 0x00, 0x41, 0x01, 0x32]))
            == .battery(status: .normal, level: 50))
    }

    @Test("解析 DPI 循环事件")
    func dpiCycle() {
        #expect(EventParser.parse(Data([0x03, 0x00, 0x10, 0x04, 0x00])) == .dpiStageChanged(4))
    }

    @Test("偏移噪声不影响识别")
    func toleratesLeadingBytes() {
        // 部分链路前面会多一两个字节
        #expect(EventParser.parse(Data([0xAB, 0x03, 0x00, 0x40, 0x02, 0x0A]))
            == .battery(status: .full, level: 10))
    }

    @Test("非法组合被丢弃")
    func rejectsImplausible() {
        // 事件码 0x40 存在，但状态 0x09 不合法 → 不应误判成电量
        let report = Data([0x03, 0x00, 0x40, 0x09, 0x64])
        #expect(EventParser.parse(report) == .unparsed(report))
    }

    @Test("过短的包原样返回")
    func shortReport() {
        let report = Data([0x06, 0xC0])
        #expect(EventParser.parse(report) == .unparsed(report))
    }
}

// MARK: - 杂项

@Suite("工具")
struct UtilityTests {
    @Test("十六进制解析")
    func hexParsing() {
        #expect(Data.parseHex("04 14 00") == Data([0x04, 0x14, 0x00]))
        #expect(Data.parseHex("041400") == Data([0x04, 0x14, 0x00]))
        #expect(Data.parseHex("") == Data())
    }

    @Test("颜色往返")
    func colorRoundTrip() {
        let color = RGB(18, 52, 86)
        #expect(color.hexString == "#123456")
        #expect(RGB(hex: "#123456") == color)
        #expect(RGB(hex: "123456") == color)
        #expect(RGB(hex: "#FFF") == nil)
    }

    @Test("命令类型与官方反汇编一致")
    func commandTypes() {
        let expected: [(CommandType, UInt8)] = [
            (.dpi, 0x04), (.lighting, 0x05), (.parameter, 0x06),
            (.wirelessSetting, 0x07), (.buttons, 0x08), (.macro, 0x09), (.profileID, 0x0C),
        ]
        for (command, raw) in expected { #expect(command.rawValue == raw) }
        #expect(CommandType.allCases.count == 7)
    }
}
