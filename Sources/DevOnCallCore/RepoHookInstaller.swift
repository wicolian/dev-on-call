import Darwin
import Foundation

public struct RepoHookInfo: Sendable {
    public let repository: URL
    public let hooksDirectory: URL
    public let isSharedHooksDirectory: Bool
    public let isEnabled: Bool
    public let isWrapperInstalled: Bool
    public let preCommitCommand: String

    public init(
        repository: URL,
        hooksDirectory: URL,
        isSharedHooksDirectory: Bool,
        isEnabled: Bool,
        isWrapperInstalled: Bool,
        preCommitCommand: String
    ) {
        self.repository = repository
        self.hooksDirectory = hooksDirectory
        self.isSharedHooksDirectory = isSharedHooksDirectory
        self.isEnabled = isEnabled
        self.isWrapperInstalled = isWrapperInstalled
        self.preCommitCommand = preCommitCommand
    }
}

public enum RepoHookInstallerError: LocalizedError {
    case notARepository(String)
    case commandFailed(String)
    case existingBackup(URL)
    case unmanagedWrapper(URL)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path):
            return "Not a Git repository: \(path)"
        case .commandFailed(let message):
            return message
        case .existingBackup(let url):
            return "Refusing to replace the existing hook backup at \(url.path)."
        case .unmanagedWrapper(let url):
            return "Refusing to remove a pre-commit hook Dev On Call does not own: \(url.path)."
        }
    }
}

public enum RepoHookInstaller {
    public static let marker = "# Dev On Call managed pre-commit wrapper v1"
    private static let originalName = "pre-commit.dev-on-call-original"

    @discardableResult
    public static func install(at path: String, command: String? = nil) throws -> RepoHookInfo {
        var info = try inspect(at: path)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: info.hooksDirectory, withIntermediateDirectories: true)

        let hook = info.hooksDirectory.appendingPathComponent("pre-commit")
        let original = info.hooksDirectory.appendingPathComponent(originalName)
        if fileManager.fileExists(atPath: hook.path), !isManagedHook(hook) {
            guard !fileManager.fileExists(atPath: original.path) else {
                throw RepoHookInstallerError.existingBackup(original)
            }
            try fileManager.moveItem(at: hook, to: original)
        }

        try wrapperScript.data(using: .utf8)!.write(to: hook, options: .atomic)
        guard chmod(hook.path, 0o755) == 0 else {
            throw RepoHookInstallerError.commandFailed("Could not make \(hook.path) executable.")
        }

