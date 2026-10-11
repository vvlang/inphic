import Foundation
import IOKit.hid

/// 直接枚举 IOHIDManager 的只读探针。
///
/// INPHIC 鼠标是**复合设备**，同一个 VID/PID 下会同时出现 4 个 IOHIDDevice：
///
/// | PrimaryUsage | Input | Output | 用途 |
/// |---|---|---|---|
/// | 1 / 128 | 64 | **64** | **厂商配置通道** |
/// | 1 / 6   | 8  | 0 | Boot 键盘 |
/// | 1 / 2   | 7  | 0 | Boot 鼠标 |
/// | 1 / 6   | 14 | 0 | 消费键 |
///
/// 只有 Output Report 长度非零的那个才是配置通道 —— 这是最稳的判别方式，
/// 不依赖厂商的 usage 码约定。
///
/// > ⚠️ 本机（macOS 27 / Darwin 26A434）上 `IOHIDManagerCopyDevices` 无论怎么匹配都返回空，
/// > 必须靠 `IOHIDManagerRegisterDeviceMatchingCallback` 拿设备。
public enum IOHIDManagerProbe {
    public struct Entry {
        public let name: String
        public let vendorID: Int32
        public let productID: Int32
        public let usagePage: Int32
        public let usage: Int32
        public let transport: String
        public let inputReportSize: Int
        public let outputReportSize: Int
        public let featureReportSize: Int

        public var summary: String {
            String(
                format: "%04X:%04X  %@  usage %04X/%-4d  in %4d out %4d feat %4d  %@",
                vendorID, productID, name, usagePage, usage,
                inputReportSize, outputReportSize, featureReportSize, transport
            )
        }

        /// 是不是厂商配置通道。
        public var isConfigurationInterface: Bool { outputReportSize > 0 }
    }

    /// 列出匹配 VID/PID 的全部接口。
    ///
    /// 依赖匹配回调而非 `IOHIDManagerCopyDevices`（见类型注释）。
    public static func enumerate(vendorID: Int32, productID: Int32? = nil, settle: TimeInterval = 0.8) -> [Entry] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        var matching: [String: Any] = [kIOHIDVendorIDKey as String: NSNumber(value: vendorID)]
        if let productID { matching[kIOHIDProductIDKey as String] = NSNumber(value: productID) }
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let collector = Collector()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager, Self.collectCallback, Unmanaged.passUnretained(collector).toOpaque()
        )

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return [] }
        CFRunLoopRunInMode(.defaultMode, settle, true)

        return collector.entries.sorted { ($0.outputReportSize, $0.usage) > ($1.outputReportSize, $1.usage) }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Entry] = []

        var entries: [Entry] { lock.withLock { storage } }

        func append(_ entry: Entry) {
            lock.withLock { storage.append(entry) }
        }
    }

    private static let collectCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context, let entry = makeEntry(device) else { return }
        Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().append(entry)
    }

    /// 把一个 IOHIDDevice 转成快照。
    public static func makeEntry(_ device: IOHIDDevice) -> Entry? {
        let vendor = int(device, kIOHIDVendorIDKey) ?? -1
        let product = int(device, kIOHIDProductIDKey) ?? -1
        guard vendor >= 0, product >= 0 else { return nil }
        return Entry(
            name: string(device, kIOHIDProductKey) ?? "未知设备",
            vendorID: vendor, productID: product,
            usagePage: int(device, kIOHIDPrimaryUsagePageKey) ?? 0,
            usage: int(device, kIOHIDPrimaryUsageKey) ?? 0,
            transport: string(device, kIOHIDTransportKey) ?? "?",
            inputReportSize: Int(int(device, kIOHIDMaxInputReportSizeKey) ?? 0),
            outputReportSize: Int(int(device, kIOHIDMaxOutputReportSizeKey) ?? 0),
            featureReportSize: Int(int(device, kIOHIDMaxFeatureReportSizeKey) ?? 0)
        )
    }

    static func int(_ device: IOHIDDevice, _ key: String) -> Int32? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.int32Value
    }

    static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
