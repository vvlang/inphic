@preconcurrency import CoreBluetooth
import Foundation

/// 蓝牙通道。
///
/// 官方 `WebDriver For Mac` 的 `JLUBluetoothManager` 只用到三个 16 位 UUID：
/// `FEE3`（服务）、`FEE4`（可写特征）、`180A`（Device Information，仅用于扫描过滤）。
/// 发送走 `writeValue(_:for:)` 到 FEE4。
///
/// ## macOS 上的关键坑
/// BLE HID 外设一旦被系统 bond，扫描到的 `CBPeripheral` 与系统持有的**不是同一个实例**，
/// 直接 `connect()` 会在 ATT 层「成功」但写入静默失败。因此启动时先
/// `retrieveConnectedPeripherals(withServices:)`，命中就认领系统已有的那个实例。
///
/// 你的 IN10 在系统里没有可用的 GAP 名称（显示为 `BTM`），所以识别靠服务指纹
/// 而不是名字；识别结果持久化到 `UserDefaults` 后下次直接复用。
public final class BLETransport: NSObject, MouseTransport, @unchecked Sendable {
    /// 厂商 HID 服务 / 特征。
    public static let serviceUUID = CBUUID(string: "FEE3")
    public static let characteristicUUID = CBUUID(string: "FEE4")
    /// Device Information，官方只拿它做扫描过滤。
    public static let deviceInformationUUID = CBUUID(string: "180A")
    private static let persistedIdentifierKey = "Inphic.BLE.peripheralIdentifier"

    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var currentDevice: MouseDevice?
    private var eventStream: AsyncStream<MouseEvent>?
    private var eventContinuation: AsyncStream<MouseEvent>.Continuation?
    private var ackWaiters: [CheckedContinuation<Bool, Never>] = []
    private var pendingWrite: CheckedContinuation<Bool, Never>?
    private var scanTimeout: Task<Void, Never>?
    /// 蓝牙通道固定 64 字节，与官方守护进程一致（其栈上帧长为 0x40）。
    public static let reportLength = 64

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

    public override init() {
        super.init()
    }

    deinit {
        stop()
    }

    public func start() {
        lock.withLock {
            guard central == nil else { return }
            let central = CBCentralManager(delegate: self, queue: .main)
            self.central = central
        }
    }

    public func stop() {
        let central = lock.withLock { () -> CBCentralManager? in
            let central = self.central
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            central?.stopScan()
            scanTimeout?.cancel()
            self.central = nil
            self.peripheral = nil
            self.writeCharacteristic = nil
            self.currentDevice = nil
            self.device = nil
            eventContinuation?.finish()
            return central
        }
        _ = central
    }

    public func send(payload: [UInt8]) async throws -> Bool {
        let (connected, target) = try lock.withLock { () throws -> (CBPeripheral, CBCharacteristic) in
            guard let connected = self.peripheral, let target = self.writeCharacteristic else {
                throw TransportError.notConnected
            }
            return (connected, target)
        }

        let report = Frame.encode(payload: payload, reportLength: Self.reportLength)

        guard target.properties.contains(.write) else {
            // 只能 write-without-response：发出去就算成功，等设备 ACK 来确认。
            connected.writeValue(report, for: target, type: .withoutResponse)
            return true
        }
        return await withCheckedContinuation { continuation in
            lock.withLock { pendingWrite = continuation }
            connected.writeValue(report, for: target, type: .withResponse)
        }
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

}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("[Inphic] 蓝牙状态: \(central.state.rawValue)")
        guard central.state == .poweredOn else { return }

        // 优先认领系统已经连着的 HID 外设 —— 详见类型注释。
        if let alreadyConnected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first
            ?? central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812")]).first {
            NSLog("[Inphic] 发现系统已连接的 BLE 外设: \(alreadyConnected.identifier.uuidString)")
            lock.withLock { self.peripheral = alreadyConnected }
            central.connect(alreadyConnected, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: false])
            return
        }

        // 扫描时把已知外设的广告数据一并记下来，供 didDiscover 匹配。
        central.scanForPeripherals(withServices: [Self.serviceUUID, Self.deviceInformationUUID], options: nil)
        lock.withLock {
            scanTimeout?.cancel()
            scanTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                central.stopScan()
                self?.lock.withLock {
                    if self?.device == nil {
                        NSLog("[Inphic] 15 秒内未发现 INPHIC 鼠标")
                    }
                }
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        NSLog("[Inphic] 扫描到 BLE 外设 \(peripheral.identifier.uuidString) 名称=\(advertised) RSSI=\(RSSI)")

        let remembered = UserDefaults.standard.string(forKey: Self.persistedIdentifierKey)
        let known = advertised.lowercased().contains("mouse")
            || advertised.lowercased().contains("inphic")
            || advertised.lowercased().contains("r1")
            || remembered == peripheral.identifier.uuidString
        // 名字全被抹掉的外设（如本机的 BTM）只能靠服务指纹 + 记住过的标识符认领。
        guard known || advertised.isEmpty else { return }

        central.stopScan()
        lock.withLock {
            scanTimeout?.cancel()
            self.peripheral = peripheral
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.persistedIdentifierKey)
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[Inphic] BLE 已连接，开始发现服务")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        NSLog("[Inphic] BLE 连接失败: \(error?.localizedDescription ?? "未知")")
        lock.withLock { if self.peripheral === peripheral { self.peripheral = nil } }
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        NSLog("[Inphic] BLE 已断开: \(error?.localizedDescription ?? "正常")")
        lock.withLock {
            if self.peripheral === peripheral {
                self.peripheral = nil
                self.writeCharacteristic = nil
                self.currentDevice = nil
                self.device = nil
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            NSLog("[Inphic] 未发现任何服务")
            return
        }
        for service in services {
            NSLog("[Inphic] 服务 \(service.uuid)")
        }
        guard let target = services.first(where: { $0.uuid == Self.serviceUUID }) else {
            NSLog("[Inphic] 未找到服务 \(Self.serviceUUID)")
            return
        }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: target)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            NSLog("[Inphic] 特征 \(characteristic.uuid) 属性: \(characteristic.properties.rawValue)")
        }
        guard let target = characteristics.first(where: { $0.uuid == Self.characteristicUUID }) else {
            NSLog("[Inphic] 未找到特征 \(Self.characteristicUUID)")
            return
        }

        lock.withLock {
            writeCharacteristic = target
            currentDevice = MouseDevice(
                id: "ble-\(peripheral.identifier.uuidString)",
                name: peripheral.name ?? "INPHIC BLE",
                kind: .bluetooth,
                vendorID: HIDTransport.vendorID,
                productID: HIDTransport.productID1K,
                reportLength: Self.reportLength
            )
            device = currentDevice
        }
        peripheral.setNotifyValue(true, for: target)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            NSLog("[Inphic] BLE 通知读取失败: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        let event = EventParser.parse(value)
        lock.withLock {
            eventContinuation?.yield(event)
            if case let .acknowledgement(isSuccess) = event, isSuccess {
                let waiters = ackWaiters
                ackWaiters.removeAll()
                waiters.forEach { $0.resume(returning: isSuccess) }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let success = error == nil
        if let error {
            NSLog("[Inphic] BLE 写入失败: \(error.localizedDescription)")
        }
        lock.withLock {
            let waiter = pendingWrite
            pendingWrite = nil
            waiter?.resume(returning: success)
        }
    }
}
