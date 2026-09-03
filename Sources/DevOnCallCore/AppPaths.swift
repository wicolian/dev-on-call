import Foundation

public enum AppPaths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["DEV_ON_CALL_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("DevOnCall", isDirectory: true)
    }

    public static var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public static var archive: URL { root.appendingPathComponent("events.json") }
    public static var log: URL { root.appendingPathComponent("dev-on-call.log") }

    public static func prepare() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }
}
