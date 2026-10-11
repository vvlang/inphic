import InphicCore
import SwiftUI

struct ButtonsPage: View {
    @Environment(DeviceController.self) private var controller
    @State private var editing: ButtonSlot?

    private var store: ProfileStore { controller.store }
    private var index: Int { store.selectedIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "按键",
                subtitle: "5 个物理按键可改绑定。固件里一共 18 个槽位，其余保持出厂值。"
            )

            Card(title: "可自定义按键") {
                VStack(spacing: 0) {
                    ForEach(Array(ButtonSlot.userEditable.enumerated()), id: \.element) { _, slot in
                        buttonRow(slot)
                        if slot != ButtonSlot.userEditable.last {
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }
            }

            Card(title: "固件槽位", trailing: "共 \(ButtonSlot.allCases.count) 个") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                    spacing: 6
                ) {
                    ForEach(ButtonSlot.allCases, id: \.rawValue) { slot in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(slot.isUserEditable ? Theme.Palette.accent : Theme.Palette.textTertiary)
                                .frame(width: 5, height: 5)
                            Text(slot.title)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(slot.isUserEditable
                                                 ? Theme.Palette.textSecondary
                                                 : Theme.Palette.textTertiary)
                            Spacer()
                            Text(describe(store.profiles[index].buttons[slot]))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            ApplyFooter()
        }
        .frame(maxWidth: 720, alignment: .leading)
        .sheet(item: $editing) { slot in
            ActionPicker(
                slot: slot,
                current: store.profiles[index].buttons[slot],
                macros: store.profiles[index].macros
            ) { action in
                controller.store.editSelected { $0.buttons[slot] = action }
            }
        }
    }

    private func buttonRow(_ slot: ButtonSlot) -> some View {
        Button {
            editing = slot
        } label: {
            HStack {
                Text(slot.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(describe(store.profiles[index].buttons[slot]))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: Theme.Metrics.rowHeight)
    }

    private func describe(_ action: ButtonAction) -> String {
        switch action.kind {
        case .off: return "关闭"
        case .leftClick: return "左键"
        case .rightClick: return "右键"
        case .middleClick: return "中键"
        case .backward: return "后退"
        case .forward: return "前进"
        case .doubleClick: return "双击"
        case .fire: return "连发"
        case .scrollDown: return "滚轮下"
        case .scrollUp: return "滚轮上"
        case .tiltLeft: return "倾斜左"
        case .tiltRight: return "倾斜右"
        case .dpiCycle: return "DPI 循环"
        case .dpiUp: return "DPI +"
        case .dpiDown: return "DPI −"
        case .easyAim: return "精准模式"
        case .shortcut:
            let key = HidKey(rawValue: action.argument)?.title ?? "键 \(action.argument)"
            return modifierLabel(action.modifier) + key
        case .macro: return "宏 \(action.argument)"
        case .mediaPlay: return "播放"
        case .mediaPrevious: return "上一首"
        case .mediaNext: return "下一首"
        case .mediaPlayPause: return "播放/暂停"
        case .mediaStop: return "停止"
        case .mute: return "静音"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        case .calculator: return "计算器"
        case .email: return "邮件"
        case .browserForward: return "浏览器前进"
        case .browserBack: return "浏览器后退"
        case .browserRefresh: return "刷新"
        case .browserHome: return "主页"
        case .browserSearch: return "搜索"
        case .profileCycle: return "配置档循环"
        case .profileUp: return "配置档 +"
        case .profileDown: return "配置档 −"
        case .modeKey: return "模式键"
        }
    }

    private func modifierLabel(_ mask: UInt8) -> String {
        var parts: [String] = []
        if mask & 0x01 != 0 { parts.append("⌃") }
        if mask & 0x02 != 0 { parts.append("⇧") }
        if mask & 0x04 != 0 { parts.append("⌥") }
        if mask & 0x08 != 0 { parts.append("⌘") }
        return parts.joined()
    }
}

/// 按键动作选择器。
struct ActionPicker: View {
    let slot: ButtonSlot
    let current: ButtonAction
    let macros: [Macro]
    let onPick: (ButtonAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var modifiers: HIDModifiers = []
    @State private var selectedKey: HidKey = .a

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("「\(slot.title)」绑定到")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Picker("动作", selection: Binding(
                get: { current.kind },
                set: { kind in apply(kind) }
            )) {
                Text("关闭").tag(ButtonAction.Kind.off)
                Section("鼠标") {
                    Text("左键").tag(ButtonAction.Kind.leftClick)
                    Text("右键").tag(ButtonAction.Kind.rightClick)
                    Text("中键").tag(ButtonAction.Kind.middleClick)
                    Text("后退").tag(ButtonAction.Kind.backward)
                    Text("前进").tag(ButtonAction.Kind.forward)
                    Text("双击").tag(ButtonAction.Kind.doubleClick)
                    Text("连发").tag(ButtonAction.Kind.fire)
                }
                Section("滚轮") {
                    Text("滚轮下").tag(ButtonAction.Kind.scrollDown)
                    Text("滚轮上").tag(ButtonAction.Kind.scrollUp)
                    Text("倾斜左").tag(ButtonAction.Kind.tiltLeft)
                    Text("倾斜右").tag(ButtonAction.Kind.tiltRight)
                }
                Section("DPI") {
                    Text("DPI 循环").tag(ButtonAction.Kind.dpiCycle)
                    Text("DPI +").tag(ButtonAction.Kind.dpiUp)
                    Text("DPI −").tag(ButtonAction.Kind.dpiDown)
                }
                Section("系统") {
                    Text("组合键…").tag(ButtonAction.Kind.shortcut)
                    Text("配置档循环").tag(ButtonAction.Kind.profileCycle)
                    Text("模式键").tag(ButtonAction.Kind.modeKey)
                }
                Section("多媒体") {
                    Text("播放/暂停").tag(ButtonAction.Kind.mediaPlayPause)
                    Text("上一首").tag(ButtonAction.Kind.mediaPrevious)
                    Text("下一首").tag(ButtonAction.Kind.mediaNext)
                    Text("静音").tag(ButtonAction.Kind.mute)
                    Text("音量 +").tag(ButtonAction.Kind.volumeUp)
                    Text("音量 −").tag(ButtonAction.Kind.volumeDown)
                }
                Section("浏览器") {
                    Text("后退").tag(ButtonAction.Kind.browserBack)
                    Text("前进").tag(ButtonAction.Kind.browserForward)
                    Text("刷新").tag(ButtonAction.Kind.browserRefresh)
                    Text("主页").tag(ButtonAction.Kind.browserHome)
                    Text("搜索").tag(ButtonAction.Kind.browserSearch)
                }
                if !macros.isEmpty {
                    Section("宏") {
                        ForEach(macros) { macro in
                            Text(macro.name).tag(ButtonAction.Kind.macro)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(height: 220)

            if current.kind == .shortcut {
                shortcutEditor
            }
            if current.kind == .macro, let macro = macros.first(where: { $0.id == Int(current.argument) }) {
                Text("当前宏：\(macro.name) · \(macro.actions.count) 个动作")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            Button("恢复该键的出厂绑定") {
                onPick(slot.factoryAction)
                dismiss()
            }
            .font(Theme.Typography.body)
        }
        .padding(20)
        .frame(width: 400)
        .background(Theme.Palette.canvas)
        .onAppear {
            modifiers = HIDModifiers(rawValue: current.modifier)
            if let key = HidKey(rawValue: current.argument) { selectedKey = key }
        }
    }

    private var shortcutEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "修饰键")
            HStack(spacing: 6) {
                modifierToggle("⌃", .control)
                modifierToggle("⇧", .shift)
                modifierToggle("⌥", .alternate)
                modifierToggle("⌘", .gui)
            }
            SectionLabel(text: "主键")
            Picker("", selection: $selectedKey) {
                ForEach(HidKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .labelsHidden()
            .onChange(of: selectedKey) { _, key in
                onPick(ButtonAction(kind: .shortcut, modifier: modifiers.rawValue, argument: key.rawValue))
            }
        }
        .onChange(of: modifiers) { _, value in
            onPick(ButtonAction(kind: .shortcut, modifier: value.rawValue, argument: selectedKey.rawValue))
        }
    }

    private func modifierToggle(_ label: String, _ option: HIDModifiers) -> some View {
        let on = modifiers.contains(option)
        return Button {
            if on { modifiers.remove(option) } else { modifiers.insert(option) }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.textSecondary)
                .frame(width: 34, height: 28)
                .background(
                    on ? Theme.Palette.accentMuted : Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(on ? Theme.Palette.accent : Theme.Palette.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func apply(_ kind: ButtonAction.Kind) {
        switch kind {
        case .shortcut:
            onPick(ButtonAction(kind: .shortcut, modifier: modifiers.rawValue, argument: selectedKey.rawValue))
        case .macro:
            onPick(ButtonAction(kind: .macro, argument: UInt8(max(1, macros.first?.id ?? 1))))
        default:
            onPick(ButtonAction(kind: kind))
        }
    }
}
