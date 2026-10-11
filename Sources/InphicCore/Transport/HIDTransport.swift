import Foundation
import IOKit.hid

/// 有线与 2.4G 接收器通道。
///
/// ## 设备识别（实机确认）
///
/// INPHIC 鼠标是复合设备，USB 枚举出 4 个 IOHIDDevice：
///
/// | PrimaryUsage | in | out | 用途 |
/// |---|---|---|---|
/// | 1 / 128 | 64 | **64** | **厂商配置通道** |
/// | 1 / 6   | 8  | 0 | Boot 键盘 |
/// | 1 / 2   | 7  | 0 | Boot 鼠标 |
/// | 1 / 6   | 14 | 0 | 消费键 |
///
/// 所以筛选条件是 **VID/PID 匹配 + `MaxOutputReportSize > 0`**，
/// 后者直接挑出唯一可配置的接口，不必依赖厂商的 usage 码约定。
///
/// > ⚠️ `IOHIDManagerCopyDevices` 在本机（macOS 27 / Darwin 26A434）上恒返回空，
/// > 必须用匹配回调收集设备。
///
/// ## reportType（🔬 官方 `WebDriver For Mac` 反汇编）
///
/// | PID | 官方类 | reportType |
/// |---|---|---|
/// | `0xFA60` | `JLUMacHid` | 2 = Feature |
/// | `0xFA60` | `JLUMacHidD8K` | 2 = Feature |
/// | `0xFA65` | `JLUMacHid8K` | 1 = Output |
/// | （仅 VID） | `JLUMacHidWire` | 2 = Feature |
///
/// 本机 IN10（`1d57:fa65`）Feature 报告只有 1 字节、Output 有 64 字节，
/// 与官方把 8K 走 Output 的结论一致。
public final class HIDTransport: MouseTransport, @unchecked Sendable {
    /// 英菲克（杰理 Jieli）VID。
    public static let vendorID: Int32 = 0x1D57
    /// 1K 鼠标 / 2.4G 接收器。
    public static let productID1K: Int32 = 0xFA60
    /// 8K 鼠标（IN10，实机确认）。
    public static let productID8K: Int32 = 0xFA65
    /// 厂商配置接口的 PrimaryUsage。
    public static let vendorUsage: Int32 = 128

    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var openDevice: IOHIDDevice?
    private var currentDevice: MouseDevice?
    private var eventContinuation: AsyncStream<MouseEvent>.Continuation?
    private var eventStream: AsyncStream<MouseEvent>?
    private var ackWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Input Report 回调没有长度参数，必须自带缓冲区。
    private static let inputReportBufferSize = 2048
    /// 设备级回调要求缓冲区在设备存活期间一直有效，所以必须持有它。
    private var reportBuffer: [UInt8] = [UInt8](repeating: 0, count: inputReportBufferSize)

    public private(set) var device: MouseDevice?

    public var events: AsyncStream<MouseEvent> {
        lock.withLock {
            if let eventStream { return eventStream }
            let (stream, continuation) = AsyncStream<MouseEvent>.makeStream(bufferingPolicy: .unbounded)
            eventStream = stream
            eventContinuation = continuation
            return stream
        }
    }

    public init() {}

    deinit { stop() }

    // MARK: - 生命周期

