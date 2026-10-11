import Foundation
import Observation

/// UI 与传输层之间的胶水。
///
/// 负责：发现设备、汇总电量/DPI 事件、把配置档下发到设备。
/// 下发是**串行**的 —— 固件对并发写入的处理未知，串行最安全。
@MainActor
@Observable
public final class DeviceController {
    public enum ConnectionState: Equatable {
        case idle
        case searching
        case connected(MouseDevice)
        case unavailable(String)

        public var device: MouseDevice? {
            if case let .connected(device) = self { return device }
            return nil
        }
    }

    public enum ApplyState: Equatable {
        case idle
        case applying(String)
        case succeeded(Date)
        case failed(String)
    }

    // MARK: - 状态

    public private(set) var state: ConnectionState = .idle
    public private(set) var applyState: ApplyState = .idle
    public private(set) var batteryLevel: Int?
    public private(set) var batteryStatus: MouseEvent.BatteryStatus?
    /// 用户按下 DPI 循环键时鼠标报告的档位。
    public private(set) var hardwareDPIStage: Int?
    /// 是否监听蓝牙（电量在 USB 上不上报）。
    public var listensToBluetooth: Bool = false

    public let store: ProfileStore

    // MARK: - 传输

    private let hid: HIDTransport
    private let ble: BLETransport
    private var eventTasks: [Task<Void, Never>] = []
    private var applyTail: Task<Void, Never>?

    public init(store: ProfileStore, hid: HIDTransport = HIDTransport(), ble: BLETransport = BLETransport()) {
        self.store = store
        self.hid = hid
        self.ble = ble
    }

    // MARK: - 生命周期

    public func start() {
        observe(hid)
        hid.start()
        if listensToBluetooth {
            observe(ble)
            ble.start()
        }
        state = .searching
        startPolling()
    }

