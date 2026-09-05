import Darwin
import DevOnCallAWS
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

// AWS Boxes: preferences saved before this feature existed must not reset
// on load just because the new keys are missing.
let legacyPreferencesJSON = """
{"isArmed":true,"herdrEnabled":true,"herdrPollSeconds":10,"blockedDelaySeconds":90,\
"soundEnabled":false,"customSoundPath":"","speechEnabled":false,\
"systemNotificationsEnabled":false,"quietHoursEnabled":true,"quietStartHour":23,\
"quietEndHour":8,"allowCriticalDuringQuietHours":false,"aiProvider":"off",\
"aiModel":"","aiExecutablePath":"","aiTimeoutSeconds":45,"probes":[]}
""".data(using: .utf8)!
do {
    let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyPreferencesJSON)
    expect(decoded.herdrPollSeconds == 10, "legacy preferences without AWS keys still decode existing fields")
    expect(!decoded.awsBoxesEnabled, "AWS boxes default to off for legacy preferences")
    expect(decoded.awsProfile == "sako", "AWS profile defaults to sako for legacy preferences")
    expect(decoded.awsLongRunningAlertHours == 12, "AWS long-running alert defaults to 12 hours")
} catch {
    failures += 1
    print("FAIL  legacy preferences decode threw \(error)")
}

// AWS Boxes: decoding must keep every instance, including spot instances,
// across every reservation in a region's response.
let sampleDescribeInstancesJSON = """
{
  "Reservations": [
    {
      "Instances": [
        {
          "InstanceId": "i-0aaaaaaaaaaaaaaaa",
          "InstanceType": "m7g.xlarge",
          "State": { "Name": "running" },
          "LaunchTime": "2020-01-01T00:00:00.000Z",
          "InstanceLifecycle": "spot",
          "Tags": [{ "Key": "Name", "Value": "koushik-sandbox" }]
        }
      ]
    },
    {
      "Instances": [
        {
          "InstanceId": "i-0bbbbbbbbbbbbbbbb",
          "InstanceType": "t3.medium",
          "State": { "Name": "stopped" },
          "LaunchTime": "2020-01-01T00:00:00.000Z",
          "Tags": [{ "Key": "Name", "Value": "staging-api" }]
        }
      ]
    }
  ]
}
""".data(using: .utf8)!
do {
    let decoded = try JSONDecoder().decode(EC2DescribeInstancesResponse.self, from: sampleDescribeInstancesJSON)
    let instances = decoded.toInstances(region: "us-east-1")
    expect(instances.count == 2, "both reservations' instances decode — none silently dropped")
    let spot = instances.first { $0.displayName == "koushik-sandbox" }
    expect(spot?.lifecycle == .spot, "a spot instance keeps its spot lifecycle, not filtered or reclassified")
    expect(spot?.isLongRunning() == true, "a box running since 2020 is flagged long-running")
    let sorted = instances.sortedForDisplay()
    expect(sorted.count == 2, "sortedForDisplay never drops an instance")
    expect(sorted.first?.state == .running, "running instances sort first")
} catch {
    failures += 1
    print("FAIL  EC2 instance decode threw \(error)")
}

// AWS Boxes: "mine" awareness — deriving a username from a caller-identity
// ARN, and matching it against an instance's Owner tag.
expect(
    AWSIdentity.userName(fromArn: "arn:aws:iam::111122223333:user/koushik_dbn") == "koushik",
    "a plain IAM user ARN yields the username with the _dbn suffix stripped"
)
expect(
    AWSIdentity.userName(fromArn: "arn:aws:iam::111122223333:user/bots/deploy-bot") == "deploy-bot",
    "a /bots/ path component is stripped, keeping only the final username"
)
expect(
    AWSIdentity.userName(fromArn: "arn:aws:sts::111122223333:assumed-role/SomeRole/session") == nil,
    "a non-IAM-user ARN (assumed-role) yields no username"
)

let ownedInstance = Instance(
    id: "i-owned",
    region: "ap-south-1",
    name: "priya-box",
    owner: "Priya",
    instanceType: "t3.medium",
    state: .running,
    lifecycle: .onDemand,
    publicIP: nil,
    launchTime: nil
)
expect(ownedInstance.isOwned(by: "priya"), "ownership match is case-insensitive")
expect(!ownedInstance.isOwned(by: "koushik"), "a different username is not a match")
expect(!ownedInstance.isOwned(by: nil), "no current user means never mine")

let untaggedInstance = Instance(
    id: "i-no-name",
    region: "ap-south-1",
    name: nil,
    owner: nil,
    instanceType: "t3.medium",
    state: .running,
    lifecycle: .onDemand,
    publicIP: nil,
    launchTime: nil
)
expect(untaggedInstance.displayName == untaggedInstance.id, "an instance with no Name tag falls back to its instance id")
expect(!untaggedInstance.isOwned(by: "koushik"), "an instance with no Owner tag is never mine")

if failures > 0 {
    print("\n\(failures) self-test(s) failed")
    exit(1)
}
print("\nAll Dev On Call self-tests passed")
