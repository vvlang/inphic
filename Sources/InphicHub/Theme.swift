import InphicCore
import SwiftUI

/// 设计令牌。
///
/// 方向：**Swiss / 精密仪器**。深色底、发丝级分隔线、等宽数字强调「硬件规格」，
/// 避免「默认设置面板」那种每个控件都一样重的观感。
enum Theme {
    // MARK: 颜色

    enum Palette {
        static let canvas = Color(red: 0.055, green: 0.059, blue: 0.071)
        static let surface = Color(red: 0.094, green: 0.098, blue: 0.118)
        static let surfaceRaised = Color(red: 0.133, green: 0.137, blue: 0.161)
        static let hairline = Color.white.opacity(0.09)
        static let hairlineStrong = Color.white.opacity(0.16)

        static let textPrimary = Color(red: 0.937, green: 0.945, blue: 0.957)
        static let textSecondary = Color(red: 0.569, green: 0.596, blue: 0.647)
        static let textTertiary = Color(red: 0.376, green: 0.400, blue: 0.447)

        static let accent = Color(red: 1.0, green: 0.290, blue: 0.435)
        static let accentMuted = Color(red: 1.0, green: 0.290, blue: 0.435).opacity(0.16)
        static let positive = Color(red: 0.310, green: 0.855, blue: 0.612)
        static let warning = Color(red: 0.980, green: 0.702, blue: 0.294)
        static let danger = Color(red: 0.965, green: 0.373, blue: 0.373)
    }

    // MARK: 排版

    enum Typography {
        /// 规格数字用等宽，跳动时不会左右晃。
        static let numeral = Font.system(size: 22, weight: .semibold, design: .monospaced)
        static let numeralSmall = Font.system(size: 13, weight: .medium, design: .monospaced)
        static let title = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 10, weight: .medium)
        static let sectionLabel = Font.system(size: 10, weight: .semibold)
    }

    // MARK: 度量

    enum Metrics {
        static let corner: CGFloat = 8
        static let cardPadding: CGFloat = 16
        static let rowHeight: CGFloat = 34
    }
}

// MARK: - 复用组件

/// 分区标题：小号、加宽、字距拉开，像仪器面板上的丝印。
struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(Theme.Typography.sectionLabel)
                .tracking(1.4)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

/// 卡片容器：表面色 + 1px 分隔线，不用阴影（阴影在深色底上很脏）。
struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                SectionLabel(text: title, trailing: trailing)
            }
            content
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.corner)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
        )
    }
}

/// 规格行：左标签、右等宽数值，中间一条虚线引导。
struct SpecRow: View {
    let label: String
    let value: String
    var tint: Color = Theme.Palette.textPrimary

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            Rectangle()
                .strokeBorder(
                    Theme.Palette.hairline,
                    style: StrokeStyle(lineWidth: 1, dash: [1, 3])
                )
                .frame(height: 1)
            // 数值绝不允许折行 —— 侧边栏很窄时它会把 "1D57:FA65" 拆成两行。
            Text(value)
                .font(Theme.Typography.numeralSmall)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: Theme.Metrics.rowHeight)
    }
}

/// 连接状态指示点。
struct StatusDot: View {
    let state: DeviceController.ConnectionState

    private var color: Color {
        switch state {
        case .connected: Theme.Palette.positive
        case .searching, .idle: Theme.Palette.warning
        case .unavailable: Theme.Palette.danger
        }
    }

    private var label: String {
        switch state {
        case let .connected(device): device.kind.title
        case .searching: "搜索中"
        case .idle: "未启动"
        case .unavailable: "未连接"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 3).blur(radius: 2))
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// 应用状态条。
struct ApplyStatusBar: View {
    let state: DeviceController.ApplyState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("尚未下发")
                    .foregroundStyle(Theme.Palette.textTertiary)
            case let .applying(what):
                ProgressView().controlSize(.small)
                Text("正在下发 \(what)…")
                    .foregroundStyle(Theme.Palette.textSecondary)
            case let .succeeded(date):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Palette.positive)
                Text("已下发 \(date.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(Theme.Palette.positive)
            case let .failed(reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.danger)
                Text(reason)
                    .foregroundStyle(Theme.Palette.danger)
                    .lineLimit(2)
            }
            Spacer()
        }
        .font(Theme.Typography.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Palette.hairline, lineWidth: 1)
        )
    }
}

// MARK: - 颜色选择

/// 原生取色器。深色底上 NSColorPicker 需要浅色外观。
struct ColorWell: View {
    @Binding var color: RGB
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: Double(color.red) / 255,
                                green: Double(color.green) / 255,
                                blue: Double(color.blue) / 255))
                    .frame(width: 20, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.Palette.hairlineStrong, lineWidth: 1)
                    )
                Text(color.hexString)
                    .font(Theme.Typography.numeralSmall)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing) {
            ColorPicker("选择颜色", selection: Binding(
                get: { Color(red: Double(color.red) / 255,
                             green: Double(color.green) / 255,
                             blue: Double(color.blue) / 255) },
                set: { picked in
                    guard let rgb = picked.rgb else { return }
                    color = rgb
                }
            ), supportsOpacity: false)
            .padding(12)
        }
    }
}

extension Color {
    /// 从 SwiftUI Color 取回 8 位 RGB。取不到（色彩空间不匹配）时返回 nil。
    var rgb: RGB? {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return RGB(
            UInt8(clamping: Int((converted.redComponent * 255).rounded())),
            UInt8(clamping: Int((converted.greenComponent * 255).rounded())),
            UInt8(clamping: Int((converted.blueComponent * 255).rounded()))
        )
    }
}
