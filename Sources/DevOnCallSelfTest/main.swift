import Darwin
import DevOnCallCore
import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

let quota = PatternMatcher.detect(in: "Request stopped: usage limit reached; resets at 08:00")
expect(quota?.severity == .critical, "account limits are critical")
expect(quota?.title == "Account or session limit", "account limits have a useful title")

let permission = PatternMatcher.detect(in: "Agent is waiting for approval before running the command")
expect(permission?.severity == .warning, "permission waits are warnings")

let failure = PatternMatcher.detect(in: "CI summary: tests failed in package core")
expect(failure?.title == "Automation failure", "CI failures are recognized")
expect(PatternMatcher.detect(in: "All 84 tests passed. Review completed successfully.") == nil, "healthy output stays quiet")

let oldTranscript = String(repeating: "healthy output\n", count: 40) + "old fatal error\n"
let appendedTranscript = oldTranscript + "all good now\n"
expect(TranscriptDelta.newText(previous: oldTranscript, current: appendedTranscript) == "all good now\n", "only appended transcript text is inspected")
expect(TranscriptDelta.newText(previous: oldTranscript, current: "unrelated replacement with old fatal error") == nil, "replaced buffers become a baseline")

let defaults = AppPreferences()
expect(!defaults.soundEnabled, "sound is opt-in")
expect(!defaults.speechEnabled, "speech is opt-in")
expect(!defaults.systemNotificationsEnabled, "system notifications are opt-in")
expect(defaults.quietHoursEnabled, "quiet hours default on")
expect(!defaults.allowCriticalDuringQuietHours, "critical alerts respect quiet hours by default")

let temporaryHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("dev-on-call-tests-\(UUID().uuidString)", isDirectory: true)
setenv("DEV_ON_CALL_HOME", temporaryHome.path, 1)
defer {
    unsetenv("DEV_ON_CALL_HOME")
    try? FileManager.default.removeItem(at: temporaryHome)
}

let event = AlertEvent(
    severity: .warning,
    source: "tests",
    title: "Permission needed",
    detail: "Pane 1-2 is blocked"
)
do {
    try EventStore.enqueue(event)
    let drained = EventStore.drainInbox()
    expect(drained.count == 1 && drained.first?.id == event.id && drained.first?.title == event.title, "inbox round-trips an event")
    expect(EventStore.drainInbox().isEmpty, "inbox drains exactly once")
} catch {
    failures += 1
    print("FAIL  inbox round-trip threw \(error)")
}

let archived = (0..<240).map {
    AlertEvent(severity: .info, source: "test", title: "Event \($0)", detail: "")
}
EventStore.saveArchive(archived)
expect(EventStore.loadArchive().count == 200, "archive is capped at 200 events")

let repo = temporaryHome.appendingPathComponent("repo", isDirectory: true)
try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
let gitInit = Process()
gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
gitInit.arguments = ["-C", repo.path, "init", "--quiet"]
try gitInit.run()
gitInit.waitUntilExit()
expect(gitInit.terminationStatus == 0, "repository hook test initializes Git")

let localHooks = repo.appendingPathComponent(".git/hooks", isDirectory: true)
let setHooksPath = Process()
setHooksPath.executableURL = URL(fileURLWithPath: "/usr/bin/git")
setHooksPath.arguments = ["-C", repo.path, "config", "--local", "core.hooksPath", localHooks.path]
try setHooksPath.run()
setHooksPath.waitUntilExit()

let existingHook = localHooks.appendingPathComponent("pre-commit")
try "#!/bin/sh\nexit 7\n".write(to: existingHook, atomically: true, encoding: .utf8)
chmod(existingHook.path, 0o755)
do {
    let installed = try RepoHookInstaller.install(at: repo.path, command: "true")
    expect(installed.isEnabled && installed.isWrapperInstalled, "repo installer enables its managed wrapper")
    expect(FileManager.default.fileExists(atPath: localHooks.appendingPathComponent("pre-commit.dev-on-call-original").path), "repo installer preserves the existing hook")

    let stubDirectory = temporaryHome.appendingPathComponent("stub-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
    let capture = temporaryHome.appendingPathComponent("hook-alert.txt")
    let stub = stubDirectory.appendingPathComponent("dev-on-call")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$DEV_ON_CALL_TEST_CAPTURE\"\n".write(to: stub, atomically: true, encoding: .utf8)
    chmod(stub.path, 0o755)
    let hookRun = Process()
    hookRun.executableURL = existingHook
    hookRun.currentDirectoryURL = repo
    hookRun.environment = [
        "HOME": NSHomeDirectory(),
        "PATH": "\(stubDirectory.path):/usr/bin:/bin",
        "DEV_ON_CALL_TEST_CAPTURE": capture.path
    ]
    try hookRun.run()
    hookRun.waitUntilExit()
    expect(hookRun.terminationStatus == 7, "repo wrapper preserves a failing hook status")
    expect((try? String(contentsOf: capture))?.contains("Pre-commit failed") == true, "repo wrapper emits a failure alert")

    let removed = try RepoHookInstaller.uninstall(at: repo.path)
    expect(!removed.isEnabled && !removed.isWrapperInstalled, "repo uninstaller disables its wrapper")
    expect((try? String(contentsOf: existingHook))?.contains("exit 7") == true, "repo uninstaller restores the existing hook")
} catch {
    failures += 1
    print("FAIL  repo hook lifecycle threw \(error)")
}

if failures > 0 {
    print("\n\(failures) self-test(s) failed")
    exit(1)
}
print("\nAll Dev On Call self-tests passed")
