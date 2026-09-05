// AWSClient.swift
// DevOnCallAWS
//
// Ported from the standalone "AWS Boxes" menu-bar app
// (Sources/AWSBoxesCore/AWSClient.swift, github.com/koushik/aws-boxes, by
// Koushik) and folded into Dev On Call. Still no AWS SDK dependency — this
// shells out to the `aws` CLI (`--output json`) exactly like the original,
// using whatever credentials/profile resolution the CLI already knows about
// (SSO, env vars, credential_process, etc.). Dev On Call itself never reads
// or stores AWS credentials.
//
// Two additions beyond the original, both about robustness inside a
// multi-feature menu-bar app rather than a change in behavior:
//
// 1. `run` is now a true `async` suspension (a background dispatch queue
//    drains the process instead of blocking the calling thread), and every
//    call carries a timeout that force-kills a hung `aws` process. The
//    original synchronously blocked whatever thread called it with no
//    timeout at all — fine for a single-purpose app, but inside Dev On Call
//    a hung CLI call must not freeze the shared Herdr/probe monitor loop or
//    leave the refresh spinner stuck forever.
// 2. On this machine, some networks resolve AWS endpoints over a broken
//    IPv6/NAT64 path that the `aws` CLI (botocore/Python) can hang on. If
//    `~/.claude/py4` (a small sitecustomize.py that forces IPv4 resolution)
//    exists, it is added to the subprocess's PYTHONPATH. This is a no-op
//    directory check on any machine where that path doesn't exist.

import Darwin
import Foundation

/// Everything that talks to the `aws` CLI. No AWS SDK dependency — we shell
/// out and parse `--output json`, same credentials/profile resolution the
/// CLI already knows how to do (SSO, env vars, credential_process, etc.)
public struct AWSClient {

    public struct CLIError: Error, LocalizedError {
        let command: String
        let exitCode: Int32
        let stderr: String

