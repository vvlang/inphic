import InphicCore
import SwiftUI

struct DPIPage: View {
    @Environment(DeviceController.self) private var controller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "DPI",
                    subtitle: "8 个档位，每档可单独启用并设定指示灯颜色。关闭的档位不会被 DPI 循环键选中。"
                )

                currentStageCard
                stagesCard
                sensorCard

                ApplyFooter()
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var currentStageCard: some View {
        Card(title: "当前档位") {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("档位")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("\(stage.value)")
                        .font(Theme.Typography.numeral)
                        .foregroundStyle(Theme.Palette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("档位序号")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("\(stageIndex + 1) / \(DPILimit.stageCount)")
                        .font(Theme.Typography.numeral)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                if let hardware = controller.hardwareDPIStage {
                    Text("鼠标上报：第 \(hardware) 档")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.positive)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.Palette.positive.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var stagesCard: some View {
        Card(title: "档位", trailing: "50 – \(DPILimit.maximum) DPI") {
            VStack(spacing: 0) {
                ForEach(0..<DPILimit.stageCount, id: \.self) { index in
                    stageRow(index)
                    if index < DPILimit.stageCount - 1 {
                        Divider().overlay(Theme.Palette.hairline)
                    }
                }
            }
        }
    }

    private func stageRow(_ index: Int) -> some View {
        let binding = Binding<Bool>(
            get: { store.profiles[store.selectedIndex].dpi.stages[index].isEnabled },
            set: { value in
                controller.store.editSelected { profile in
                    profile.dpi.stages[index].isEnabled = value
                    if !value && profile.dpi.activeStage == index + 1 {
                        // 当前档被关掉时，落到第一个可用档，避免固件收到越界档位。
                        profile.dpi.activeStage = (0..<DPILimit.stageCount)
                            .first { profile.dpi.stages[$0].isEnabled }.map { $0 + 1 } ?? 1
                    }
                }
            }
        )
        let dpiBinding = Binding<Int>(
            get: { store.profiles[store.selectedIndex].dpi.stages[index].value },
            set: { value in
                controller.store.editSelected { profile in
                    profile.dpi.stages[index].value = min(max(value, DPILimit.minimum), DPILimit.maximum)
                }
            }
        )
        let colorBinding = Binding<RGB>(
            get: { store.profiles[store.selectedIndex].dpi.stages[index].color },
            set: { value in
                controller.store.editSelected { $0.dpi.stages[index].color = value }
            }
        )

        return HStack(spacing: 12) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Text("档 \(index + 1)")
                .font(Theme.Typography.body)
                .foregroundStyle(binding.wrappedValue
                                 ? Theme.Palette.textPrimary
                                 : Theme.Palette.textTertiary)
                .frame(width: 42, alignment: .leading)

            HStack(spacing: 2) {
                TextField("DPI", value: dpiBinding, format: .number)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.numeralSmall)
                    .frame(width: 58)
                    .disabled(!binding.wrappedValue)
                Text("DPI")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 5))
            .opacity(binding.wrappedValue ? 1 : 0.4)

            Spacer()

            ColorWell(color: colorBinding)
                .opacity(binding.wrappedValue ? 1 : 0.35)
                .disabled(!binding.wrappedValue)
        }
        .frame(height: Theme.Metrics.rowHeight)
    }

    private var sensorCard: some View {
        Card(title: "传感器") {
            let ripple = Binding(
                get: { store.profiles[store.selectedIndex].dpi.ripple },
                set: { value in controller.store.editSelected { $0.dpi.ripple = value } }
            )
            let snap = Binding(
                get: { store.profiles[store.selectedIndex].dpi.angleSnap },
                set: { value in controller.store.editSelected { $0.dpi.angleSnap = value } }
            )
            let motion = Binding(
                get: { store.profiles[store.selectedIndex].dpi.motionSync },
                set: { value in controller.store.editSelected { $0.dpi.motionSync = value } }
            )
            let loft = Binding(
                get: { store.profiles[store.selectedIndex].dpi.liftOffDistance },
                set: { value in controller.store.editSelected { $0.dpi.liftOffDistance = value } }
            )

            VStack(spacing: 0) {
                toggleRow("涟漪控制", "抑制轨迹抖动，代价是微调变难", isOn: ripple)
                Divider().overlay(Theme.Palette.hairline)
                toggleRow("角度吸附", "45° 方向自动锁死，代价是弧线变折线", isOn: snap)
                Divider().overlay(Theme.Palette.hairline)
                toggleRow("Motion Sync", "发射前读取传感器，8000Hz 下有效", isOn: motion)

                Divider().overlay(Theme.Palette.hairline)
                HStack {
                    Text("抬升距离")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Picker("", selection: loft) {
                        Text("1 mm").tag(UInt8(0))
                        Text("2 mm").tag(UInt8(1))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                .frame(height: Theme.Metrics.rowHeight)
            }
        }
    }

    private func toggleRow(_ title: String, _ note: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .frame(height: Theme.Metrics.rowHeight)
    }

    // MARK: - 派生

    private var store: ProfileStore { controller.store }

    private var stageIndex: Int {
        max(0, min(DPILimit.stageCount - 1, store.profiles[store.selectedIndex].dpi.activeStage - 1))
    }

    private var stage: DPIStage {
        store.profiles[store.selectedIndex].dpi.stages[stageIndex]
    }
}
