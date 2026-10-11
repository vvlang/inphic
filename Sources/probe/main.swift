import Foundation
import InphicCore

// MARK: - 命令行

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

/// 同时支持 `--key value` 与 `--key=value`。
let flags: [String: String] = {
    var result: [String: String] = [:]
    var pendingKey: String?
    for argument in arguments.dropFirst() {
        if argument.hasPrefix("--") {
            let body = argument.dropFirst(2)
            if let equals = body.firstIndex(of: "=") {
                result[String(body[..<equals])] = String(body[body.index(after: equals)...])
                pendingKey = nil
            } else {
                pendingKey = String(body)
            }
        } else if let key = pendingKey {
            result[key] = argument
            pendingKey = nil
        }
    }
    if let key = pendingKey { result[key] = "true" }
    return result
}()

func flag(_ key: String, default defaultValue: String) -> String { flags[key] ?? defaultValue }
func section(_ title: String) { print("\n\u{1B}[1m── \(title) ──\u{1B}[0m") }

/// 在主线程上泵事件循环，直到异步操作完成。
///
/// CLI 里没法直接 `await`，而 IOHIDManager / CoreBluetooth 的回调都挂在主 run loop 上，
/// 所以必须一边等一边转 run loop。
func pump<T>(timeout: TimeInterval = 5, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    Task {
        do { box.set(.success(try await operation())) }
        catch { box.set(.failure(error)) }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while box.isEmpty, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return try box.take()
}

final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    var isEmpty: Bool { lock.withLock { result == nil } }

    func set(_ value: Result<T, Error>) { lock.withLock { result = value } }

    func take() throws -> T {
        let value = lock.withLock { result }
        guard let value else { throw TransportError.transportUnavailable("操作超时") }
        return try value.get()
    }
}

// MARK: - 设备枚举

func enumerateHID() {
    let entries = IOHIDManagerProbe.enumerate(vendorID: HIDTransport.vendorID, productID: HIDTransport.productID8K)
    section("HID 设备 — VID 0x\(String(format: "%04X", HIDTransport.vendorID))")
    guard !entries.isEmpty else {
        print("未找到任何英菲克设备。请检查 USB 连接或 2.4G 接收器是否插好。")
        return
    }
    for entry in entries {
        let marker = entry.isConfigurationInterface ? "\u{1B}[32m◀ 厂商配置通道\u{1B}[0m" : "  (无 Output 报告，不可配置)"
        print("\(entry.summary)\n\(marker)")
    }
}

// MARK: - 编码自检

func selfCheck() {
    section("灯光载荷 — 对照 SignalRGB 实机抓包")

    let captured = LightingConfiguration(
        mode: .staticColor, speed: 6, brightness: 8,
        color: RGB(255, 0, 0), lightSleepMinutes: 0.5,
        deepSleepMinutes: 5, debounceMilliseconds: 3
    )
    let frame = Frame.encode(payload: captured.payload(), reportLength: 65)
    print("输出报告 (65 字节):")
    print("  \(frame.hexDump)")
    print("")
    print("抓包原文:  04 14 00 05 0F 01 10 03 58 FF 00 00 01 03 01 6E 00 00 02 0A …")

    section("各命令载荷")
    let commands: [(String, [UInt8])] = [
        ("DPI   0x04", DPIConfiguration().payload()),
        ("灯光  0x05", LightingConfiguration().payload()),
        ("性能  0x06", ParameterCommand().payload()),
        ("按键  0x08", ButtonConfiguration().payload()),
    ]
    for (name, payload) in commands {
        print(String(format: "  %@  载荷 %3d 字节  帧 %3d 字节", name, payload.count, payload.count + 5))
    }
    if let macro = try? MacroCommand(macro: Macro(id: 1, actions: [.keyDown(0x04)])).payload() {
        print(String(format: "  宏    0x09  载荷 %3d 字节  帧 %3d 字节", macro.count, macro.count + 5))
    }
    print("")
    print("命令类型: " + CommandType.allCases.map { String(format: "0x%02X", $0.rawValue) }.joined(separator: " "))
}

// MARK: - 下发

/// 打印上报事件，便于确认设备是否真的收到了命令。
func listen(to transport: HIDTransport, seconds: TimeInterval) {
    Task {
        for await event in transport.events {
            switch event {
            case let .battery(status, level):
                print("   ← 电量 \(level)% (\(status))")
            case let .acknowledgement(isSuccess):
                print("   ← 写入确认: \(isSuccess ? "成功" : "失败")")
            case let .dpiStageChanged(stage):
                print("   ← DPI 切到第 \(stage) 档")
            case let .vibration(value):
                print("   ← 震动 \(value)")
            case let .profileChanged(value):
                print("   ← 配置档 \(value)")
            case let .vendor(code, p1, p2):
                print("   ← 厂商事件 0x\(String(code, radix: 16)) (\(p1), \(p2))")
            case let .unparsed(data):
                print("   ← 未识别: \(data.hexDump)")
            }
        }
    }
    CFRunLoopRunInMode(.defaultMode, seconds, true)
}

func connectedTransport() throws -> HIDTransport {
    let transport = HIDTransport()
    transport.start()
    CFRunLoopRunInMode(.defaultMode, 1.5, true)
    guard let device = transport.device else {
        throw TransportError.notConnected
    }
    print("已连接: \(device.name) [\(device.kind.title)] \(String(format: "%04X:%04X", device.vendorID, device.productID)) 报告长度 \(device.reportLength)")
    listen(to: transport, seconds: Double(flag("listen", default: "2")) ?? 2)
    return transport
}