        public var errorDescription: String? {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "\(command) failed (exit \(exitCode))"
            }
            // AWS CLI errors are usually a single readable line already,
            // e.g. "An error occurred (ExpiredToken) ...". Keep just the
            // last non-empty line so it fits inline in the UI.
            let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
            return lastLine
        }
    }

    public struct NotFoundError: Error, LocalizedError {
        public var errorDescription: String? {
            "aws CLI not found at /opt/homebrew/bin/aws or /usr/local/bin/aws"
        }
    }

    /// Locates the aws binary. Homebrew Apple Silicon path first, then the
    /// Intel/legacy Homebrew path.
    public static func resolveBinaryPath() -> String? {
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Machine-specific IPv4-forcing workaround directory (see file header).
    /// Returns nil (a pure no-op) unless the directory actually exists.
    private static var ipv4WorkaroundPythonPath: String? {
        let candidate = NSHomeDirectory() + "/.claude/py4"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return candidate
    }

    /// Runs `aws <args>` and returns stdout as Data. Throws CLIError with the
    /// trimmed stderr text on non-zero exit or timeout, or NotFoundError if
    /// the binary isn't present at either well-known path. Never blocks the
    /// calling thread — the process wait happens on a background queue.
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 20) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try runSynchronously(args, timeout: timeout)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSynchronously(_ args: [String], timeout: TimeInterval) throws -> Data {
        guard let binary = resolveBinaryPath() else {
            throw NotFoundError()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Keep the CLI non-interactive: never let it prompt (MFA, SSO
        // device-flow browser open, pager, etc.) and block forever.
        var env = ProcessInfo.processInfo.environment
        env["AWS_PAGER"] = ""
        if let workaround = ipv4WorkaroundPythonPath {
            env["PYTHONPATH"] = env["PYTHONPATH"].map { "\(workaround):\($0)" } ?? workaround
        }
        process.environment = env

        // Drain both pipes concurrently on background threads. Reading only
        // after the process exits risks a classic deadlock: a process whose
        // stdout fills the pipe buffer before exiting will block on write
        // forever if nothing is reading the other end.
        var stdoutData = Data()
        var stderrData = Data()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            drainGroup.wait()
            throw CLIError(command: args.joined(separator: " "), exitCode: -1, stderr: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(max(1, timeout))
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(250_000)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }

        process.waitUntilExit()
        drainGroup.wait()

        if timedOut {
            throw CLIError(
                command: args.joined(separator: " "),
                exitCode: -1,
                stderr: "Timed out after \(Int(timeout))s waiting for aws CLI (no response — check network/SSO session)."
            )
        }

        if process.terminationStatus != 0 {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw CLIError(command: args.joined(separator: " "), exitCode: process.terminationStatus, stderr: stderrText)
        }

        return stdoutData
    }

    public struct CallerIdentity: Decodable, Sendable {
        public let arn: String

        enum CodingKeys: String, CodingKey {
            case arn = "Arn"
        }
    }

    /// Fetches the caller identity (account, user id, ARN) for a profile.
    /// Used both to verify a profile authenticates and, via the ARN, to
    /// work out whose boxes are whose for the "mine" badge/filter.
    public static func callerIdentity(profile: String) async throws -> CallerIdentity {
        let data = try await run(["sts", "get-caller-identity", "--profile", profile, "--output", "json"], timeout: 15)
        return try JSONDecoder().decode(CallerIdentity.self, from: data)
    }

    /// Verifies a profile can authenticate. Used at first refresh to decide
    /// whether to fall back from "sako" to "keladev".
    public static func checkIdentity(profile: String) async -> Bool {
        (try? await callerIdentity(profile: profile)) != nil
    }

    /// Whether a named profile exists in the local AWS config/credentials
    /// files at all — distinct from `checkIdentity`, which asks whether a
    /// profile that does exist can actually authenticate. This is a purely
    /// local, offline check (`aws configure list-profiles` just reads
    /// `~/.aws/config` and `~/.aws/credentials`), so it's safe to call
    /// often and works even with no network. Used to show a first-run setup
    /// card instead of a confusing CLI error when a colleague hasn't run
    /// `aws configure` yet.
    public static func localProfileExists(_ name: String) async -> Bool {
        guard let data = try? await run(["configure", "list-profiles"], timeout: 10) else { return false }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains(name)
    }

    /// Fetches instances for a single region.
    public static func describeInstances(profile: String, region: String) async throws -> [Instance] {
        let data = try await run([
            "ec2", "describe-instances",
            "--profile", profile,
            "--region", region,
            "--output", "json"
        ])
        let decoded = try JSONDecoder().decode(EC2DescribeInstancesResponse.self, from: data)
        return decoded.toInstances(region: region)
    }

    /// Fetches instances across every region in parallel.
    public static func describeAllInstances(profile: String, regions: [String]) async -> (instances: [Instance], errors: [String: String]) {
        await withTaskGroup(of: (String, Result<[Instance], Error>).self) { group in
            for region in regions {
                group.addTask {
                    do {
                        let instances = try await describeInstances(profile: profile, region: region)
                        return (region, .success(instances))
                    } catch {
                        return (region, .failure(error))
                    }
                }
            }

            var allInstances: [Instance] = []
            var errors: [String: String] = [:]
            for await (region, result) in group {
                switch result {
                case .success(let instances):
                    allInstances.append(contentsOf: instances)
                case .failure(let error):
                    errors[region] = error.localizedDescription
                }
            }
            return (allInstances, errors)
        }
    }

    public static func stopInstance(id: String, region: String, profile: String) async throws {
        try await run(["ec2", "stop-instances", "--instance-ids", id, "--region", region, "--profile", profile, "--output", "json"])
    }

    public static func startInstance(id: String, region: String, profile: String) async throws {
        try await run(["ec2", "start-instances", "--instance-ids", id, "--region", region, "--profile", profile, "--output", "json"])
    }

    public static func terminateInstance(id: String, region: String, profile: String) async throws {
        try await run(["ec2", "terminate-instances", "--instance-ids", id, "--region", region, "--profile", profile, "--output", "json"])
    }
}
