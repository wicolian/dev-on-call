import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool

    public init(exitCode: Int32, output: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
    }
}

public enum CommandRunner {
    public static func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        timeout: TimeInterval = 20,
        currentDirectory: URL? = nil
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runSynchronously(
                    executable: executable,
                    arguments: arguments,
                    input: input,
                    timeout: timeout,
                    currentDirectory: currentDirectory
                ))
            }
        }
    }

    public static func shell(
        _ command: String,
        timeout: TimeInterval = 20,
        currentDirectory: URL? = nil
    ) async -> CommandResult {
        await run(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            timeout: timeout,
            currentDirectory: currentDirectory
        )
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        input: String?,
        timeout: TimeInterval,
        currentDirectory: URL?
    ) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(exitCode: 127, output: "Executable not found: \(executable)", timedOut: false)
        }

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        if input != nil { process.standardInput = inputPipe }

        var outputData = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForReading.close()
            reader.wait()
            return CommandResult(exitCode: 126, output: error.localizedDescription, timedOut: false)
        }

        if let input, let data = input.data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
            try? inputPipe.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(max(1, timeout))
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()
        reader.wait()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, output: output, timedOut: timedOut)
    }
}
