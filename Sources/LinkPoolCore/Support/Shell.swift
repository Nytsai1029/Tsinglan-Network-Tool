import Foundation

/// Small wrapper around Process for read-only system commands and for the
/// privileged helper.
public enum Shell {
    @discardableResult
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return nil
        }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    public static func runStatus(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs a shell command with an administrator prompt (AppleScript).
    /// The command is passed as a single quoted argument; we refuse anything
    /// that contains characters we cannot safely quote.
    public static func runAsAdmin(_ command: String) -> (Bool, String) {
        guard !command.contains("\"") && !command.contains("\\") else {
            return (false, "拒绝执行包含引号或反斜杠的特权命令")
        }
        let script = "do shell script \"\(command)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus == 0, text)
    }
}
