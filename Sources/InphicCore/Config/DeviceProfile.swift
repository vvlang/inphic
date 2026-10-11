import Foundation

/// 一个完整的配置档。
///
/// 固件侧没有「读回」接口（官方 macOS 驱动是纯只写的），
/// 所以配置以本地为准；下发时整份重写，避免出现「改了一项把别的项清零」。
public struct DeviceProfile: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// 固件里的配置档号。IN10 官方前端把它硬编码为 1。
    public var firmwareProfileID: UInt8

    public var dpi: DPIConfiguration
    public var lighting: LightingConfiguration
    public var polling: ParameterCommand
    public var buttons: ButtonConfiguration
    public var macros: [Macro]

    public init(
        id: UUID = UUID(),
        name: String = "配置 1",
        firmwareProfileID: UInt8 = 1,
        dpi: DPIConfiguration = DPIConfiguration(),
        lighting: LightingConfiguration = LightingConfiguration(),
        polling: ParameterCommand = ParameterCommand(),
        buttons: ButtonConfiguration = ButtonConfiguration(),
        macros: [Macro] = []
    ) {
        self.id = id
        self.name = name
        self.firmwareProfileID = firmwareProfileID
        self.dpi = dpi
        self.lighting = lighting
        self.polling = polling
        self.buttons = buttons
        self.macros = macros
    }

    /// 恢复出厂。
    public static let factory = DeviceProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    /// 把整份配置摊平成一串命令载荷，按依赖顺序排列。
    ///
    /// 顺序有讲究：先 DPI（决定当前档位与指示灯语义），再灯光/电源，
    /// 再轮询率，最后按键与宏。
    public func payloads() throws -> [(CommandType, [UInt8])] {
        var commands: [(CommandType, [UInt8])] = []
        commands.append((.dpi, dpi.payload()))
        commands.append((.lighting, lighting.payload()))
        commands.append((.parameter, polling.payload()))
        commands.append((.buttons, buttons.payload()))
        for macro in macros {
            commands.append((.macro, try MacroCommand(macro: macro).payload()))
        }
        return commands
    }
}

/// 连接方式对应的能力上限。
public struct DeviceCapabilities: Equatable, Sendable {
    public var maxPollingRate: PollingRate
    public var supportsMacro: Bool
    public var supportsMotionSync: Bool
    public var supportsProfileSwitch: Bool

    public init(kind: ConnectionKind) {
        maxPollingRate = kind.maxPollingRate
        supportsMacro = true
        supportsMotionSync = kind != .wired
        supportsProfileSwitch = kind == .bluetooth
    }

    /// 超过上限的轮询率会被降到上限。
    public func clamp(_ rate: PollingRate) -> PollingRate {
        rate.rawValue <= maxPollingRate.rawValue ? rate : maxPollingRate
    }
}
