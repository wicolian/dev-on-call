import AppKit
import DevOnCallCore
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            statusStrip
            Divider().opacity(0.55)
            eventFeed
            Divider().opacity(0.55)
            footer
        }
        .frame(width: 404, height: 526)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.preferences.isArmed && !model.isSnoozed
                          ? WatchPalette.healthy.opacity(0.14)
                          : WatchPalette.inset)
                Image(systemName: model.menuBarSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.preferences.isArmed && !model.isSnoozed
                                     ? WatchPalette.healthy
                                     : .secondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dev On Call")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.monitoringLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Armed", isOn: Binding(
                get: { model.preferences.isArmed },
                set: { model.setArmed($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Arm monitoring")

            Menu {
                if model.isSnoozed {
                    Button("Resume now") { model.wake() }
                } else {
                    Button("Snooze 1 hour") { model.snooze(hours: 1) }
                    Button("Snooze 4 hours") { model.snooze(hours: 4) }
                    Button("Snooze until morning") { model.snoozeUntilMorning() }
                }
            } label: {
                Image(systemName: model.isSnoozed ? "moon.zzz.fill" : "moon.zzz")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Snooze alerts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var statusStrip: some View {
        HStack(spacing: 0) {
            MonitorStatus(
                label: "HERDR",
                value: model.herdrSummary,
                symbol: "rectangle.3.group.bubble.left",
                active: model.preferences.herdrEnabled
            )
            Divider().frame(height: 40).opacity(0.5)
            MonitorStatus(
                label: "PROBES",
                value: model.probeSummary,
                symbol: "waveform.path.ecg",
                active: !model.preferences.probes.filter(\.enabled).isEmpty
            )
        }
        .padding(.vertical, 10)
        .background(WatchPalette.inset.opacity(0.55))
    }

    private var eventFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SIGNAL RAIL")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.events.isEmpty {
                    Text("\(model.events.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if model.events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.events.prefix(30)) { event in
                            EventRow(event: event)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(WatchPalette.healthy)
            Text("Quiet watch")
                .font(.system(size: 13, weight: .semibold))
            Text("Permission waits, account limits, CI failures, and custom probes will land here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 270)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            settingsControl

            Button {
                model.triggerTest()
            } label: {
                Label("Visual test", systemImage: "bolt.badge.checkmark")
            }
            .help("Creates a test signal. Audio stays off unless enabled in Settings.")

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var settingsControl: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct MonitorStatus: View {
    let label: String
    let value: String
    let symbol: String
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? WatchPalette.healthy : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
    }
}

private struct EventRow: View {
    let event: AlertEvent

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(WatchPalette.color(for: event.severity))
                .frame(width: 3)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(event.createdAt, style: .time)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(event.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(event.source.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(WatchPalette.color(for: event.severity).opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .background(WatchPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(WatchPalette.borderSoft, lineWidth: 0.5)
        }
    }
}
