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

if failures > 0 {
    print("\n\(failures) self-test(s) failed")
    exit(1)
}
print("\nAll Dev On Call self-tests passed")
