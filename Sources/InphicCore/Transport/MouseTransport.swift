import Foundation

/// 鼠标的连接方式。与官方 `linkedType` 取值一致。
public enum ConnectionKind: UInt8, Sendable, Codable {
    case wired = 0x80
    case wireless1K = 0x81
    case wireless8K = 0x82
    case bluetooth = 0x84

    public var title: String {
        switch self {
        case .wired: "有线"
        case .wireless1K: "2.4G (1K)"
        case .wireless8K: "2.4G (8K)"
        case .bluetooth: "蓝牙"
        }
    }

    /// 该通道承载的轮询率上限。
    public var maxPollingRate: PollingRate {
        switch self {
        case .wired, .wireless1K, .bluetooth: .hz1000
        case .wireless8K: .hz8000
        }
    }
}

/// 一台在线的鼠标。
public struct MouseDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: ConnectionKind
    public let vendorID: Int32
    public let productID: Int32
    /// HID 报告长度（读或写，取决于固件）。
    public let reportLength: Int
    /// 固件内部型号码，IN10 = 147。仅用于日志与型号识别。
    public let modelID: UInt8?

    public init(
        id: String, name: String, kind: ConnectionKind,
        vendorID: Int32, productID: Int32,
        reportLength: Int, modelID: UInt8? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.vendorID = vendorID
        self.productID = productID
        self.reportLength = reportLength
        self.modelID = modelID
    }
}

/// 传输层的统一抽象。有线 / 2.4G / 蓝牙各自实现一份。
public protocol MouseTransport: AnyObject, Sendable {
    /// 当前已连接的设备，未连接为 nil。
    var device: MouseDevice? { get }
    /// 上行事件流。
    var events: AsyncStream<MouseEvent> { get }

    /// 开始发现设备（已连接则立即推送）。
    func start()
    /// 停止发现并断开。
    func stop()

    /// 下发一条命令载荷。USB 通道是即发即忘；蓝牙走带响应的写入，
    /// 因此签名是 async，返回值表示 ATT 层是否被外设确认。
    func send(payload: [UInt8]) async throws -> Bool
    /// 等待一次设备侧的 ACK 事件。
    func waitForAcknowledgement(timeout: Duration) async -> Bool
}

public enum TransportError: LocalizedError {
    case notConnected
    case deviceBusy(String)
    case writeFailed(status: IOReturn)
    case transportUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "鼠标未连接"
        case let .deviceBusy(name): "无法打开设备「\(name)」，可能被系统或其他程序占用"
        case let .writeFailed(status): "写入失败（IOReturn 0x\(String(UInt32(bitPattern: status), radix: 16))）"
        case let .transportUnavailable(reason): "传输通道不可用：\(reason)"
        }
    }
}
