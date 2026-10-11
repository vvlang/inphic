import InphicCore
import SwiftUI

struct PowerPage: View {
    @Environment(DeviceController.self) private var controller

    private var store: ProfileStore { controller.store }
    private var index: Int { store.selectedIndex }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "电源",
                    subtitle: "浅睡与深睡会和灯光共用同一条命令，改动时会一起下发当前灯光值。"
                )

                Card(title: "电池") {
                    HStack(alignment: .center, spacing: 16) {
                        ZStack {
                            Circle()
                                .stroke(Theme.Palette.hairlineStrong, lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: (Double(controller.batteryLevel ?? 0) / 100))
                                .stroke(batteryTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(controller.batteryLevel ?? 0)%")
                                .font(Theme.Typography.numeralSmall)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .frame(width: 88, height: 88)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.batteryStatus == .charging ? "充电中" : "电量")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Text(statusNote)
                                .font(Theme.Typography.body)
                                .foregroundStyle(controller.batteryStatus == nil
                                                 ? Theme.Palette.textTertiary
                                                 : Theme.Palette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }

                Card(title: "休眠") {
                    VStack(spacing: 0) {
                        sliderRow(
                            "浅睡超时",
                            value: Binding(
                                get: { store.profiles[index].lighting.lightSleepMinutes },
                                set: { value in
                                    controller.store.editSelected { $0.lighting.lightSleepMinutes = value }
                                }
                            ),
                            range: 0.5...30,
                            step: 0.5,
                            text: { "\($0.formatted(.number.precision(.fractionLength(1)))) 分钟" }
                        )
                        Divider().overlay(Theme.Palette.hairline)
                        sliderRow(
                            "深度休眠",
                            value: Binding(
                                get: { Double(store.profiles[index].lighting.deepSleepMinutes) },
                                set: { value in
                                    controller.store.editSelected {
                                        $0.lighting.deepSleepMinutes = Int(value.rounded())
                                    }
                                }
                            ),
                            range: 1...60,
                            step: 1,
                            text: { "\(Int($0)) 分钟" }
                        )
                    }
                }

                ApplyFooter()
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var statusNote: String {
        switch controller.batteryStatus {
        case .charging: "接在电源上，正在充电"
        case .full: "已充满"
        case .normal: "正常使用中"
        case nil:
            // 实测：电量包走 Report ID 3，每 2 秒一次，但**只在鼠标醒着的时候**。
            // 鼠标进深睡（出厂 5 分钟）后就不再上报，也不再响应配置写入。
            "鼠标睡着时不上报 —— 动一下鼠标即可，电量约 2 秒后出现"
        }
    }

    private var batteryTint: Color {
        guard let level = controller.batteryLevel else { return Theme.Palette.textTertiary }
        return switch level {
        case ..<20: Theme.Palette.danger
        case ..<40: Theme.Palette.warning
        default: Theme.Palette.positive
        }
    }

    private func sliderRow(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>,
        step: Double, text: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(text(value.wrappedValue))
                    .font(Theme.Typography.numeralSmall)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
