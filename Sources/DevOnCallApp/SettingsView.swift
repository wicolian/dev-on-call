import AppKit
import DevOnCallCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AlertsSettings(model: model)
                .tabItem { Label("Alerts", systemImage: "bell.badge") }
            MonitoringSettings(model: model)
                .tabItem { Label("Monitors", systemImage: "waveform.path.ecg") }
            IntelligenceSettings(model: model)
                .tabItem { Label("Voice", systemImage: "waveform.and.person.filled") }
            IntegrationSettings()
                .tabItem { Label("Connect", systemImage: "terminal") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 520)
    }
}

private struct AlertsSettings: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = LaunchAtLoginController.isEnabled

    var body: some View {
        Form {
            Section("Watch state") {
                Toggle("Monitoring armed", isOn: Binding(
                    get: { model.preferences.isArmed },
                    set: { model.setArmed($0) }
                ))
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { model.setLaunchAtLogin($0) }
                if !model.settingsMessage.isEmpty {
                    Text(model.settingsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Delivery") {
                Toggle("Show macOS notifications", isOn: $model.preferences.systemNotificationsEnabled)
                    .onChange(of: model.preferences.systemNotificationsEnabled) { enabled in
                        if enabled { model.requestNotificationPermission() }
                    }
                Toggle("Play a sound", isOn: $model.preferences.soundEnabled)
                Toggle("Speak the message", isOn: $model.preferences.speechEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom sound")
                        Text(model.preferences.customSoundPath.isEmpty
                             ? "System beep (sound is off by default)"
                             : model.preferences.customSoundPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Choose…", action: chooseSound)
                    Button("Preview") { model.previewSound() }
                        .disabled(!model.preferences.soundEnabled)
                }
            }

            Section("Quiet hours") {
                Toggle("Silence sound and speech during quiet hours", isOn: $model.preferences.quietHoursEnabled)
                HStack {
                    Picker("From", selection: $model.preferences.quietStartHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker("Until", selection: $model.preferences.quietEndHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
                Toggle("Let critical alerts break quiet hours", isOn: $model.preferences.allowCriticalDuringQuietHours)
                Text("Defaults are intentionally silent. Dev On Call never changes system volume and never loops audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func chooseSound() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose the sound played once for each distinct incident."
        if panel.runModal() == .OK, let path = panel.url?.path {
            model.preferences.customSoundPath = path
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct MonitoringSettings: View {
    @ObservedObject var model: AppModel
    @State private var showingAddProbe = false

    var body: some View {
        Form {
            Section("Herdr — read only") {
                Toggle("Watch Herdr panes", isOn: $model.preferences.herdrEnabled)
                Stepper(
                    "Poll every \(model.preferences.herdrPollSeconds) seconds",
                    value: $model.preferences.herdrPollSeconds,
                    in: 5...120,
                    step: 5
                )
                Stepper(
                    "Alert after blocked for \(model.preferences.blockedDelaySeconds) seconds",
                    value: $model.preferences.blockedDelaySeconds,
                    in: 30...1800,
                    step: 30
                )
                Text("Reads pane status and recent output to spot permission waits, session limits, rate limits, CI failures, and review failures. It never focuses, types into, or closes a pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.preferences.probes.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No shell probes yet")
                            .fontWeight(.medium)
                        Text("Add any command where exit 0 means healthy and non-zero means alert.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.preferences.probes) { probe in
                        ProbeRow(model: model, probe: probe)
                    }
                }
            } header: {
                HStack {
                    Text("Shell probes")
                    Spacer()
                    Button {
                        showingAddProbe = true
                    } label: {
                        Label("Add probe", systemImage: "plus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .sheet(isPresented: $showingAddProbe) {
            ProbeEditor { probe in model.addProbe(probe) }
        }
    }
}

private struct ProbeRow: View {
    @ObservedObject var model: AppModel
    let probe: ProbeRule

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { probe.enabled },
                set: { enabled in
                    var changed = probe
                    changed.enabled = enabled
                    model.updateProbe(changed)
                }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(probe.name).fontWeight(.medium)
                Text(probe.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Every \(probe.intervalSeconds)s · timeout \(probe.timeoutSeconds)s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(role: .destructive) {
                if let index = model.preferences.probes.firstIndex(where: { $0.id == probe.id }) {
                    model.removeProbes(at: IndexSet(integer: index))
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct ProbeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var interval = 60
    @State private var timeout = 20
    let onSave: (ProbeRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add shell probe")
                .font(.title2.weight(.semibold))
            Text("Dev On Call runs this command periodically. Exit 0 is healthy; any other exit code creates one deduplicated incident.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("GitHub Actions"))
                TextField("Command", text: $command, prompt: Text("cd ~/project && ./scripts/check-ci.sh"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...6)
                Stepper("Run every \(interval) seconds", value: $interval, in: 10...3600, step: 10)
                Stepper("Timeout after \(timeout) seconds", value: $timeout, in: 1...300)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add probe") {
                    onSave(ProbeRule(name: name, command: command, intervalSeconds: interval, timeoutSeconds: timeout))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 530, height: 410)
    }
}

private struct IntelligenceSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Optional AI narration") {
                Picker("Provider", selection: $model.preferences.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Model override", text: $model.preferences.aiModel, prompt: Text(defaultModelHint))
                TextField("Executable override", text: $model.preferences.aiExecutablePath, prompt: Text("Auto-detect local CLI"))
                Stepper(
                    "Give up after \(model.preferences.aiTimeoutSeconds) seconds",
                    value: $model.preferences.aiTimeoutSeconds,
                    in: 10...120,
                    step: 5
                )
            }

            Section("Safety and billing") {
                LabeledContent("Claude detected", value: ExecutableLocator.find("claude") == nil ? "No" : "Yes")
                LabeledContent("Codex detected", value: ExecutableLocator.find("codex") == nil ? "No" : "Yes")
                Text("Uses your existing local CLI login. No API key is read or stored. Claude runs with tools disabled; Codex runs ephemerally in a read-only sandbox. If the model is unavailable or rate-limited, the deterministic alert is spoken instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("AI narration consumes the selected provider's subscription allowance and is off by default.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WatchPalette.warning)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var defaultModelHint: String {
        switch model.preferences.aiProvider {
        case .claude: return "haiku"
        case .codex: return "Use Codex default"
        case .off: return "Provider default"
        }
    }
}

private struct IntegrationSettings: View {
    private let command = "dev-on-call alert --source ci --severity critical --title 'Tests failed' --body 'Open the latest run.'"

    var body: some View {
        Form {
            Section("Any terminal") {
                Text("Send an event from scripts, hooks, CI watchers, or another agent:")
                CodeBox(command)
                CodeBox("npm test || dev-on-call alert --source tests --severity critical --title 'npm test failed'")
            }
            Section("Built for adapters") {
                Label("GitHub Actions and other CI: add a shell probe or emit from a watcher", systemImage: "checkmark.circle")
                Label("Review bots: alert from their failure hook or poll their status command", systemImage: "text.magnifyingglass")
                Label("Herdr: enabled automatically and strictly read-only", systemImage: "rectangle.3.group")
            }
            Section("Data location") {
                Text(AppPaths.root.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct CodeBox: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(WatchPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(WatchPalette.healthy)
            Text("Dev On Call")
                .font(.title2.weight(.semibold))
            Text("A quiet, local-first incident sentry for developers and their agents.")
                .foregroundStyle(.secondary)
            Link("github.com/wicolian/dev-on-call", destination: URL(string: "https://github.com/wicolian/dev-on-call")!)
            Text("MIT licensed · no telemetry · no credentials stored")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
