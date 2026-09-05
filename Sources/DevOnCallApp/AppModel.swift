import Combine
import DevOnCallAWS
import DevOnCallCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences: AppPreferences {
        didSet { savePreferences() }
    }
    @Published private(set) var events: [AlertEvent]
    @Published private(set) var herdrSummary = "Waiting for first scan"
    @Published private(set) var probeSummary = "No probes configured"
    @Published private(set) var lastScanAt: Date?
    @Published var settingsMessage = ""

    // AWS Boxes — mirrors the standalone AWS Boxes app's runtime state.
    @Published private(set) var awsInstances: [Instance] = []
    @Published private(set) var awsRegionErrors: [String: String] = [:]
    @Published private(set) var awsClientError: String?
    @Published private(set) var awsActionError: String?
    @Published private(set) var awsIsRefreshing = false
    @Published private(set) var awsLastRefreshed: Date?
    @Published private(set) var awsActingInstanceIDs: Set<String> = []

    /// WorkSpaces — Koushik's desktop lives here rather than on EC2. Kept in
    /// its own list (not merged into `awsInstances`) because a desktop and a
    /// server answer different questions: presence vs uptime, running mode
    /// vs spot/on-demand, and no destructive action is ever offered.
    @Published private(set) var awsWorkspaces: [Workspace] = []
    @Published private(set) var awsWorkspaceRegionErrors: [String: String] = [:]
    @Published private(set) var awsActingWorkspaceIDs: Set<String> = []

    /// True when the configured profile (default "sako") has no section at
    /// all in the local AWS config/credentials files — the "a colleague
    /// hasn't run `aws configure` yet" case, shown as a setup card instead
    /// of a CLI error.
    @Published private(set) var awsProfileMissing = false
    /// Username derived from `aws sts get-caller-identity`'s ARN for the
    /// working profile, used for the "you" badge and "Only mine" filter.
    @Published private(set) var awsCurrentUserName: String?
    /// "Only mine" toggle in the AWS Boxes section header. Not persisted —
    /// always starts off, per design.
    @Published var awsOnlyMine = false
    /// The region list to use when the user hasn't customized one yet.
    /// Starts at the safe single-region colleague default and widens once
    /// a local "keladev" profile is detected (Koushik's own machine).
    @Published private(set) var awsDefaultRegions = AWSBoxesDefaults.colleagueRegions

    private let output = AlertOutputService()
    private var monitorTask: Task<Void, Never>?
    private var nextHerdrScan = Date.distantPast
    private var nextProbeRuns: [UUID: Date] = [:]
    private var blockedSince: [String: Date] = [:]
    private var blockedAlerts: Set<String> = []
    private var paneStatuses: [String: String] = [:]
    private var paneTranscripts: [String: String] = [:]
    private var deduplication: [String: Date] = [:]
    private var probeLastSuccess: [UUID: Bool] = [:]
    private var hasBaselinedHerdr = false

    private var nextAWSScan = Date.distantPast
    private var awsDidResolveProfile = false
    private var awsLongRunningAlerted: Set<String> = []
    private var awsIdleWorkspaceAlerted: Set<String> = []
    private var awsIdentityProfile: String?
    private var didDetectAWSDefaultRegions = false

    private static let preferencesKey = "DevOnCall.preferences.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.preferencesKey),
           let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = saved
        } else {
            preferences = AppPreferences()
        }
        events = EventStore.loadArchive()
        startMonitoring()
        Task { [weak self] in await self?.detectAWSDefaultRegionsIfNeeded() }
    }

    deinit { monitorTask?.cancel() }

    var isSnoozed: Bool {
        guard let until = preferences.snoozedUntil else { return false }
        return until > Date()
    }

    var menuBarSymbol: String {
        if !preferences.isArmed { return "bell.slash.fill" }
        if isSnoozed { return "moon.zzz.fill" }
        if events.first?.severity == .critical,
           Date().timeIntervalSince(events.first?.createdAt ?? .distantPast) < 900 {
            return "exclamationmark.triangle.fill"
        }
        return "dot.radiowaves.left.and.right"
    }

    var monitoringLabel: String {
        if !preferences.isArmed { return "Disarmed" }
        if let until = preferences.snoozedUntil, until > Date() {
            return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "On watch"
    }

    // MARK: - AWS Boxes

    var awsRunningCount: Int {
        awsInstances.filter { $0.state == .running }.count
    }

    var awsEffectiveRegions: [String] {
        preferences.awsRegions.isEmpty ? awsDefaultRegions : preferences.awsRegions
    }

    /// Instances grouped by region, each group sorted (running first, then
    /// launch time), regions sorted alphabetically. Respects "Only mine"
    /// when it's on; otherwise every decoded instance from every region is
    /// included.
    var awsGroupedInstances: [(region: String, instances: [Instance])] {
        let base = awsOnlyMine ? awsInstances.filter { isMine($0) } : awsInstances
        let groups = Dictionary(grouping: base, by: \.region)
        return groups.keys.sorted().map { region in
            (region: region, instances: (groups[region] ?? []).sortedForDisplay())
        }
    }

    /// WorkSpaces grouped by region, same shape and same "Only mine" rule as
    /// `awsGroupedInstances`. Regions with no WorkSpaces never appear.
    var awsGroupedWorkspaces: [(region: String, workspaces: [Workspace])] {
        let base = awsOnlyMine ? awsWorkspaces.filter { isMine($0) } : awsWorkspaces
        let groups = Dictionary(grouping: base, by: \.region)
        return groups.keys.sorted().map { region in
            (region: region, workspaces: (groups[region] ?? []).sortedForDisplay())
        }
    }

    /// Available WorkSpaces are billing right now exactly like a running
    /// box, so the section header counts them together.
    var awsAvailableWorkspaceCount: Int {
        awsWorkspaces.filter { $0.state.health == .available }.count
    }

    var awsRunningResourceCount: Int {
        awsRunningCount + awsAvailableWorkspaceCount
    }

    var awsHasAnyResources: Bool {
        !awsInstances.isEmpty || !awsWorkspaces.isEmpty
    }

    var awsHasVisibleResources: Bool {
        !awsGroupedInstances.isEmpty || !awsGroupedWorkspaces.isEmpty
    }

    /// Whose boxes count as yours. The manual override in Settings wins
    /// when it's set, because the derived identity is only a good guess:
    /// on a shared account handing out per-machine bot users, the IAM
    /// username (`bots/kela-mac`) has nothing to do with the `Owner` tags
    /// or WorkSpace users that person actually owns.
    var awsEffectiveUserName: String? {
        let override = preferences.awsOwnerName.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return awsCurrentUserName
    }

    func isMine(_ instance: Instance) -> Bool {
        instance.isOwned(by: awsEffectiveUserName)
    }

    func isMine(_ workspace: Workspace) -> Bool {
        workspace.isOwned(by: awsEffectiveUserName)
    }

    var awsErrorSummary: String? {
        if let awsClientError { return awsClientError }
        if let awsActionError { return awsActionError }
        // WorkSpaces isn't enabled in every region of the list, so a region
        // that has EC2 boxes but no WorkSpaces directory would otherwise
        // spam the banner. Only report a WorkSpaces region error when that
        // region isn't already failing for EC2.
        let merged = awsRegionErrors.merging(awsWorkspaceRegionErrors) { ec2, _ in ec2 }
        if !merged.isEmpty {
            return merged
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: " · ")
        }
        return nil
    }

    var menuBarAccessibilityLabel: String {
        var label = "Dev On Call — \(monitoringLabel)"
        if preferences.awsBoxesEnabled {
            let count = awsRunningResourceCount
            label += ", \(count) AWS box\(count == 1 ? "" : "es") running"
        }
        return label
    }

    func refreshAWSBoxesNow() {
        nextAWSScan = .distantPast
        Task { [weak self] in await self?.scanAWSBoxes() }
    }

    func awsStop(_ instance: Instance) {
        performAWSAction(instance) {
            try await AWSClient.stopInstance(id: instance.id, region: instance.region, profile: self.preferences.awsProfile)
        }
    }

    func awsStart(_ instance: Instance) {
        performAWSAction(instance) {
            try await AWSClient.startInstance(id: instance.id, region: instance.region, profile: self.preferences.awsProfile)
        }
    }

    func awsTerminate(_ instance: Instance) {
        performAWSAction(instance) {
            try await AWSClient.terminateInstance(id: instance.id, region: instance.region, profile: self.preferences.awsProfile)
        }
    }

    // WorkSpaces actions. Start/Stop/Reboot only — Rebuild and Terminate
    // wipe or destroy somebody's desktop and have no place behind a
    // one-click menu-bar menu.

    func awsStartWorkspace(_ workspace: Workspace) {
        performAWSWorkspaceAction(workspace) {
            try await AWSClient.startWorkspace(id: workspace.id, region: workspace.region, profile: self.preferences.awsProfile)
        }
    }

    func awsStopWorkspace(_ workspace: Workspace) {
        performAWSWorkspaceAction(workspace) {
            try await AWSClient.stopWorkspace(id: workspace.id, region: workspace.region, profile: self.preferences.awsProfile)
        }
    }

    func awsRebootWorkspace(_ workspace: Workspace) {
        performAWSWorkspaceAction(workspace) {
            try await AWSClient.rebootWorkspace(id: workspace.id, region: workspace.region, profile: self.preferences.awsProfile)
        }
    }

    private func performAWSWorkspaceAction(_ workspace: Workspace, _ action: @escaping () async throws -> Void) {
        guard !awsActingWorkspaceIDs.contains(workspace.id) else { return }
        awsActingWorkspaceIDs.insert(workspace.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
                self.awsActionError = nil
            } catch {
                self.awsActionError = error.localizedDescription
            }
            await self.scanAWSBoxes()
            self.awsActingWorkspaceIDs.remove(workspace.id)
        }
    }

    private func performAWSAction(_ instance: Instance, _ action: @escaping () async throws -> Void) {
        guard !awsActingInstanceIDs.contains(instance.id) else { return }
        awsActingInstanceIDs.insert(instance.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await action()
                self.awsActionError = nil
            } catch {
                self.awsActionError = error.localizedDescription
            }
            await self.scanAWSBoxes()
            self.awsActingInstanceIDs.remove(instance.id)
        }
    }

    private func scanAWSBoxes() async {
        guard preferences.awsBoxesEnabled else { return }

        guard AWSClient.resolveBinaryPath() != nil else {
            awsClientError = "aws CLI not found at /opt/homebrew/bin/aws or /usr/local/bin/aws"
            awsProfileMissing = false
            return
        }

        // A colleague who hasn't run `aws configure` yet gets a setup card
        // instead of a cryptic CLI error — and we skip the network calls
        // entirely, since we already know they'll fail.
        let profileExists = await AWSClient.localProfileExists(preferences.awsProfile)
        awsProfileMissing = !profileExists
        guard profileExists else {
            awsClientError = nil
            awsInstances = []
            awsRegionErrors = [:]
            awsWorkspaces = []
            awsWorkspaceRegionErrors = [:]
            return
        }
        awsClientError = nil

        if !awsDidResolveProfile {
            awsDidResolveProfile = true
            if preferences.awsProfile == "sako" {
                let sakoWorks = await AWSClient.checkIdentity(profile: "sako")
                if !sakoWorks, await AWSClient.checkIdentity(profile: "keladev") {
                    preferences.awsProfile = "keladev"
                }
            }
        }

        await resolveAWSIdentityIfNeeded()

        awsIsRefreshing = true
        let profile = preferences.awsProfile
        let regions = awsEffectiveRegions
        // EC2 and WorkSpaces fan out concurrently — one shouldn't wait on
        // the other, and a slow region in either doesn't stall the refresh.
        async let instancesResult = AWSClient.describeAllInstances(profile: profile, regions: regions)
        async let workspacesResult = AWSClient.describeAllWorkspaces(profile: profile, regions: regions)
        let (fetched, errors) = await instancesResult
        let (fetchedWorkspaces, workspaceErrors) = await workspacesResult

        awsInstances = fetched
        awsRegionErrors = errors
        awsWorkspaces = fetchedWorkspaces
        awsWorkspaceRegionErrors = workspaceErrors
        awsLastRefreshed = Date()
        awsIsRefreshing = false

        checkAWSLongRunningAlerts()
        checkAWSIdleWorkspaceAlerts()
    }

    /// Resolves "who am I" for the "mine" badge/filter, once per profile.
    /// Re-resolves if the profile changes (e.g. the sako→keladev fallback
    /// above, or the user edits it in Settings) or if it previously failed.
    private func resolveAWSIdentityIfNeeded() async {
        let profile = preferences.awsProfile
        guard awsIdentityProfile != profile else { return }
        if let identity = try? await AWSClient.callerIdentity(profile: profile) {
            awsIdentityProfile = profile
            awsCurrentUserName = AWSIdentity.userName(fromArn: identity.arn)
        } else {
            awsIdentityProfile = nil
            awsCurrentUserName = nil
        }
    }

    /// Runs once at launch: widens the default region list from the safe
    /// single-region colleague default to the full list only when this
    /// machine also has a local "keladev" profile configured — a cheap,
    /// offline stand-in for "this looks like Koushik's own machine."
    /// Doesn't touch `preferences.awsRegions` at all, so it only ever
    /// affects the *default* — a customized region list always wins.
    private func detectAWSDefaultRegionsIfNeeded() async {
        guard !didDetectAWSDefaultRegions else { return }
        guard AWSClient.resolveBinaryPath() != nil else { return }
        didDetectAWSDefaultRegions = true
        guard await AWSClient.localProfileExists("keladev") else { return }
        awsDefaultRegions = AWSBoxesDefaults.regions

        // Same "this looks like Koushik's own machine" signal, reused once
        // to pre-fill the owner name. This account's `sako` profile
        // authenticates as a per-machine bot user (`bots/kela-mac`), so the
        // derived identity never matches the `Owner` tags or WorkSpace
        // users it actually owns and nothing would ever badge. Runs at most
        // once, and never over a value that's already there — clearing the
        // field in Settings has to stay cleared.
        if !preferences.awsOwnerNameDidPrefill, preferences.awsOwnerName.isEmpty {
            preferences.awsOwnerName = "koushik"
            preferences.awsOwnerNameDidPrefill = true
        }
    }

    private func checkAWSLongRunningAlerts() {
        guard preferences.awsBoxesEnabled, preferences.awsLongRunningAlertEnabled else { return }
        let thresholdHours = Double(max(1, preferences.awsLongRunningAlertHours))

        // Stop tracking instances that are no longer running long — if the
        // box is later stopped and started again, or a new box reuses an id
        // (it won't, but just in case), it can alert again.
        let stillOverThreshold = Set(
            awsInstances
                .filter { $0.isLongRunning(thresholdHours: thresholdHours) }
                .map(\.id)
        )
        awsLongRunningAlerted.formIntersection(stillOverThreshold)

        for instance in awsInstances where instance.isLongRunning(thresholdHours: thresholdHours) {
            guard !awsLongRunningAlerted.contains(instance.id) else { continue }
            awsLongRunningAlerted.insert(instance.id)
            let hours = Int((instance.uptime() ?? 0) / 3600)
            ingest(AlertEvent(
                severity: .warning,
                source: "AWS Boxes · \(instance.region)",
                title: "EC2 box running long",
                detail: "\(instance.displayName) running \(hours)h"
            ))
        }
    }

    /// The long-running waste alert, for WorkSpaces.
    ///
    /// An AUTO_STOP WorkSpace parks itself and stops billing, so it is never
    /// alerted however long it sits — that mode is the fix, not the problem.
    /// An ALWAYS_ON WorkSpace bills at the full rate whether or not anyone
    /// connects, and it has no launch time to measure against (it is up by
    /// definition), so the measurable waste is idle time: nobody has
    /// connected for longer than the same threshold the EC2 alert uses. A
    /// WorkSpace AWS has no connection record for is never alerted, since
    /// there is nothing to measure.
    private func checkAWSIdleWorkspaceAlerts() {
        guard preferences.awsBoxesEnabled, preferences.awsLongRunningAlertEnabled else { return }
        let thresholdHours = Double(max(1, preferences.awsLongRunningAlertHours))

        let stillIdle = Set(
            awsWorkspaces
                .filter { $0.isWastefullyIdle(thresholdHours: thresholdHours) }
                .map(\.id)
        )
        awsIdleWorkspaceAlerted.formIntersection(stillIdle)

        for workspace in awsWorkspaces where workspace.isWastefullyIdle(thresholdHours: thresholdHours) {
            guard !awsIdleWorkspaceAlerted.contains(workspace.id) else { continue }
            awsIdleWorkspaceAlerted.insert(workspace.id)
            let hours = Int((workspace.idleTime() ?? 0) / 3600)
            ingest(AlertEvent(
                severity: .warning,
                source: "AWS Boxes · \(workspace.region)",
                title: "WorkSpace always-on and idle",
                detail: "\(workspace.displayName) unused for \(hours)h"
            ))
        }
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func setArmed(_ armed: Bool) {
        preferences.isArmed = armed
        if !armed { output.stop() }
    }

    func snooze(hours: Double) {
        preferences.snoozedUntil = Date().addingTimeInterval(hours * 3600)
        output.stop()
    }

    func snoozeUntilMorning() {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = preferences.quietEndHour
        components.minute = 0
        var target = calendar.date(from: components) ?? now.addingTimeInterval(8 * 3600)
        if target <= now { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target.addingTimeInterval(86400) }
        preferences.snoozedUntil = target
        output.stop()
    }

    func wake() {
        preferences.snoozedUntil = nil
    }

    func triggerTest() {
        let event = AlertEvent(
            severity: .warning,
            source: "Test bench",
            title: "Dev On Call is listening",
            detail: "Sound, speech, notifications, and the signal rail are ready."
        )
        ingest(event, forceAudible: true)
    }

    func previewSound() {
        output.playSound(customPath: preferences.customSoundPath)
    }

    func requestNotificationPermission() {
        output.requestNotificationPermission()
    }

    func clearEvents() {
        events = []
        EventStore.saveArchive(events)
    }

    func addProbe(_ probe: ProbeRule) {
        preferences.probes.append(probe)
        nextProbeRuns[probe.id] = .distantPast
    }

    func removeProbes(at offsets: IndexSet) {
        for index in offsets { nextProbeRuns.removeValue(forKey: preferences.probes[index].id) }
        for index in offsets.sorted(by: >) { preferences.probes.remove(at: index) }
    }

    func updateProbe(_ probe: ProbeRule) {
        guard let index = preferences.probes.firstIndex(where: { $0.id == probe.id }) else { return }
        preferences.probes[index] = probe
        nextProbeRuns[probe.id] = .distantPast
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            settingsMessage = enabled ? "Launch at login enabled." : "Launch at login disabled."
        } catch {
            settingsMessage = "Could not update login item: \(error.localizedDescription)"
        }
    }

    private func tick() async {
        if let until = preferences.snoozedUntil, until <= Date() {
            preferences.snoozedUntil = nil
        }

        for event in EventStore.drainInbox() { ingest(event) }

        if preferences.herdrEnabled, Date() >= nextHerdrScan {
            nextHerdrScan = Date().addingTimeInterval(TimeInterval(max(5, preferences.herdrPollSeconds)))
            await scanHerdr()
        } else if !preferences.herdrEnabled {
            herdrSummary = "Herdr monitor off"
        }

        await runDueProbes()

        if preferences.awsBoxesEnabled, Date() >= nextAWSScan {
            nextAWSScan = Date().addingTimeInterval(60)
            await scanAWSBoxes()
        }

        lastScanAt = Date()
    }

    private func scanHerdr() async {
        switch await HerdrClient.listPanes() {
        case .failure(let error):
            herdrSummary = error.localizedDescription
        case .success(let panes):
            let active = panes.filter { ["working", "blocked"].contains($0.status) }.count
            let blocked = panes.filter { $0.status == "blocked" }.count
            herdrSummary = "\(active) active · \(blocked) blocked"

            let now = Date()
            let currentIDs = Set(panes.map(\.id))
            blockedSince = blockedSince.filter { currentIDs.contains($0.key) }
            blockedAlerts = blockedAlerts.filter { currentIDs.contains($0) }

            for pane in panes {
                let priorStatus = paneStatuses[pane.id]
                paneStatuses[pane.id] = pane.status

                if pane.status == "blocked" {
                    let since = blockedSince[pane.id] ?? now
                    blockedSince[pane.id] = since
                    if now.timeIntervalSince(since) >= TimeInterval(preferences.blockedDelaySeconds),
                       !blockedAlerts.contains(pane.id) {
                        blockedAlerts.insert(pane.id)
                        ingest(AlertEvent(
                            severity: .warning,
                            source: "Herdr · \(pane.label)",
                            title: "Agent has been blocked",
                            detail: "Pane \(pane.id) has needed attention for \(preferences.blockedDelaySeconds) seconds."
                        ))
                    }
                } else {
                    blockedSince.removeValue(forKey: pane.id)
                    blockedAlerts.remove(pane.id)
                }

                let shouldRead = pane.status == "blocked"
                    || pane.status == "done"
                    || pane.status == "unknown"
                    || priorStatus != pane.status
                guard shouldRead, let transcript = await HerdrClient.readRecent(paneID: pane.id) else { continue }
                let current = String(transcript.suffix(8_000))
                let previous = paneTranscripts[pane.id]
                paneTranscripts[pane.id] = current
                guard hasBaselinedHerdr,
                      let previous,
                      let delta = TranscriptDelta.newText(previous: previous, current: current),
                      let detection = PatternMatcher.detect(in: delta)
                else { continue }
                ingest(AlertEvent(
                    severity: detection.severity,
                    source: "Herdr · \(pane.label)",
                    title: detection.title,
                    detail: detection.detail
                ))
            }
            hasBaselinedHerdr = true
        }
    }

    private func runDueProbes() async {
        let enabled = preferences.probes.filter(\.enabled)
        probeSummary = enabled.isEmpty ? "No probes configured" : "\(enabled.count) shell probe\(enabled.count == 1 ? "" : "s") armed"

        for probe in enabled where Date() >= (nextProbeRuns[probe.id] ?? .distantPast) {
            nextProbeRuns[probe.id] = Date().addingTimeInterval(TimeInterval(max(10, probe.intervalSeconds)))
            let result = await CommandRunner.shell(
                probe.command,
                timeout: TimeInterval(max(1, probe.timeoutSeconds))
            )
            let succeeded = result.exitCode == 0 && !result.timedOut
            let previous = probeLastSuccess[probe.id]
            probeLastSuccess[probe.id] = succeeded

            if !succeeded, previous != false {
                let reason = result.timedOut
                    ? "Timed out after \(probe.timeoutSeconds) seconds."
                    : String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500))
                ingest(AlertEvent(
                    severity: .critical,
                    source: "Probe · \(probe.name)",
                    title: "Monitor command failed",
                    detail: reason.isEmpty ? "Exited with status \(result.exitCode)." : reason
                ))
            } else if succeeded, previous == false {
                ingest(AlertEvent(
                    severity: .info,
                    source: "Probe · \(probe.name)",
                    title: "Monitor recovered",
                    detail: "The command is passing again."
                ))
            }
        }
    }

    private func ingest(_ event: AlertEvent, forceAudible: Bool = false) {
        let now = Date()
        deduplication = deduplication.filter { now.timeIntervalSince($0.value) < 900 }
        if !forceAudible, let last = deduplication[event.fingerprint], now.timeIntervalSince(last) < 900 { return }
        deduplication[event.fingerprint] = now

        events.insert(event, at: 0)
        events = Array(events.prefix(200))
        EventStore.saveArchive(events)
        EventStore.appendLog("[\(event.severity.rawValue)] \(event.source): \(event.title) — \(event.detail)")

        guard preferences.isArmed else { return }
        if !forceAudible, let until = preferences.snoozedUntil, until > now { return }
        if preferences.systemNotificationsEnabled { output.postNotification(for: event) }

        let audible = forceAudible || !isQuietHours(for: event.severity)
        guard audible else { return }
        if preferences.soundEnabled { output.playSound(customPath: preferences.customSoundPath) }
        guard preferences.speechEnabled else { return }

        let snapshot = preferences
        Task { [weak self] in
            let generated = await NarrationService.generate(for: event, preferences: snapshot)
            guard let self else { return }
            self.output.speak(generated ?? event.fallbackSpokenMessage)
        }
    }

    private func isQuietHours(for severity: AlertSeverity) -> Bool {
        guard preferences.quietHoursEnabled else { return false }
        if severity == .critical, preferences.allowCriticalDuringQuietHours { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        let start = preferences.quietStartHour
        let end = preferences.quietEndHour
        if start == end { return true }
        if start < end { return hour >= start && hour < end }
        return hour >= start || hour < end
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.preferencesKey)
    }
}
