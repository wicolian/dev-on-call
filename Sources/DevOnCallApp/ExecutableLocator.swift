import Foundation

enum ExecutableLocator {
    static func find(_ command: String, customPath: String = "") -> String? {
        let expandedCustom = NSString(string: customPath).expandingTildeInPath
        if !expandedCustom.isEmpty, FileManager.default.isExecutableFile(atPath: expandedCustom) {
            return expandedCustom
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixedCandidates = [
            "\(home)/.local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)"
        ]
        if let found = fixedCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        if command == "codex" {
            let nodeRoot = URL(fileURLWithPath: home)
                .appendingPathComponent(".nvm/versions/node", isDirectory: true)
            let versions = (try? FileManager.default.contentsOfDirectory(
                at: nodeRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let candidate = version.appendingPathComponent("bin/codex").path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }

        return nil
    }
}
