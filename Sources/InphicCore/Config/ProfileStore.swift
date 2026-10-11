import Foundation
import Observation

/// 配置档的本地存储。
///
/// 路径：`~/Library/Application Support/InphicHub/profiles.json`
/// 写入用「临时文件 + rename」保证原子性，避免断电/崩溃写坏配置。
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profiles: [DeviceProfile]
    public var selectedProfileID: UUID {
        didSet {
            guard selectedProfileID != oldValue else { return }
            UserDefaults.standard.set(selectedProfileID.uuidString, forKey: Self.selectionKey)
        }
    }

    private static let selectionKey = "InphicHub.selectedProfileID"
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url

        let loaded: [DeviceProfile]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data),
           !decoded.isEmpty {
            loaded = decoded
        } else {
            loaded = [DeviceProfile.factory]
        }
        self.profiles = loaded

        let remembered = UserDefaults.standard.string(forKey: Self.selectionKey)
            .flatMap(UUID.init(uuidString:))
        self.selectedProfileID = loaded.contains { $0.id == remembered } ? remembered! : loaded[0].id
    }

    public var selectedIndex: Int {
        profiles.firstIndex { $0.id == selectedProfileID } ?? 0
    }

    /// 取当前配置档的引用，调用方修改后调用 `commit()`。
    public func editSelected(_ body: (inout DeviceProfile) -> Void) {
        body(&profiles[selectedIndex])
        save()
    }

    public func addProfile(named name: String? = nil) {
        var profile = DeviceProfile(name: name ?? "配置 \(profiles.count + 1)")
        profile.id = UUID()
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    /// 至少要保留一个配置档。
    public func deleteSelected() -> Bool {
        guard profiles.count > 1 else { return false }
        let index = selectedIndex
        profiles.remove(at: index)
        selectedProfileID = profiles[min(index, profiles.count - 1)].id
        save()
        return true
    }

    public func duplicateSelected() {
        let current = profiles[selectedIndex]
        var copy = current
        copy.id = UUID()
        copy.name = nextAvailableName(basedOn: current.name)
        profiles.append(copy)
        selectedProfileID = copy.id
        save()
    }

    private func nextAvailableName(basedOn name: String) -> String {
        let stem = name.replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
        var index = 2
        var candidate = "\(stem) \(index)"
        let existing = Set(profiles.map(\.name))
        while existing.contains(candidate) {
            index += 1
            candidate = "\(stem) \(index)"
        }
        return candidate
    }

    public func resetSelectedToFactory() {
        let index = selectedIndex
        var fresh = DeviceProfile.factory
        fresh.id = profiles[index].id
        fresh.name = profiles[index].name
        profiles[index] = fresh
        save()
    }

    /// 导入配置档（追加），同名自动改名。
    public func importProfiles(from data: Data) throws {
        let incoming = try JSONDecoder().decode([DeviceProfile].self, from: data)
        for var profile in incoming {
            profile.id = UUID()
            profile.name = nextAvailableName(basedOn: profile.name)
            profiles.append(profile)
        }
        save()
    }

    /// 导出全部配置档。
    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }

    // MARK: - 落盘

    public func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            // 原子写：先写临时文件再 rename，避免半截文件。
            let temporary = directory.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            NSLog("[Inphic] 保存配置失败: \(error.localizedDescription)")
        }
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("InphicHub/profiles.json")
    }
}