        try git(["-C", info.repository.path, "config", "--local", "devoncall.enabled", "true"])
        if let command {
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try? git(["-C", info.repository.path, "config", "--local", "--unset-all", "devoncall.preCommitCommand"])
            } else {
                try git(["-C", info.repository.path, "config", "--local", "devoncall.preCommitCommand", command])
            }
        }

        info = try inspect(at: info.repository.path)
        return info
    }

    @discardableResult
    public static func uninstall(at path: String) throws -> RepoHookInfo {
        let info = try inspect(at: path)
        _ = try? git(["-C", info.repository.path, "config", "--local", "--unset-all", "devoncall.enabled"])
        _ = try? git(["-C", info.repository.path, "config", "--local", "--unset-all", "devoncall.preCommitCommand"])

        // Shared hook directories may serve other repositories. Leave the tiny
        // opt-in wrapper in place and disable only this repository.
        if !info.isSharedHooksDirectory {
            let fileManager = FileManager.default
            let hook = info.hooksDirectory.appendingPathComponent("pre-commit")
            let original = info.hooksDirectory.appendingPathComponent(originalName)
            if fileManager.fileExists(atPath: hook.path) {
                guard isManagedHook(hook) else { throw RepoHookInstallerError.unmanagedWrapper(hook) }
                try fileManager.removeItem(at: hook)
            }
            if fileManager.fileExists(atPath: original.path) {
                try fileManager.moveItem(at: original, to: hook)
            }
        }

        return try inspect(at: info.repository.path)
    }

    public static func inspect(at path: String) throws -> RepoHookInfo {
        let expanded = NSString(string: path).expandingTildeInPath
        let requested = URL(fileURLWithPath: expanded).standardizedFileURL
        let rootResult = runGit(["-C", requested.path, "rev-parse", "--show-toplevel"])
        guard rootResult.status == 0 else { throw RepoHookInstallerError.notARepository(requested.path) }

        let repository = URL(fileURLWithPath: rootResult.output).standardizedFileURL
        let gitDirectory = URL(
            fileURLWithPath: try git(["-C", repository.path, "rev-parse", "--absolute-git-dir"])
        ).standardizedFileURL

        let configuredHooks = runGit(["-C", repository.path, "config", "--path", "--get", "core.hooksPath"])
        let hooksPath: String
        if configuredHooks.status == 0, !configuredHooks.output.isEmpty {
            hooksPath = configuredHooks.output
        } else {
            hooksPath = try git(["-C", repository.path, "rev-parse", "--git-path", "hooks"])
        }
        let hooksDirectory: URL
        if hooksPath.hasPrefix("/") {
            hooksDirectory = URL(fileURLWithPath: hooksPath).standardizedFileURL
        } else {
            hooksDirectory = repository.appendingPathComponent(hooksPath).standardizedFileURL
        }

        let localRoots = [repository.path + "/", gitDirectory.path + "/"]
        let isShared = !localRoots.contains { hooksDirectory.path.hasPrefix($0) }
        let enabled = runGit(["-C", repository.path, "config", "--local", "--bool", "--get", "devoncall.enabled"]).output == "true"
        let configuredCommand = runGit(["-C", repository.path, "config", "--local", "--get", "devoncall.preCommitCommand"]).output
        let hook = hooksDirectory.appendingPathComponent("pre-commit")

        return RepoHookInfo(
            repository: repository,
            hooksDirectory: hooksDirectory,
            isSharedHooksDirectory: isShared,
            isEnabled: enabled,
            isWrapperInstalled: isManagedHook(hook),
            preCommitCommand: configuredCommand
        )
    }

    private static func isManagedHook(_ url: URL) -> Bool {
        guard let prefix = try? String(contentsOf: url, encoding: .utf8).prefix(256) else { return false }
        return prefix.contains(marker)
    }

    @discardableResult
    private static func git(_ arguments: [String]) throws -> String {
        let result = runGit(arguments)
        guard result.status == 0 else {
            throw RepoHookInstallerError.commandFailed(result.output.isEmpty ? "Git command failed." : result.output)
        }
        return result.output
    }

    private static func runGit(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (126, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }

    private static let wrapperScript = """
    #!/bin/sh
    \(marker)
    hook_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    original="$hook_dir/\(originalName)"
    status=0

    if [ -x "$original" ]; then
      "$original" "$@" || status=$?
    fi

    enabled="$(git config --local --bool --get devoncall.enabled 2>/dev/null || true)"
    if [ "$enabled" != "true" ]; then
      exit "$status"
    fi

    configured_command="$(git config --local --get devoncall.preCommitCommand 2>/dev/null || true)"
    if [ "$status" -eq 0 ] && [ -n "$configured_command" ]; then
      /bin/zsh -lc "$configured_command" || status=$?
    fi

    if [ "$status" -ne 0 ]; then
      alert_cli="$(command -v dev-on-call 2>/dev/null || true)"
      if [ -z "$alert_cli" ] && [ -x "$HOME/.local/bin/dev-on-call" ]; then
        alert_cli="$HOME/.local/bin/dev-on-call"
      fi
      if [ -n "$alert_cli" ]; then
        repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
        "$alert_cli" alert \
          --source "$repo_name pre-commit" \
          --severity critical \
          --title "Pre-commit failed in $repo_name" \
          --body "Exit $status. Open the repository terminal for details." >/dev/null 2>&1 || true
      fi
    fi

    exit "$status"
    """
}
