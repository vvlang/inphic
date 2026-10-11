import InphicCore
import SwiftUI

struct MacroPage: View {
    @Environment(DeviceController.self) private var controller
    @State private var editing: Macro?

    private var store: ProfileStore { controller.store }
    private var index: Int { store.selectedIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "宏",
                subtitle: "宏由鼠标固件自行播放。每条宏最多约 100 字节事件流，超出请拆成多条。"
            )

            Card(title: "宏列表", trailing: "固件上限 100 字节/条") {
                VStack(spacing: 0) {
                    if store.profiles[index].macros.isEmpty {
                        Text("还没有宏。新建一条后可以在「按键」页把它绑到侧键上。")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(.vertical, 14)
                    }
                    ForEach(store.profiles[index].macros) { macro in
                        macroRow(macro)
                        if macro.id != store.profiles[index].macros.last?.id {
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }
            }

            HStack {
                Button {
                    var next = Macro(id: nextMacroID())
                    next.name = "宏 \(next.id)"
                    next.actions = [.keyDown(0x04), .keyUp(0x04)]
                    controller.store.editSelected { $0.macros.append(next) }
                } label: {
                    Label("新建宏", systemImage: "plus")
                }
                .controlSize(.regular)

                Button("下发当前配置") { controller.applyCurrentProfile() }
                    .controlSize(.regular)
                    .keyboardShortcut("r", modifiers: .command)

                Spacer()
            }

            ApplyFooter()
        }
        .frame(maxWidth: 720, alignment: .leading)
        .sheet(item: $editing) { macro in
            MacroEditor(macro: macro) { updated in
                controller.store.editSelected { profile in
                    guard let position = profile.macros.firstIndex(where: { $0.id == updated.id }) else { return }
                    profile.macros[position] = updated
                }
            }
        }
    }

    private func macroRow(_ macro: Macro) -> some View {
        Button {
            editing = macro
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(macro.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("\(macro.trigger.title) · \(macro.actions.count) 个动作")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                byteBadge(macro)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除", role: .destructive) {
                controller.store.editSelected {
                    $0.macros.removeAll { $0.id == macro.id }
                }
            }
        }
    }

    private func byteBadge(_ macro: Macro) -> some View {
        let size = (try? MacroCommand.encodeActions(macro.actions).data.count) ?? 0
        let over = size > MacroCommand.maxEventBytes
        return Text("\(size) B")
            .font(Theme.Typography.caption)
            .foregroundStyle(over ? Theme.Palette.danger : Theme.Palette.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                (over ? Theme.Palette.danger : Theme.Palette.textTertiary).opacity(0.12),
                in: Capsule()
            )
    }

    private func nextMacroID() -> Int {
        (store.profiles[index].macros.map(\.id).max() ?? 0) + 1
    }
}

/// 宏编辑器。
struct MacroEditor: View {
    @State var macro: Macro
    let onSave: (Macro) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("宏名称", text: $macro.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .semibold))
                Button("完成") {
                    onSave(macro)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack {
                Picker("触发", selection: $macro.trigger) {
                    ForEach(MacroTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.title).tag(trigger)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

                if macro.trigger == .loop {
                    Stepper("循环 \(macro.loops) 次", value: $macro.loops, in: 1...255)
                        .frame(width: 200)
                }
                Spacer()
            }

            Divider().overlay(Theme.Palette.hairline)

            SectionLabel(text: "动作序列", trailing: "\(macro.actions.count) 个")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(macro.actions.enumerated()), id: \.offset) { position, action in
                        actionRow(position, action)
                        if position < macro.actions.count - 1 {
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }
            }
            .frame(height: 240)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                addButton("按键 A", action: .keyDown(0x04))
                addButton("按键 A 抬起", action: .keyUp(0x04))
                addButton("右移 10", action: .movement(dx: 10, dy: 0))
                addButton("等待 100ms", action: .wait(milliseconds: 100))
                Spacer()
                Button("清空", role: .destructive) { macro.actions.removeAll() }
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(Theme.Palette.canvas)
    }

    private func actionRow(_ position: Int, _ action: MacroAction) -> some View {
        HStack(spacing: 10) {
            Text("\(position + 1)")
                .font(Theme.Typography.numeralSmall)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 22, alignment: .trailing)

            Image(systemName: symbol(for: action))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 18)

            Text(describe(action))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)

            Spacer()

            Stepper(
                value: Binding(
                    get: { delayOf(action) },
                    set: { macro.actions[position] = withDelay(action, $0) }
                ),
                in: 1...2000,
                step: 1
            ) {
                Text("\(delayOf(action)) ms")
                    .font(Theme.Typography.numeralSmall)
                    .monospacedDigit()
            }
            .fixedSize()

            Button {
                macro.actions.remove(at: position)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.Palette.danger.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .frame(height: Theme.Metrics.rowHeight)
    }

    private func addButton(_ title: String, action: MacroAction) -> some View {
        Button {
            macro.actions.append(action)
        } label: {
            Text(title)
                .font(Theme.Typography.caption)
        }
        .controlSize(.small)
    }

    private func delayOf(_ action: MacroAction) -> Int {
        switch action {
        case let .key(_, _, delay): delay
        case let .move(_, _, delay): delay
        case let .wait(milliseconds): min(milliseconds, 2000)
        }
    }

    private func withDelay(_ action: MacroAction, _ delay: Int) -> MacroAction {
        switch action {
        case let .key(usage, pressed, _): .key(usage: usage, pressed: pressed, delay: delay)
        case let .move(dx, dy, _): .move(dx: dx, dy: dy, delay: delay)
        case .wait: .wait(milliseconds: delay)
        }
    }

    private func symbol(for action: MacroAction) -> String {
        switch action {
        case let .key(_, pressed, _): pressed ? "arrow.down.to.line" : "arrow.up.to.line"
        case .move: "arrow.left.and.right"
        case .wait: "clock"
        }
    }

    private func describe(_ action: MacroAction) -> String {
        switch action {
        case let .key(usage, pressed, _):
            let key = HidKey(rawValue: usage)?.title ?? String(format: "键 0x%02X", usage)
            return pressed ? "按下 \(key)" : "抬起 \(key)"
        case let .move(dx, dy, _):
            return "移动 (\(dx), \(dy))"
        case let .wait(milliseconds):
            return "等待 \(milliseconds) ms"
        }
    }
}
