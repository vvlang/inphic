import InphicCore
import SwiftUI

struct ContentView: View {
    @Environment(DeviceController.self) private var controller

    enum Page: String, CaseIterable, Identifiable {
        case dpi = "DPI"
        case lighting = "灯光"
        case performance = "性能"
        case buttons = "按键"
        case macro = "宏"
        case power = "电源"
        case about = "关于"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .dpi: "arrow.up.left.and.arrow.down.right"
            case .lighting: "lightbulb.max"
            case .performance: "speedometer"
            case .buttons: "cursorarrow.rays"
            case .macro: "list.bullet.rectangle.portrait"
            case .power: "battery.100"
            case .about: "info.circle"
            }
        }
    }

    @State private var section: Page = .dpi

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                Divider().overlay(Theme.Palette.hairline)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            .background(Theme.Palette.canvas)
        }
        .background(Theme.Palette.canvas)
        .navigationTitle("Inphic Hub")
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                ForEach(Page.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol)
                        .tag(item)
                        .font(Theme.Typography.body)
                }
            }
            Section("配置档") {
                ProfileSidebar()
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.surface)
        .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(Theme.Palette.hairline)
                StatusDot(state: controller.state)
                if let level = controller.batteryLevel {
                    SpecRow(label: "电量", value: "\(level)%")
                } else if controller.state.device != nil {
                    SpecRow(label: "电量", value: "—", tint: Theme.Palette.textTertiary)
                }
                if let device = controller.state.device {
                    SpecRow(
                        label: "VID:PID",
                        value: String(format: "%04X:%04X", device.vendorID, device.productID)
                    )
                }
                Button {
                    controller.applyCurrentProfile()
                } label: {
                    Label("下发当前配置", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .disabled(controller.state.device == nil)
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .dpi: DPIPage()
        case .lighting: LightingPage()
        case .performance: PerformancePage()
        case .buttons: ButtonsPage()
        case .macro: MacroPage()
        case .power: PowerPage()
        case .about: AboutPage()
        }
    }
}

/// 侧边栏底部的配置档列表。
struct ProfileSidebar: View {
    @Environment(DeviceController.self) private var controller
    @State private var renaming: DeviceProfile?

    var body: some View {
        ForEach(controller.store.profiles) { profile in
            HStack(spacing: 6) {
                Image(systemName: controller.store.selectedProfileID == profile.id
                      ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.accent)
                Text(profile.name)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.store.selectedProfileID = profile.id }
            .contextMenu {
                Button("重命名…") { renaming = profile }
                Button("复制") { controller.store.duplicateSelected() }
                Button("恢复出厂设置", role: .destructive) {
                    controller.store.selectedProfileID = profile.id
                    controller.store.resetSelectedToFactory()
                }
                Divider()
                Button("删除", role: .destructive) {
                    controller.store.selectedProfileID = profile.id
                    _ = controller.store.deleteSelected()
                }
                .disabled(controller.store.profiles.count <= 1)
            }
        }

        Button {
            controller.store.addProfile()
        } label: {
            Label("新建配置档", systemImage: "plus.circle")
                .font(Theme.Typography.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.top, 4)
        .alert("重命名配置档", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名称", text: Binding(
                get: { renaming?.name ?? "" },
                set: { renaming?.name = $0 }
            ))
            Button("取消", role: .cancel) { renaming = nil }
            Button("确定") {
                if let renaming, !renaming.name.isEmpty {
                    controller.store.editSelected { $0.name = renaming.name }
                }
                renaming = nil
            }
        } message: {
            Text("配置档名只保存在本机，不会上传到设备。")
        }
    }
}

/// 页面统一的标题 + 说明条。
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(subtitle)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.bottom, 4)
    }
}

/// 页面底部的下发状态。
struct ApplyFooter: View {
    @Environment(DeviceController.self) private var controller

    var body: some View {
        ApplyStatusBar(state: controller.applyState)
            .padding(.top, 12)
    }
}
