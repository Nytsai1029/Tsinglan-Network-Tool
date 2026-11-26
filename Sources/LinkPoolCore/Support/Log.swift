import Foundation
import os

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String
}

public extension Notification.Name {
    static let linkPoolLogDidAppend = Notification.Name("com.nytsai.linkpool.log.append")
}

/// Thread-safe ring buffer + unified-log mirror. Keeps at most 2000 entries in
/// memory and writes a rotating file at ~/Library/Logs/LinkPool.log.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private let capacity = 2000
    private let logger = Logger(subsystem: "com.nytsai.linkpool", category: "app")
    private let fileURL: URL
    private let fileQueue = DispatchQueue(label: "com.nytsai.linkpool.logfile")
    private var fileHandle: FileHandle?

    public init() {
        let logs = AppPaths.logsDirectory
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        fileURL = logs.appendingPathComponent("LinkPool.log")
        openFile()
    }

    public func debug(_ category: String, _ message: String) { append(.debug, category, message) }
    public func info(_ category: String, _ message: String) { append(.info, category, message) }
    public func warn(_ category: String, _ message: String) { append(.warn, category, message) }
    public func error(_ category: String, _ message: String) { append(.error, category, message) }

    public func snapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock(); buffer.removeAll(); lock.unlock()
        NotificationCenter.default.post(name: .linkPoolLogDidAppend, object: nil)
    }

    private func append(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()

        switch level {
        case .debug: logger.debug("[\(category, privacy: .public)] \(message, privacy: .private)")
        case .info: logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warn: logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: logger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }

        NotificationCenter.default.post(name: .linkPoolLogDidAppend, object: nil)

        fileQueue.async { [weak self] in self?.writeLine(entry) }
    }

    private func openFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        // Rotate at 2 MB.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64, size > 2 * 1024 * 1024 {
            let old = fileURL.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: fileURL, to: old)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func writeLine(_ entry: LogEntry) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: entry.date)) [\(entry.level.label)] [\(entry.category)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}
