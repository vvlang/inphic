import AppKit
import InphicCore
import Observation
import SwiftUI

/// 菜单栏常驻：电量、DPI 档位、快速切换。
@MainActor
@Observable
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private weak var controller: DeviceController?
    private var observation: Task<Void, Never>?

    func attach(to controller: DeviceController) {
        self.controller = controller
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "computermouse", accessibilityDescription: "Inphic Hub"
        )
        item.button?.image?.isTemplate = true
        item.menu = makeMenu()
        statusItem = item

        observation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshIcon()
            }
        }
    }

    private func refreshIcon() {
        guard let controller, let statusItem else { return }
        let symbol: String
        switch (controller.state, controller.batteryLevel) {
        case (.connected, let level?):
            symbol = level <= 15 ? "computermouse.fill.badge.exclamationmark" : "computermouse.fill"
        case (.connected, nil):
            symbol = "computermouse"
        case (.searching, _):
            symbol = "computermouse"
        default:
            symbol = "computermouse"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        guard let controller else { return NSMenu() }
        let menu = NSMenu()

        let header = NSMenuItem(title: headerTitle(controller), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let level = controller.batteryLevel {
            let item = NSMenuItem(title: "电量 \(level)%", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let profileHeader = NSMenuItem(title: "切换配置档", action: nil, keyEquivalent: "")
        profileHeader.isEnabled = false
        menu.addItem(profileHeader)

        for profile in controller.store.profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == controller.store.selectedProfileID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let dpiHeader = NSMenuItem(title: "DPI 档位", action: nil, keyEquivalent: "")
        dpiHeader.isEnabled = false
        menu.addItem(dpiHeader)

        let index = controller.store.selectedIndex
        for stage in controller.store.profiles[index].dpi.stages where stage.isEnabled {
            let item = NSMenuItem(title: "\(stage.value)", action: #selector(pickStage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = stage.value
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let apply = NSMenuItem(title: "下发当前配置", action: #selector(applyProfile), keyEquivalent: "")
        apply.target = self
        menu.addItem(apply)

        let show = NSMenuItem(title: "打开主窗口", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Inphic Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func headerTitle(_ controller: DeviceController) -> String {
        switch controller.state {
        case let .connected(device): "\(device.name) · \(device.kind.title)"
        case .searching: "正在查找鼠标…"
        case .unavailable: "未连接鼠标"
        case .idle: "Inphic Hub"
        }
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller?.store.selectedProfileID = id
        controller?.applyCurrentProfile()
    }

    @objc private func pickStage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int, let controller else { return }
        controller.store.editSelected { profile in
            guard let stage = profile.dpi.stages.firstIndex(where: { $0.value == value }) else { return }
            profile.dpi.activeStage = stage + 1
        }
        controller.applyDPI(controller.store.profiles[controller.store.selectedIndex].dpi)
    }

    @objc private func applyProfile() {
        controller?.applyCurrentProfile()
    }

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
