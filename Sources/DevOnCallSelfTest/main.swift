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
    expect(decoded.awsOwnerName.isEmpty, "the owner-name override defaults to empty (use the derived identity)")
    expect(!decoded.awsOwnerNameDidPrefill, "legacy preferences have not been pre-filled yet")
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

// AWS Boxes: WorkSpaces decoding. The first entry is a verbatim capture of
// `aws workspaces describe-workspaces --region ap-south-1` for Koushik's
// music desktop while it was still building (no ComputerName yet), so the
// PENDING/no-name case is covered by real data rather than a guess. The
// other two are hand-written in the same shape to cover an ALWAYS_ON
// desktop and a broken one.
let sampleDescribeWorkspacesJSON = """
{
  "Workspaces": [
    {
      "WorkspaceId": "ws-f8g0stl4z",
      "DirectoryId": "d-9f6759e579",
      "UserName": "koushik",
      "State": "PENDING",
      "BundleId": "wsb-xyv83v8b5",
      "WorkspaceProperties": {
        "RunningMode": "AUTO_STOP",
        "RunningModeAutoStopTimeoutInMinutes": 60,
        "RootVolumeSizeGib": 175,
        "ComputeTypeName": "GRAPHICS_G4DN",
        "Protocols": ["WSP"],
        "OperatingSystemName": "WINDOWS_SERVER_2022",
        "GlobalAccelerator": { "Mode": "INHERITED", "PreferredProtocol": "INHERITED" },
        "NestedVirtualizationEnabled": false
      },
      "ModificationStates": []
    },
    {
      "WorkspaceId": "ws-alwayson01",
      "UserName": "priya",
      "ComputerName": "PRIYA-DESK",
      "State": "AVAILABLE",
      "BundleId": "wsb-standard1",
      "WorkspaceProperties": {
        "RunningMode": "ALWAYS_ON",
        "ComputeTypeName": "STANDARD",
        "OperatingSystemName": "WINDOWS_SERVER_2022"
      }
    },
    {
      "WorkspaceId": "ws-broken0001",
      "UserName": "koushik",
      "ComputerName": "OLD-BOX",
      "State": "UNHEALTHY",
      "ErrorMessage": "The WorkSpace failed a health check.",
      "WorkspaceProperties": {
        "RunningMode": "AUTO_STOP",
        "RunningModeAutoStopTimeoutInMinutes": 60,
        "ComputeTypeName": "GRAPHICS_G6F_2XLARGE"
      }
    }
  ]
}
""".data(using: .utf8)!

let sampleConnectionStatusJSON = """
{
  "WorkspacesConnectionStatus": [
    {
      "WorkspaceId": "ws-alwayson01",
      "ConnectionState": "DISCONNECTED",
      "ConnectionStateCheckTimestamp": "2020-06-01T00:00:00.000000+05:30",
      "LastKnownUserConnectionTimestamp": "2020-01-01T00:00:00.000000+05:30"
    }
  ]
}
""".data(using: .utf8)!

do {
    let connections = try JSONDecoder()
        .decode(WorkspacesConnectionStatusResponse.self, from: sampleConnectionStatusJSON)
        .byWorkspaceID()
    expect(connections.count == 1, "connection status decodes and indexes by WorkSpace id")

    let decoded = try JSONDecoder().decode(WorkspacesDescribeResponse.self, from: sampleDescribeWorkspacesJSON)
    let workspaces = decoded.toWorkspaces(region: "ap-south-1", connections: connections)
    expect(workspaces.count == 3, "every WorkSpace decodes — none silently dropped")

    let music = workspaces.first { $0.id == "ws-f8g0stl4z" }
    expect(music?.userName == "koushik", "the assigned user name decodes")
    expect(music?.displayName == "ws-f8g0stl4z", "a WorkSpace with no ComputerName yet falls back to its id")
    expect(music?.state == .pending, "PENDING decodes as a known state, not unknown")
    expect(music?.state.health == .transitioning, "PENDING reads as mid-transition, not broken")
    expect(music?.computeLabel == "g4dn, GPU", "a GRAPHICS_ compute type shows its GPU family")
    expect(music?.isGPU == true, "a GRAPHICS_ compute type is flagged as a GPU desktop")
    expect(music?.runningMode.tag == "AUTO-STOP 60M", "auto-stop carries its timeout budget in the tag")
    expect(music?.presenceString() == "-", "a WorkSpace with no connection record claims nothing about presence")
    expect(music?.canStart == false && music?.canStop == false && music?.canReboot == false,
           "a PENDING WorkSpace offers no actions")

    let alwaysOn = workspaces.first { $0.id == "ws-alwayson01" }
    expect(alwaysOn?.displayName == "PRIYA-DESK", "ComputerName wins over the id when present")
    expect(alwaysOn?.state.health == .available, "AVAILABLE reads as available")
    expect(alwaysOn?.computeLabel == "Standard", "a non-GPU compute type reads as a plain name")
    expect(alwaysOn?.runningMode.tag == "ALWAYS-ON", "always-on has no timeout to show")
    expect(alwaysOn?.presenceString().hasPrefix("Idle ") == true, "a disconnected WorkSpace reports idle time")
    expect(alwaysOn?.isWastefullyIdle(thresholdHours: 12) == true,
           "an always-on desktop nobody has connected to since 2020 is flagged")
    expect(alwaysOn?.canStop == true && alwaysOn?.canReboot == true && alwaysOn?.canStart == false,
           "an available WorkSpace offers Stop and Reboot but not Start")

    let broken = workspaces.first { $0.id == "ws-broken0001" }
    expect(broken?.state.health == .faulted, "UNHEALTHY reads as broken")
    expect(broken?.computeLabel == "g6f.2xlarge, GPU", "a multi-segment GPU family keeps its size")
    expect(broken?.errorMessage?.isEmpty == false, "a WorkSpace error message is kept for the tooltip")
    expect(broken?.isWastefullyIdle(thresholdHours: 1) == false,
           "an auto-stop WorkSpace is never flagged as wasteful, however long it sits")

    expect(music?.isOwned(by: "koushik") == true, "a WorkSpace assigned to you matches the derived identity")
    expect(alwaysOn?.isOwned(by: "koushik") == false, "somebody else's WorkSpace is not yours")
    expect(music?.isOwned(by: nil) == false, "with no known identity nothing is claimed as yours")

    let sorted = workspaces.sortedForDisplay()
    expect(sorted.count == 3, "sortedForDisplay never drops a WorkSpace")
    expect(sorted.first?.id == "ws-alwayson01", "available WorkSpaces sort first")
    expect(sorted[1].id == "ws-broken0001", "a broken WorkSpace sorts above a transitional one, not below")
} catch {
    failures += 1
    print("FAIL  WorkSpaces decode threw \(error)")
}

