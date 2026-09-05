// AWSBoxesSection.swift
// DevOnCallApp
//
// The AWS Boxes section of the menu-bar popover. Reworked from the
// standalone AWS Boxes app's ContentView/InstanceRow (see AWSClient.swift
// and Models.swift for the ported data layer) to match Dev On Call's own
// "signal rail" visual language rather than looking like a second app
// bolted onto the first:
//   - the same accent-rail-on-inset-card shape already used by EventRow
//     carries instance state here too, so alerts and boxes read as one
//     family instead of two apps stitched together;
//   - exactly one accent color is a true accent (WatchPalette.healthy for
//     a healthy running box); everything else — stopped, pending, unknown —
//     is a neutral secondary tone, and the long-running warning reuses the
//     same WatchPalette.warning already used elsewhere in the app;
//   - name gets real weight (13pt semibold) over a quieter 11pt meta line,
//     and nothing in the meta line truncates — Owner/IP move to a tooltip
//     instead of getting clipped;
//   - row actions collapse into a single trailing overflow menu instead of
//     three always-visible text buttons;
//   - the list caps its height and scrolls rather than growing the popover
//     without bound.
//
// "Mine" awareness (colleague multi-tenancy on one shared account): a
// subtle monospaced "YOU" tag reuses the section's one accent color rather
// than inventing a second hue, and the "Only mine" toggle only appears once
// there's an actual identity to filter by — a control that can't do
// anything yet is worse than no control. The first-run setup card (shown
// when the configured profile has no local AWS config at all) uses the
// same inset/code-box treatment as Settings → Connect's CodeBox, so it
// reads as "this app" rather than a bolted-on wizard.
import AppKit
import DevOnCallAWS
import SwiftUI

struct AWSBoxesSection: View {
    @ObservedObject var model: AppModel

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = model.awsErrorSummary {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(WatchPalette.critical)
                    .lineLimit(2)
            }
            content
        }
        .padding(14)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AWS BOXES")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                if model.awsRunningCount > 0 {
                    Text("\(model.awsRunningCount) running")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(lastRefreshedText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Button {
                    model.refreshAWSBoxesNow()
                } label: {
                    if model.awsIsRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .disabled(model.awsIsRefreshing)
            }

            // Only shown once we actually know who "you" are — a toggle
            // that can't change anything yet would just be confusing.
            if model.awsCurrentUserName != nil {
                Toggle(isOn: $model.awsOnlyMine) {
                    Text("Only mine")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }

    private var lastRefreshedText: String {
        guard let date = model.awsLastRefreshed else { return "Not refreshed yet" }
        return Self.clockFormatter.string(from: date)
    }

    @ViewBuilder
    private var content: some View {
        if model.awsProfileMissing {
            setupCard
        } else if model.awsInstances.isEmpty, !model.awsIsRefreshing, model.awsErrorSummary == nil {
            emptyState
        } else if model.awsInstances.isEmpty, !model.awsIsRefreshing {
            // Errors present and nothing decoded — the error banner above
            // already explains why; keep this compact.
            EmptyView()
        } else if model.awsOnlyMine, model.awsGroupedInstances.isEmpty, !model.awsIsRefreshing {
            onlyMineEmptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.awsGroupedInstances, id: \.region) { group in
                        regionSection(group)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 230)
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(WatchPalette.healthy)
            Text("No EC2 instances in the configured regions")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var onlyMineEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)
            Text("None of the visible boxes are tagged to you")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// First-run state: the configured profile (default "sako") has no
    /// section at all in the local AWS config, so every describe-instances
    /// call would just fail. Rather than a wall of CLI error text, tell a
    /// colleague exactly what to run.
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "key.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("AWS access isn't set up yet")
                    .font(.system(size: 12.5, weight: .semibold))
            }

            Text("Run this with your own access key, then set the region to ap-south-1 when asked:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text(setupCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(setupCommand, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
            .padding(9)
            .background(WatchPalette.inset)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Link("Setup guide", destination: URL(string: SETUP_GUIDE_URL) ?? URL(string: "https://github.com/wicolian/dev-on-call")!)
                .font(.system(size: 11))
        }
        .padding(.vertical, 6)
    }

    private var setupCommand: String {
        "aws configure --profile \(model.preferences.awsProfile)"
    }

    private func regionSection(_ group: (region: String, instances: [Instance])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.region.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Text("\(group.instances.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(group.instances) { instance in
                    AWSInstanceRow(model: model, instance: instance)
                }
            }
        }
    }
}

private struct AWSInstanceRow: View {
    @ObservedObject var model: AppModel
    let instance: Instance

    @State private var showTerminateConfirm = false

    private var isActing: Bool { model.awsActingInstanceIDs.contains(instance.id) }
    private var isStopped: Bool { instance.state == .stopped }
    private var isLongRunning: Bool {
        instance.isLongRunning(thresholdHours: Double(max(1, model.preferences.awsLongRunningAlertHours)))
    }

    /// One accent color only: green means "healthy and running." The long-
    /// running warning reuses the app's existing warning color rather than
    /// inventing a new hue. Every other state is a neutral, secondary tone.
    private var railColor: Color {
        if instance.state == .running {
            return isLongRunning ? WatchPalette.warning : WatchPalette.healthy
        }
        return Color.secondary.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(railColor)
                .frame(width: 3)
                .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(instance.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.isMine(instance) {
                        Text("YOU")
                            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(WatchPalette.healthy)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(WatchPalette.healthy.opacity(0.16))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 6)
                    Text(instance.lifecycle.label.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                    actionControl
                }
                Text("\(instance.instanceType) · \(instance.state.label) · \(instance.uptimeString())")
                    .font(.system(size: 11))
                    .foregroundStyle(isLongRunning ? WatchPalette.warning : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(WatchPalette.inset)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(WatchPalette.borderSoft, lineWidth: 0.5)
        }
        .opacity(isStopped ? 0.55 : 1)
        .help(tooltipText)
        .alert(
            "Terminate \(instance.displayName)?",
            isPresented: $showTerminateConfirm
        ) {
            Button("Terminate", role: .destructive) { model.awsTerminate(instance) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently terminates \(instance.displayName) (\(instance.id)) in \(instance.region). This cannot be undone.")
        }
    }

    private var tooltipText: String {
        var parts: [String] = []
        if let owner = instance.owner, !owner.isEmpty { parts.append("Owner: \(owner)") }
        if let ip = instance.publicIP, !ip.isEmpty { parts.append("IP: \(ip)") }
        parts.append(instance.id)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionControl: some View {
        if isActing {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
        } else {
            Menu {
                Button("Stop") { model.awsStop(instance) }
                    .disabled(instance.state != .running)
                Button("Start") { model.awsStart(instance) }
                    .disabled(instance.state != .stopped)
                Divider()
                Button("Terminate…", role: .destructive) { showTerminateConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18, height: 18)
        }
    }
}
