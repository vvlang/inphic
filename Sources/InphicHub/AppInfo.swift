import Foundation

/// App 元信息。版本号以仓库根目录的 `VERSION` 文件为准，
/// 由 `Scripts/build-app.sh` 与 GitHub Actions 在构建时注入。
///
/// 这里的值是 **Xcode / SwiftPM 直接跑**时的兜底；
/// 正式打包时会被 Info.plist 里的 `CFBundleShortVersionString` 覆盖。
enum AppInfo {
    static let name = "Inphic Hub"
    static let author = "AIYeon"
    static let repository = "https://github.com/vvlang/inphic"
    static let bundleIdentifier = "cn.inphic.hub.mac"
    /// 与 VERSION 文件保持一致。
    static let version = "0.1.0"

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var copyright: String {
        "© 2026 \(author) · MIT License"
    }

    static var disclaimer: String {
        "非官方工具，与英菲克（INPHIC）无隶属关系。协议由逆向分析得出。"
    }

    /// 打包后从 Info.plist 读真实版本，读不到再退回编译期常量。
    static var displayVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? version
        return "\(name) \(short) (\(build))"
    }
}