// AWS Boxes: a region with no WorkSpaces at all returns an empty list, and
// some regions in the EC2 list (ap-south-2, eu-north-1) have no WorkSpaces
// endpoint whatsoever — neither may look like a decode failure.
do {
    let empty = try JSONDecoder().decode(
        WorkspacesDescribeResponse.self,
        from: #"{"Workspaces": []}"#.data(using: .utf8)!
    )
    expect(empty.toWorkspaces(region: "us-east-1").isEmpty, "a region with no WorkSpaces decodes to an empty list")

    let missingKey = try JSONDecoder().decode(
        WorkspacesDescribeResponse.self,
        from: #"{"NextToken": "abc"}"#.data(using: .utf8)!
    )
    expect(missingKey.workspaces.isEmpty, "a response with no Workspaces key at all still decodes")
} catch {
    failures += 1
    print("FAIL  empty WorkSpaces response decode threw \(error)")
}

expect(
    Workspace.formatComputeType("GRAPHICSPRO_G4DN") == "g4dn, GPU",
    "a GRAPHICSPRO bundle reports the same GPU family"
)
expect(
    Workspace.formatComputeType("GENERALPURPOSE_4XLARGE") == "Generalpurpose.4xlarge",
    "a multi-segment non-GPU compute type keeps every segment"
)
expect(
    Workspace.formatComputeType(nil) == "unknown",
    "a missing compute type degrades to a word, not a crash or an empty slot"
)
expect(
    WorkspaceState(raw: "SOME_FUTURE_STATE").label == "Some Future State",
    "an unrecognised future state stays readable instead of decoding as an error"
)

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

// AWS Boxes: the owner-name override. This account's "sako" profile
// authenticates as the per-machine bot user "bots/kela-mac", so the name
// derived from the caller identity matches nothing Koushik actually owns
// and no row would ever badge. The Settings override is what closes that
// gap, and it has to work identically for a box and for a desktop.
let derivedBotIdentity = AWSIdentity.userName(fromArn: "arn:aws:iam::111122223333:user/bots/kela-mac")
expect(derivedBotIdentity == "kela-mac", "a per-machine bot user derives its own name, not the person's")

let koushikBox = Instance(
    id: "i-koushik",
    region: "ap-south-1",
    name: "koushik-music",
    owner: "koushik",
    instanceType: "m6i.xlarge",
    state: .running,
    lifecycle: .onDemand,
    publicIP: nil,
    launchTime: nil
)
let koushikDesktop = Workspace(
    id: "ws-koushik",
    region: "ap-south-1",
    userName: "koushik",
    computerName: "WSAMZN-I3L3J52A",
    bundleId: nil,
    computeTypeName: "GRAPHICS_G4DN",
    operatingSystemName: nil,
    state: .available,
    runningMode: WorkspaceRunningMode(raw: "AUTO_STOP", timeoutMinutes: 60),
    errorMessage: nil,
    connection: nil
)
expect(!koushikBox.isOwned(by: derivedBotIdentity), "the derived bot name badges nothing — the gap the override exists to close")
expect(!koushikDesktop.isOwned(by: derivedBotIdentity), "the same gap applies to a desktop")
expect(koushikBox.isOwned(by: "koushik"), "the override name badges the box")
expect(koushikDesktop.isOwned(by: "koushik"), "the override name badges the desktop identically")
expect(koushikDesktop.isOwned(by: "KOUSHIK"), "the override is matched case-insensitively, like the derived name")

// A saved override has to survive a preferences round-trip, and clearing it
// must stay cleared rather than being re-filled by the one-time local
// pre-fill on the next launch.
do {
    var prefs = AppPreferences()
    prefs.awsOwnerName = "koushik"
    prefs.awsOwnerNameDidPrefill = true
    let roundTripped = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
    expect(roundTripped.awsOwnerName == "koushik", "the owner-name override survives a save/load round-trip")
    expect(roundTripped.awsOwnerNameDidPrefill, "the pre-fill marker survives, so clearing the field stays cleared")

    var cleared = roundTripped
    cleared.awsOwnerName = ""
    let clearedAgain = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(cleared))
    expect(clearedAgain.awsOwnerName.isEmpty && clearedAgain.awsOwnerNameDidPrefill,
           "an emptied override stays empty while the pre-fill marker stays set")
} catch {
    failures += 1
    print("FAIL  owner-name override round-trip threw \(error)")
}

if failures > 0 {
    print("\n\(failures) self-test(s) failed")
    exit(1)
}
print("\nAll Dev On Call self-tests passed")
