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
    }

    private var lastRefreshedText: String {
        guard let date = model.awsLastRefreshed else { return "Not refreshed yet" }
        return Self.clockFormatter.string(from: date)
    }

    @ViewBuilder
    private var content: some View {
        if model.awsInstances.isEmpty, !model.awsIsRefreshing, model.awsErrorSummary == nil {
            emptyState
        } else if model.awsInstances.isEmpty, !model.awsIsRefreshing {
            // Errors present and nothing decoded — the error banner above
            // already explains why; keep this compact.
            EmptyView()
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
