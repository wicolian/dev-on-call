import Combine
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
