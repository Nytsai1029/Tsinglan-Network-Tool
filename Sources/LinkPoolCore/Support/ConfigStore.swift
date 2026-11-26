import Foundation

/// Reads and writes the single JSON config document.
///
/// The file contains no secrets (passwords live in the Keychain). Writes are
/// atomic and debounced so rapid UI edits cannot corrupt the file.
public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()

    private let queue = DispatchQueue(label: "com.nytsai.linkpool.config")
    private var pendingWrite: DispatchWorkItem?
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        let dir = AppPaths.supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("config.json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public var path: String { fileURL.path }

    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            Log.shared.warn("config", "配置文件解析失败，已备份并使用默认配置：\(error.localizedDescription)")
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return AppConfig()
        }
    }

    /// Persist immediately (used on quit and after structural changes).
    public func saveNow(_ config: AppConfig) {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            write(config)
        }
    }

    /// Coalesce writes that happen within `delay` seconds.
    public func save(_ config: AppConfig, delay: TimeInterval = 0.4) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWrite?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.write(config) }
            self.pendingWrite = item
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func write(_ config: AppConfig) {
        do {
            let data = try encoder.encode(config)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            Log.shared.error("config", "写入配置失败：\(error.localizedDescription)")
        }
    }
}