    /// 传输层没有「设备插拔」回调流，用低频轮询刷新连接状态。
    private func startPolling() {
        eventTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.refreshConnectionState()
            }
        })
    }

    public func restartBluetooth() {
        observe(ble)
        ble.start()
    }

    private func observe(_ transport: any MouseTransport) {
        eventTasks.append(Task { [weak self] in
            for await event in transport.events {
                await self?.handle(event)
            }
        })
    }

    private func handle(_ event: MouseEvent) {
        // 任何上报都说明鼠标是醒着的 —— 这是判断「能不能写进去」最可靠的信号。
        lastEventAt = Date()
        switch event {
        case let .battery(status, level):
            batteryStatus = status
            batteryLevel = level
        case let .dpiStageChanged(stage):
            hardwareDPIStage = stage
        case .acknowledgement:
            break
        case .vibration, .profileChanged, .vendor, .unparsed:
            break
        }
    }

    /// 鼠标最近一次上报的时间。
    ///
    /// 固件**睡着时会静默丢弃配置写入**（出厂深睡 5 分钟）。而它醒着的时候
    /// 每 2 秒会发一次电量包。所以：写过之后如果 3 秒内没有新上报，说明
    /// 那一帧很可能被丢了，需要重发。
    private var lastEventAt: Date?

    /// 鼠标是否处于活跃状态（最近有上报）。
    private var isAwake: Bool {
        guard let lastEventAt else { return false }
        return Date().timeIntervalSince(lastEventAt) < Self.awakeWindow
    }

    /// 超过这个间隔没上报，就认为鼠标睡着了。
    private static let awakeWindow: TimeInterval = 3

    /// 下发一条命令，必要时重试到鼠标确实醒着。
    ///
    /// 固件没有 ACK 可言（实测从没收到过 `06 C0 …` 确认帧），所以「写成功」
    /// 的判据只能是：**写完之后鼠标仍在持续上报**。
    private func send(_ payload: [UInt8], via transport: any MouseTransport) async throws {
        try await transport.send(payload: payload)

        // 鼠标本来就醒着 → 一帧足矣。
        if isAwake { return }

        for _ in 0..<Self.wakeRetries {
            try? await Task.sleep(for: .milliseconds(500))
            try await transport.send(payload: payload)
            if isAwake { return }
        }
    }

    /// 鼠标睡着时最多重发多少帧。
    private static let wakeRetries = 15

    private func refreshConnectionState() {
        let device = hid.device ?? ble.device
        let newState: ConnectionState = device.map(ConnectionState.connected)
            ?? (listensToBluetooth ? .searching : .unavailable("未检测到鼠标。请插上 2.4G 接收器或改用有线连接。"))
        if newState != state { state = newState }
    }

    // MARK: - 下发

    /// 把当前配置档整份下发。
    public func applyCurrentProfile() {
        let profile = store.profiles[store.selectedIndex]
        let transport = activeTransport()
        guard let transport else {
            applyState = .failed("鼠标未连接")
            return
        }

        // 串行化：无论调用多少次，都按调用顺序排队执行。
        let previous = applyTail
        applyTail = Task { [weak self] in
            _ = await previous?.result
            await self?.apply(profile: profile, via: transport)
        }
    }

    private func apply(profile: DeviceProfile, via transport: any MouseTransport) async {
        do {
            let commands = try profile.payloads()
            for (type, payload) in commands {
                applyState = .applying(describe(type))
                try await send(payload, via: transport)
                // 固件对连续写入有速率要求，稍作间隔更稳。
                try? await Task.sleep(for: .milliseconds(20))
            }
            applyState = .succeeded(Date())
        } catch {
            applyState = .failed(error.localizedDescription)
        }
    }

    /// 只下发灯光（UI 上调色时用，避免整份重写）。
    public func applyLighting(_ lighting: LightingConfiguration) {
        guard let transport = activeTransport() else {
            applyState = .failed("鼠标未连接")
            return
        }
        let payload = lighting.payload()
        let previous = applyTail
        applyTail = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            do {
                self.applyState = .applying("灯光")
                try await self.send(payload, via: transport)
                self.applyState = .succeeded(Date())
            } catch {
                self.applyState = .failed(error.localizedDescription)
            }
        }
    }

    /// 只下发 DPI。
    public func applyDPI(_ dpi: DPIConfiguration) {
        guard let transport = activeTransport() else {
            applyState = .failed("鼠标未连接")
            return
        }
        let payload = dpi.payload()
        let previous = applyTail
        applyTail = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            do {
                self.applyState = .applying("DPI")
                try await self.send(payload, via: transport)
                self.applyState = .succeeded(Date())
            } catch {
                self.applyState = .failed(error.localizedDescription)
            }
        }
    }

    /// 只下发轮询率，并按连接方式的能力上限夹紧。
    public func applyPolling(_ rate: PollingRate) {
        guard let transport = activeTransport() else {
            applyState = .failed("鼠标未连接")
            return
        }
        let clamped = DeviceCapabilities(kind: transport.device?.kind ?? .wired).clamp(rate)
        let payload = ParameterCommand(pollingRate: clamped).payload()
        let previous = applyTail
        applyTail = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            do {
                self.applyState = .applying("轮询率")
                try await self.send(payload, via: transport)
                self.applyState = .succeeded(Date())
            } catch {
                self.applyState = .failed(error.localizedDescription)
            }
        }
    }

    /// 只下发按键映射。
    public func applyButtons(_ buttons: ButtonConfiguration) {
        guard let transport = activeTransport() else {
            applyState = .failed("鼠标未连接")
            return
        }
        let payload = buttons.payload()
        let previous = applyTail
        applyTail = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            do {
                self.applyState = .applying("按键")
                try await self.send(payload, via: transport)
                self.applyState = .succeeded(Date())
            } catch {
                self.applyState = .failed(error.localizedDescription)
            }
        }
    }

    private func activeTransport() -> (any MouseTransport)? {
        if hid.device != nil { return hid }
        if ble.device != nil { return ble }
        return nil
    }

    private func describe(_ type: CommandType) -> String {
        switch type {
        case .dpi: "DPI"
        case .lighting: "灯光"
        case .parameter: "轮询率"
        case .wirelessSetting: "无线"
        case .buttons: "按键"
        case .macro: "宏"
        case .profileID: "配置档"
        }
    }
}
