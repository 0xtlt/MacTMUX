import Foundation

public enum DiagnosticLog {
    public static let path = "/tmp/mactmux-debug.log"

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["MACTMUX_DEBUG_LOG"] == "1"
    }

    public static func write(
        _ message: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        path: String = Self.path
    ) {
        guard isEnabled(environment: environment) else {
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            return
        }
        defer {
            try? handle.close()
        }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    }

    public static func clear(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        path: String = Self.path
    ) {
        guard isEnabled(environment: environment) else {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}
