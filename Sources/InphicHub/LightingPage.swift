import InphicCore
import SwiftUI

struct LightingPage: View {
    @Environment(DeviceController.self) private var controller

    private var store: ProfileStore { controller.store }
    private var index: Int { store.selectedIndex }

    private func edit(_ body: @escaping (inout LightingConfiguration) -> Void) {
        controller.store.editSelected { profile in body(&profile.lighting) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "灯光",
                    subtitle: "鼠标只有一个 RGB 区域。呼吸 / 霓虹 / 循环等动态效果由固件生成，不是多颗独立灯珠。"
                )

                Card(title: "灯效") {
                    VStack(spacing: 0) {
                        Picker("", selection: Binding(
                            get: { store.profiles[index].lighting.mode },
                            set: { mode in edit { $0.mode = mode } }
                        )) {
                            ForEach(LightMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Divider().overlay(Theme.Palette.hairline).padding(.vertical, 12)

                        HStack(alignment: .top, spacing: 16) {
                            preview
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("颜色")
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                    Spacer()
                                    ColorWell(color: Binding(
                                        get: { store.profiles[index].lighting.color },
                                        set: { value in
                                            edit {
                                                $0.color = value
                                                // 选了颜色就切成常亮，否则看不出变化。
                                                if $0.mode == .off { $0.mode = .staticColor }
                                            }
                                        }
                                    ))
                                }

                                sliderRow(
                                    "亮度",
                                    value: Binding(
                                        get: { store.profiles[index].lighting.brightness },
                                        set: { value in edit { $0.brightness = value } }
                                    ),
                                    range: 1...8,
                                    footnote: "固件存 \(store.profiles[index].lighting.mode == .off ? "—" : "1–8")"
                                )

                                sliderRow(
                                    "速度",
                                    value: Binding(
                                        get: { store.profiles[index].lighting.speed },
                                        set: { value in edit { $0.speed = value } }
                                    ),
                                    range: 1...8,
                                    footnote: "仅呼吸 / 循环呼吸生效"
                                )
                            }
                        }
                    }
                }

                Card(title: "快速配色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                        ForEach(DPIDefaultColors.palette, id: \.self) { swatch in
                            Button {
                                edit {
                                    $0.color = swatch
                                    if $0.mode == .off { $0.mode = .staticColor }
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(red: Double(swatch.red) / 255,
                                                green: Double(swatch.green) / 255,
                                                blue: Double(swatch.blue) / 255))
                                    .frame(height: 30)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(
                                                store.profiles[index].lighting.color == swatch
                                                    ? Theme.Palette.accent : Theme.Palette.hairline,
                                                lineWidth: store.profiles[index].lighting.color == swatch ? 2 : 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                ApplyFooter()
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    /// 灯光预览：一个用当前颜色填充的圆角方块，暗色下有一点辉光。
    private var preview: some View {
        let lighting = store.profiles[index].lighting
        let tint = Color(red: Double(lighting.color.red) / 255,
                         green: Double(lighting.color.green) / 255,
                         blue: Double(lighting.color.blue) / 255)
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(lighting.mode == .off ? 0.08 : 0.30))
                .frame(width: 132, height: 132)
            RoundedRectangle(cornerRadius: 12)
                .fill(tint)
                .frame(width: 132, height: 132)
                .blur(radius: lighting.mode == .off ? 0 : 14)
                .opacity(lighting.mode == .off ? 0 : 0.45)
            VStack(spacing: 3) {
                Image(systemName: lighting.mode == .off ? "moon.zzz" : "lightbulb.max.fill")
                    .font(.system(size: 22))
                Text(lighting.mode.title)
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(width: 148, height: 148)
    }

    private func sliderRow(
        _ title: String, value: Binding<Int>, range: ClosedRange<Int>, footnote: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("\(value.wrappedValue)")
                    .font(Theme.Typography.numeralSmall)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(footnote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            .controlSize(.small)
        }
    }
}
