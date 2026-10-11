import Foundation
import InphicCore
import SwiftUI

struct AboutPage: View {
    @Environment(DeviceController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "关于",
                    subtitle: AppInfo.disclaimer
                )

                Card(title: "应用") {
                    SpecRow(label: "版本", value: AppInfo.displayVersion)
                    SpecRow(label: "作者", value: AppInfo.author)
                    SpecRow(label: "许可", value: "MIT License")
                    HStack {
                        Link("github.com/vvlang/inphic", destination: URL(string: AppInfo.repository)!)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.accent)
                        Spacer()
                    }
                    Text(AppInfo.copyright)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                Card(title: "设备") {
                    if let device = controller.state.device {
                        SpecRow(label: "名称", value: device.name)
                        SpecRow(label: "连接方式", value: device.kind.title)
                        SpecRow(
                            label: "VID:PID",
                            value: String(format: "%04X:%04X", device.vendorID, device.productID)
                        )
                        SpecRow(label: "报告长度", value: "\(device.reportLength) 字节")
                        SpecRow(
                            label: "轮询率上限",
                            value: "\(DeviceCapabilities(kind: device.kind).maxPollingRate.rawValue) Hz"
                        )
                    } else {
                        Text("未连接")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }

                Card(title: "协议") {
                    SpecRow(label: "报告 ID", value: "0x\(String(format: "%02X", Frame.reportID))")
                    SpecRow(
                        label: "命令类型",
                        value: CommandType.allCases
                            .map { String(format: "0x%02X", $0.rawValue) }
                            .joined(separator: " ")
                    )
                    SpecRow(label: "校验", value: "大端 16 位累加和")
                    Text("帧格式  04 | len+5 | 00 | payload | csum16 | 补零")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.top, 2)
                }

                Card(title: "已知限制") {
                    limitation("固件不支持读回设置", detail: "能读电量，但读不回 DPI / 灯光 / 按键。官方 macOS 驱动也是纯只写的，所以本工具以下发为准。")
                    limitation("鼠标睡着时写不进去", detail: "固件进入深睡后会静默丢弃配置写入（接口仍返回成功）。本工具会自动重发，动一下鼠标即可唤醒。")
                    limitation("蓝牙通道未验证", detail: "macOS 不转发 HID SET_REPORT，蓝牙需要 CoreBluetooth 直连，FEE3/FEE4 是否可用待实机确认。")
                    limitation("配置档只存本机", detail: "每条配置档是一组完整设置，切换即整份重写。")
                }

                Card(title: "配置档") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("共 \(controller.store.profiles.count) 条")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text("存放在 ~/Library/Application Support/InphicHub/profiles.json")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Spacer()
                        exportButton
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var exportButton: some View {
        Button {
            guard let data = try? controller.store.exportData() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "inphic-profiles.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        } label: {
            Label("导出配置", systemImage: "square.and.arrow.up")
        }
    }

    private func limitation(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsView: View {
    @Environment(DeviceController.self) private var controller
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("连接") {
                Toggle("同时监听蓝牙", isOn: Binding(
                    get: { controller.listensToBluetooth },
                    set: { value in
                        controller.listensToBluetooth = value
                        if value { controller.restartBluetooth() }
                    }
                ))
                StatusDot(state: controller.state)
            }
            Section("开机启动") {
                Toggle("登录时自动运行", isOn: $launchAtLogin)
                    .disabled(true)
                    .help("需要先打包成 .app 并签名到「登录项」，当前为开发版本")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 240)
    }
}
