import InphicCore
import SwiftUI

struct PerformancePage: View {
    @Environment(DeviceController.self) private var controller

    private var store: ProfileStore { controller.store }
    private var index: Int { store.selectedIndex }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "性能",
                    subtitle: "轮询率受连接方式限制 —— 2.4G 与有线最高 1000Hz，只有 8K 接收器能到 8000Hz。"
                )

                Card(title: "轮询率", trailing: capNote) {
                    VStack(spacing: 0) {
                        ForEach(availableRates, id: \.self) { rate in
                            rateRow(rate)
                            if rate != availableRates.last {
                                Divider().overlay(Theme.Palette.hairline)
                            }
                        }
                    }
                }

                Card(title: "按键响应") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("去抖时间")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text("越小越跟手，但连击容易漏判")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { store.profiles[index].lighting.debounceMilliseconds },
                                set: { value in
                                    controller.store.editSelected { $0.lighting.debounceMilliseconds = value }
                                }
                            ),
                            in: 1...50,
                            step: 1
                        ) {
                            Text("\(store.profiles[index].lighting.debounceMilliseconds) ms")
                                .font(Theme.Typography.numeralSmall)
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .frame(height: Theme.Metrics.rowHeight)
                }

                ApplyFooter()
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func rateRow(_ rate: PollingRate) -> some View {
        let selected = store.profiles[index].polling.pollingRate == rate
        let available = availableRates.contains(rate)
        return Button {
            controller.store.editSelected { $0.polling.pollingRate = rate }
        } label: {
            HStack {
                Text("\(rate.rawValue) Hz")
                    .font(Theme.Typography.numeralSmall)
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textPrimary)
                Spacer()
                Text("固件码 \(rate.firmwareValue)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.3)
        .frame(height: Theme.Metrics.rowHeight)
        .disabled(!available)
    }

    private var maxRate: PollingRate {
        DeviceCapabilities(kind: controller.state.device?.kind ?? .wired).maxPollingRate
    }

    /// 只列出不超过当前连接方式上限的档位。
    private var availableRates: [PollingRate] {
        PollingRate.allCases.filter { $0.rawValue <= maxRate.rawValue }
    }

    private var capNote: String? {
        let device = controller.state.device
        guard let device, device.kind != .wired else { return nil }
        return device.kind == .wireless8K ? nil : "\(device.kind.title)上限 \(maxRate.rawValue)Hz"
    }
}
