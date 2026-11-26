import Foundation

/// Central place for on-disk locations. `LINKPOOL_HOME` lets development and
/// tests run against a throw-away directory instead of the real profile.
public enum AppPaths {
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["LINKPOOL_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/LinkPool", isDirectory: true)
    }

    public static var logsDirectory: URL {
        home.appendingPathComponent("Library/Logs", isDirectory: true)
    }

    public static var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static func ensure() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