func writePayload(_ transport: HIDTransport, _ payload: [UInt8], expectation: String) {
    let frame = Frame.encode(payload: payload, reportLength: transport.device?.reportLength ?? 64)
    print("载荷 (\(payload.count)): \(Data(payload).hexDump)")
    print("帧   (\(frame.count)): \(frame.hexDump)")
    do {
        let acknowledged = try pump { try await transport.send(payload: payload) }
        print(acknowledged ? "✅ 已写入 — \(expectation)" : "⚠️  写入未被外设确认 — \(expectation)")
    } catch {
        print("❌ \(error.localizedDescription)")
    }
}

func runWriteCommand() {
    let transport: HIDTransport
    do { transport = try connectedTransport() }
    catch {
        print("❌ \(error.localizedDescription)")
        print("   先跑 `probe hid` 看看枚举到了什么。")
        return
    }
    defer { transport.stop() }

    if flag("cmd", default: "lighting") == "burst" {
        let r = UInt8(flag("r", default: "0")) ?? 0
        let g = UInt8(flag("g", default: "255")) ?? 255
        let b = UInt8(flag("b", default: "0")) ?? 0
        let interval = Double(flag("interval", default: "1")) ?? 1
        let total = Double(flag("count", default: "20")) ?? 20
        let payload = LightingConfiguration(
            mode: LightMode(rawValue: UInt8(flag("mode", default: "1")) ?? 1) ?? .staticColor,
            color: RGB(r, g, b)
        ).payload()
        print("连发 \(Int(total)) 帧，间隔 \(interval)s —— 请在此期间不停移动/点击鼠标")
        for step in 0..<Int(total) {
            do {
                let ok = try pump { try await transport.send(payload: payload) }
                print("  [\(step + 1)/\(Int(total))] \(ok ? "已写入" : "未确认")")
            } catch {
                print("  [\(step + 1)/\(Int(total))] ❌ \(error.localizedDescription)")
            }
            CFRunLoopRunInMode(.defaultMode, interval, true)
        }
        return
    }

    if flag("cmd", default: "lighting") == "profile" {
        // 复现 App 的「下发当前配置」：整份配置按 DPI → 灯光 → 轮询率 → 按键 顺序发
        var profile = DeviceProfile()
        profile.lighting = LightingConfiguration(
            mode: LightMode(rawValue: UInt8(flag("mode", default: "1")) ?? 1) ?? .staticColor,
            color: RGB(UInt8(flag("r", default: "0")) ?? 0,
                       UInt8(flag("g", default: "255")) ?? 255,
                       UInt8(flag("b", default: "0")) ?? 0)
        )
        print("")
        let commands = (try? profile.payloads()) ?? []
        print("整份配置共 \(commands.count) 条命令：")
        for (type, payload) in commands {
            let ok = (try? pump { try await transport.send(payload: payload) }) ?? false
            print("  0x\(String(format: "%02X", type.rawValue)) \(payload.count) 字节 → \(ok ? "已写入" : "失败")")
            CFRunLoopRunInMode(.defaultMode, 0.3, true)
        }
        print("")
        print("最后一条是灯光命令，观察鼠标颜色是否变化")
        return
    }

    switch flag("cmd", default: "lighting") {
    case "lighting":
        let color = RGB(
            UInt8(flag("r", default: "255")) ?? 255,
            UInt8(flag("g", default: "0")) ?? 0,
            UInt8(flag("b", default: "255")) ?? 255
        )
        let mode = LightMode(rawValue: UInt8(flag("mode", default: "1")) ?? 1) ?? .staticColor
        print("")
        writePayload(transport, LightingConfiguration(mode: mode, color: color).payload(),
                     expectation: "观察鼠标灯光")

    case "dpi":
        let value = Int(flag("dpi", default: "1600")) ?? 1600
        var configuration = DPIConfiguration()
        configuration.stages[0].value = value
        print("")
        writePayload(transport, configuration.payload(), expectation: "桌面上移动鼠标，距离应变化")

    case "polling":
        let rate = PollingRate(rawValue: Int(flag("hz", default: "1000")) ?? 1000) ?? .hz1000
        print("")
        writePayload(transport, ParameterCommand(pollingRate: rate).payload(),
                     expectation: "轮询率改为 \(rate.rawValue)Hz")

    case "buttons":
        var configuration = ButtonConfiguration()
        configuration[.forward] = ButtonAction(kind: .browserBack)
        print("")
        writePayload(transport, configuration.payload(), expectation: "前进键应变为「浏览器后退」")

    default:
        print("未知命令「\(flag("cmd", default: ""))」，可用: lighting / dpi / polling / buttons")
    }

    CFRunLoopRunInMode(.defaultMode, 1.5, true)
}

// MARK: - 蓝牙

func runBLECommand() {
    let transport = BLETransport()
    transport.start()
    print("正在扫描 FEE3 服务…")
    print("macOS 首次运行会弹蓝牙权限请求，请点「允许」。日志走 NSLog，可用 Console.app 查看。")
    print("按 Ctrl-C 退出。")
    RunLoop.main.run()
}

// MARK: - 入口

switch command {
case "hid": enumerateHID()
case "check": selfCheck()
case "write": runWriteCommand()
case "ble": runBLECommand()
default:
    print("""
    Inphic 探针 — Spike 0

      probe check                                    纯本地协议自检，不需要设备
      probe hid                                      枚举所有英菲克 HID 接口
      probe write --cmd lighting --r 255 --g 0 --b 255
      probe write --cmd dpi --dpi 1600
      probe write --cmd polling --hz 8000
      probe write --cmd buttons
      probe ble                                      扫描并连接蓝牙外设，dump GATT
    """)
}