    public func start() {
        let alreadyRunning: Bool = lock.withLock {
            guard manager == nil else { return true }
            return false
        }
        guard !alreadyRunning else { return }

        // HID 管理器必须挂在**自己专属的线程 + run loop** 上。
        // 挂在主 run loop 上时，SwiftUI / AppKit 的运行模式会让 HID 源收不到
        // 回调 —— 实测同一份代码在 CLI 里（手动泵 run loop）能收到电量包，
        // 在 App 里一个包都收不到。独立线程是最稳的做法。
        hidThread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = RunLoop.current
            // 加一个源，保证 run loop 不会立刻返回空转退出。
            let keepAlive = Port()
            runLoop.add(keepAlive, forMode: .default)
            self.hidRunLoop = CFRunLoopGetCurrent()

            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [String: Any] = [
                kIOHIDVendorIDKey as String: NSNumber(value: Self.vendorID),
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
            IOHIDManagerRegisterDeviceMatchingCallback(
                manager, Self.matchCallback, Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDManagerRegisterDeviceRemovalCallback(
                manager, Self.removeCallback, Unmanaged.passUnretained(self).toOpaque()
            )
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

            let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            if !opened { NSLog("[Inphic] IOHIDManagerOpen 失败") }
            self.lock.withLock { self.manager = opened ? manager : nil }

            // 阻塞这个线程的 run loop，直到 stop() 叫醒它。
            while !self.lock.withLock({ self.shouldStop }) {
                _ = runLoop.run(mode: .default, before: Date().addingTimeInterval(0.5))
            }
        }
        hidThread?.name = "cn.inphic.hub.hid"
        hidThread?.qualityOfService = .userInitiated
        hidThread?.start()
    }

    public func stop() {
        let (openedManager, openedDevice) = lock.withLock { () -> (IOHIDManager?, IOHIDDevice?) in
            let result = (manager, openDevice)
            shouldStop = true
            return result
        }
        if let openedDevice { IOHIDDeviceClose(openedDevice, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let openedManager { IOHIDManagerClose(openedManager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let hidRunLoop { CFRunLoopWakeUp(hidRunLoop) }
        lock.withLock {
            manager = nil
            openDevice = nil
            currentDevice = nil
            device = nil
            eventContinuation?.finish()
        }
    }

    // MARK: - 发送

    /// 强制使用指定报告类型，忽略按 PID 的默认值。仅用于诊断。
    public func send(payload: [UInt8], forcingReportType reportType: IOHIDReportType) async throws -> Bool {
        let context = try lock.withLock { () throws -> SendContext in
            guard let openDevice, let currentDevice else { throw TransportError.notConnected }
            return SendContext(
                device: openDevice,
                productID: currentDevice.productID,
                reportLength: reportLength(for: openDevice),
                forcedReportType: reportType
            )
        }
        let report = Frame.encode(payload: payload, reportLength: context.reportLength)
        var buffer = [UInt8](report)
        let result = IOHIDDeviceSetReport(context.device, reportType, CFIndex(Frame.reportID), &buffer, buffer.count)
        guard result == kIOReturnSuccess else { throw TransportError.writeFailed(status: result) }
        return true
    }

    public func send(payload: [UInt8]) async throws -> Bool {
        let context = try lock.withLock { () throws -> SendContext in
            guard let openDevice, let currentDevice else { throw TransportError.notConnected }
            return SendContext(
                device: openDevice,
                productID: currentDevice.productID,
                reportLength: reportLength(for: openDevice),
                forcedReportType: nil
            )
        }

        let report = Frame.encode(payload: payload, reportLength: context.reportLength)
        var buffer = [UInt8](report)
        let result = IOHIDDeviceSetReport(
            context.device, context.forcedReportType ?? Self.reportType(for: context.productID),
            CFIndex(Frame.reportID), &buffer, buffer.count
        )
        guard result == kIOReturnSuccess else {
            throw TransportError.writeFailed(status: result)
        }
        return true
    }

    public func waitForAcknowledgement(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { continuation in
                    guard let self else { return continuation.resume(returning: false) }
                    self.lock.withLock { self.ackWaiters.append(continuation) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private struct SendContext {
        let device: IOHIDDevice
        let productID: Int32
        let reportLength: Int
        let forcedReportType: IOHIDReportType?
    }

    /// 该设备声明的输出报告长度。本机 IN10 为 64。
    func reportLength(for device: IOHIDDevice) -> Int {
        if let size = IOHIDManagerProbe.int(device, kIOHIDMaxOutputReportSizeKey), size > 1 { return Int(size) }
        if let size = IOHIDManagerProbe.int(device, kIOHIDMaxFeatureReportSizeKey), size > 1 { return Int(size) }
        return Frame.fallbackReportLength
    }

    static func reportType(for productID: Int32) -> IOHIDReportType {
        productID == productID8K ? kIOHIDReportTypeOutput : kIOHIDReportTypeFeature
    }

    // MARK: - 连接管理

    /// 只认 Output Report 非零的那个接口 —— 它就是厂商配置通道。
    private func attach(to hidDevice: IOHIDDevice) {
        guard let entry = IOHIDManagerProbe.makeEntry(hidDevice), entry.isConfigurationInterface else { return }

        if let previous = openDevice {
            IOHIDDeviceClose(previous, IOOptionBits(kIOHIDOptionsTypeNone))
            openDevice = nil
        }

        guard IOHIDDeviceOpen(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            NSLog("[Inphic] 打开 %@ 配置接口失败（可能被系统占用）", entry.name)
            return
        }

        // 设备级上行回调：只有这样才收得到 Report ID 3 的电量包。
        let context = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.withUnsafeMutableBytes { raw in
            IOHIDDeviceRegisterInputReportCallback(
                hidDevice,
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                Self.inputReportBufferSize,
                Self.inputReportCallback,
                context
            )
        }

        let kind: ConnectionKind = entry.productID == Self.productID8K ? .wireless8K : .wireless1K
        let mouse = MouseDevice(
            id: "hid-\(entry.vendorID)-\(entry.productID)-\(entry.usage)-\(entry.transport)",
            name: entry.name,
            kind: kind,
            vendorID: entry.vendorID,
            productID: entry.productID,
            reportLength: reportLength(for: hidDevice)
        )

        openDevice = hidDevice
        currentDevice = mouse
        device = mouse
        NSLog("[Inphic] 已连接 %@ usage %d 报告长度 %d", entry.name, entry.usage, mouse.reportLength)
        NSLog("[Inphic] 已连接 %@ [%@] usage %d 报告长度 %d", entry.name, kind.title, entry.usage, mouse.reportLength)
    }

    private func detach() {
        if let hidDevice = openDevice {
            IOHIDDeviceClose(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        openDevice = nil
        currentDevice = nil
        device = nil
    }

    // MARK: - C 回调

    fileprivate func handleMatch(_ device: IOHIDDevice) {
        lock.withLock { attach(to: device) }
    }

    fileprivate func handleRemoval(_ device: IOHIDDevice) {
        lock.withLock {
            guard openDevice == device else { return }
            detach()
        }
    }

    private static let matchCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().handleMatch(device)
    }

    private static let removeCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue().handleRemoval(device)
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
        guard let context, reportLength > 0 else { return }
        Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            .handleInputReport(Data(bytes: report, count: reportLength))
    }

    /// 输入报告按 Report ID 分流。
    fileprivate func handleInputReport(_ bytes: Data) {
        // 鼠标移动是高频包，本工具不关心，直接丢掉，只留厂商事件。
        guard bytes.first != Self.motionReportID else { return }
        let event = EventParser.parse(bytes)
        lock.withLock {
            eventContinuation?.yield(event)
            if case let .acknowledgement(isSuccess) = event, isSuccess {
                let waiters = ackWaiters
                ackWaiters.removeAll()
                waiters.forEach { $0.resume(returning: isSuccess) }
            }
        }
    }

    private var hidThread: Thread?
    private var hidRunLoop: CFRunLoop?
    private var shouldStop = false

    /// 标准鼠标移动的 Report ID。设备级回调会把所有报告都送上来，
    /// 其中绝大多数是这类高频移动包，本工具不关心，直接丢掉。
    private static let motionReportID: UInt8 = 0
}

extension NSLock {
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
