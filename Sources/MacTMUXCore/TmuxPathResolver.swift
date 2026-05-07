import Foundation

public enum TmuxPathResolver {
    public static let trustedPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    public static func autodetect(fileManager: FileManager = .default) -> String? {
        trustedPaths.first { isValidTmuxBinary($0, fileManager: fileManager) }
    }

    public static func isValidTmuxBinary(_ path: String, fileManager: FileManager = .default) -> Bool {
        guard URL(fileURLWithPath: path).lastPathComponent == "tmux" else {
            return false
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }
}
