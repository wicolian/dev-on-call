// Workspaces.swift
// DevOnCallAWS
//
// Amazon WorkSpaces support, sitting alongside the ported EC2 layer in
// Models.swift/AWSClient.swift. A WorkSpace is a persistent desktop, not a
// server, so the model deliberately measures different things:
//
//   - EC2 asks "how long has this been up?" (LaunchTime). WorkSpaces has no
//     launch time at all — an ALWAYS_ON desktop is up by definition. The
//     honest waste question for a desktop is "when did a human last sit at
//     it?", which is what DescribeWorkspacesConnectionStatus answers.
//   - Cost control is a property of the WorkSpace itself (AUTO_STOP with a
//     timeout budget vs ALWAYS_ON), not of the purchase (spot/on-demand).
//
// Like Models.swift this stays Foundation-only and UI-agnostic: state maps
// to a semantic `health` case, never to a Color. The view layer decides
// what each case looks like.
//
// The compute type comes straight off WorkspaceProperties.ComputeTypeName,
// so listing WorkSpaces needs no DescribeWorkspaceBundles call and no
// bundle-name cache — one describe per region, plus one cheap connection
// status call per region.

import Foundation

// MARK: - Raw AWS CLI JSON shapes
//
// (aws workspaces describe-workspaces --output json, and
//  aws workspaces describe-workspaces-connection-status --output json)
//
// Same rule as the EC2 shapes: every field is optional or defaulted, so a
// partially populated or future-shaped response never breaks decoding.

public struct WorkspacesDescribeResponse: Decodable {
    public var workspaces: [RawWorkspace]

    enum CodingKeys: String, CodingKey {
        case workspaces = "Workspaces"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decodeIfPresent([RawWorkspace].self, forKey: .workspaces) ?? []
    }
}

public struct RawWorkspace: Decodable {
    var workspaceId: String
    var userName: String?
    var computerName: String?
    var state: String?
    var bundleId: String?
    var properties: RawWorkspaceProperties?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "WorkspaceId"
        case userName = "UserName"
        case computerName = "ComputerName"
        case state = "State"
        case bundleId = "BundleId"
        case properties = "WorkspaceProperties"
        case errorMessage = "ErrorMessage"
    }
}

struct RawWorkspaceProperties: Decodable {
    var runningMode: String?
    var runningModeAutoStopTimeoutInMinutes: Int?
    var computeTypeName: String?
    var operatingSystemName: String?

    enum CodingKeys: String, CodingKey {
        case runningMode = "RunningMode"
        case runningModeAutoStopTimeoutInMinutes = "RunningModeAutoStopTimeoutInMinutes"
        case computeTypeName = "ComputeTypeName"
        case operatingSystemName = "OperatingSystemName"
    }
}

public struct WorkspacesConnectionStatusResponse: Decodable {
    public var statuses: [RawWorkspaceConnectionStatus]

    enum CodingKeys: String, CodingKey {
        case statuses = "WorkspacesConnectionStatus"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statuses = try container.decodeIfPresent([RawWorkspaceConnectionStatus].self, forKey: .statuses) ?? []
    }
}

public struct RawWorkspaceConnectionStatus: Decodable {
    var workspaceId: String?
    var connectionState: String?
    var lastKnownUserConnectionTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "WorkspaceId"
        case connectionState = "ConnectionState"
        case lastKnownUserConnectionTimestamp = "LastKnownUserConnectionTimestamp"
    }
}

// MARK: - Domain model

/// How a WorkSpace's state reads to a human, with no color attached. The
/// view layer maps these four cases onto the app's existing palette.
public enum WorkspaceHealth: Hashable, Sendable {
    /// Up, billable, ready for someone to connect.
    case available
    /// Deliberately not running (or gone) — nothing to worry about.
    case resting
    /// Mid-transition. Will settle on its own; don't act on it yet.
    case transitioning
    /// Broken. Needs a human.
    case faulted
}

public enum WorkspaceState: Hashable, Sendable {
    case available
    case pending
    case starting
    case stopping
    case stopped
    case rebooting
    case rebuilding
    case restoring
    case maintenance
    case adminMaintenance
    case updating
    case suspended
    case terminating
    case terminated
    case unhealthy
    case error
    case impaired
    case unknown(String)

    public init(raw: String?) {
        switch (raw ?? "").uppercased() {
        case "AVAILABLE": self = .available
        case "PENDING": self = .pending
        case "STARTING": self = .starting
        case "STOPPING": self = .stopping
        case "STOPPED": self = .stopped
        case "REBOOTING": self = .rebooting
        case "REBUILDING": self = .rebuilding
        case "RESTORING": self = .restoring
        case "MAINTENANCE": self = .maintenance
        case "ADMIN_MAINTENANCE": self = .adminMaintenance
        case "UPDATING": self = .updating
        case "SUSPENDED": self = .suspended
        case "TERMINATING": self = .terminating
        case "TERMINATED": self = .terminated
        case "UNHEALTHY": self = .unhealthy
        case "ERROR": self = .error
        case "IMPAIRED": self = .impaired
        case let other: self = .unknown(other)
        }
    }

    public var label: String {
        switch self {
        case .available: return "Available"
        case .pending: return "Pending"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .rebooting: return "Rebooting"
        case .rebuilding: return "Rebuilding"
        case .restoring: return "Restoring"
        case .maintenance: return "Maintenance"
        case .adminMaintenance: return "Admin maintenance"
        case .updating: return "Updating"
        case .suspended: return "Suspended"
        case .terminating: return "Terminating"
        case .terminated: return "Terminated"
        case .unhealthy: return "Unhealthy"
        case .error: return "Error"
        case .impaired: return "Impaired"
        case .unknown(let raw):
            guard !raw.isEmpty else { return "Unknown" }
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var health: WorkspaceHealth {
        switch self {
        case .available:
            return .available
        case .stopped, .suspended, .terminated:
            return .resting
        case .pending, .starting, .stopping, .rebooting, .rebuilding,
             .restoring, .maintenance, .adminMaintenance, .updating, .terminating:
            return .transitioning
        case .unhealthy, .error, .impaired:
            return .faulted
        case .unknown:
            return .resting
        }
    }

    /// Available desktops float to the top; anything broken sits just under
    /// them so it can't hide below a wall of stopped machines.
    public var sortRank: Int {
        switch health {
        case .available: return 0
        case .faulted: return 1
        case .transitioning: return 2
        case .resting: return 3
        }
    }
}

public enum WorkspaceRunningMode: Hashable, Sendable {
    /// Stops itself after `timeoutMinutes` of nobody connected. Billed by
    /// the hour, so an idle one costs nothing — never worth alerting about.
    case autoStop(timeoutMinutes: Int?)
    /// Runs whether anyone uses it or not. Billed monthly at the full rate.
    case alwaysOn
    case other(String)

    public init(raw: String?, timeoutMinutes: Int?) {
        switch (raw ?? "").uppercased() {
        case "AUTO_STOP": self = .autoStop(timeoutMinutes: timeoutMinutes)
        case "ALWAYS_ON": self = .alwaysOn
        case "": self = .other("Unknown")
        case let other: self = .other(other.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    /// Short uppercase form for the trailing mono tag, sitting exactly where
    /// an EC2 row shows SPOT / ON-DEMAND. Carries the auto-stop budget with
    /// it — the timeout is the whole point of the mode.
    public var tag: String {
        switch self {
        case .autoStop(let minutes):
            guard let minutes, minutes > 0 else { return "AUTO-STOP" }
            return "AUTO-STOP \(minutes)M"
        case .alwaysOn:
            return "ALWAYS-ON"
        case .other(let raw):
            return raw.uppercased()
        }
    }

    public var isAlwaysOn: Bool {
        if case .alwaysOn = self { return true }
        return false
    }
}

public enum WorkspaceConnectionState: Hashable, Sendable {
    case connected
    case disconnected
    case unknown

    public init(raw: String?) {
        switch (raw ?? "").uppercased() {
        case "CONNECTED": self = .connected
        case "DISCONNECTED": self = .disconnected
        default: self = .unknown
        }
    }
}

public struct WorkspaceConnection: Hashable, Sendable {
    public let state: WorkspaceConnectionState
    public let lastKnownUserConnection: Date?

    public init(state: WorkspaceConnectionState, lastKnownUserConnection: Date?) {
        self.state = state
        self.lastKnownUserConnection = lastKnownUserConnection
    }
}

public struct Workspace: Identifiable, Hashable, Sendable {
    public let id: String
    public let region: String
    public let userName: String?
    public let computerName: String?
    public let bundleId: String?
    public let computeTypeName: String?
    public let operatingSystemName: String?
    public let state: WorkspaceState
    public let runningMode: WorkspaceRunningMode
    public let errorMessage: String?
    public let connection: WorkspaceConnection?

    public init(
        id: String,
        region: String,
        userName: String?,
        computerName: String?,
        bundleId: String?,
        computeTypeName: String?,
        operatingSystemName: String?,
        state: WorkspaceState,
        runningMode: WorkspaceRunningMode,
        errorMessage: String?,
        connection: WorkspaceConnection?
    ) {
        self.id = id
        self.region = region
        self.userName = userName
        self.computerName = computerName
        self.bundleId = bundleId
        self.computeTypeName = computeTypeName
        self.operatingSystemName = operatingSystemName
        self.state = state
        self.runningMode = runningMode
        self.errorMessage = errorMessage
        self.connection = connection
    }

    /// ComputerName is what the person actually recognizes, but AWS leaves
    /// it empty until the desktop finishes building — so a freshly ordered
    /// WorkSpace shows its id rather than a blank row.
    public var displayName: String {
        if let computerName, !computerName.isEmpty { return computerName }
        return id
    }

    /// Human form of WorkspaceProperties.ComputeTypeName. Graphics bundles
    /// are named after their EC2 GPU family, so the family is the useful
    /// half: GRAPHICS_G6F_2XLARGE -> "g6f.2xlarge, GPU".
    public var computeLabel: String {
        Workspace.formatComputeType(computeTypeName)
    }

    public static func formatComputeType(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        let segments = raw.uppercased().split(separator: "_").map(String.init)
        guard let first = segments.first else { return "unknown" }

        if first.hasPrefix("GRAPHICS") {
            let family = segments.dropFirst().map { $0.lowercased() }.joined(separator: ".")
            let name = family.isEmpty ? first.lowercased() : family
            return "\(name), GPU"
        }

        let joined = segments.map { $0.lowercased() }.joined(separator: ".")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    public var isGPU: Bool {
        (computeTypeName ?? "").uppercased().hasPrefix("GRAPHICS")
    }

    /// Time since a person last connected, if AWS knows of one.
    public func idleTime(now: Date = Date()) -> TimeInterval? {
        guard let last = connection?.lastKnownUserConnection else { return nil }
        return max(0, now.timeIntervalSince(last))
    }

    /// The last slot of the row's meta line. An EC2 box reports machine
    /// uptime there; a desktop reports human presence, which is the number
    /// that actually tells you whether it should still be running.
    public func presenceString(now: Date = Date()) -> String {
        if connection?.state == .connected { return "Connected" }
        if let idle = idleTime(now: now) {
            return "Idle \(Instance.formatUptime(idle))"
        }
        if connection != nil { return "Never used" }
        return "-"
    }

    /// Waste flag, ALWAYS_ON only.
    ///
    /// An AUTO_STOP WorkSpace parks itself and stops billing, so it is never
    /// flagged no matter how long it sits. An ALWAYS_ON WorkSpace bills at
    /// the full monthly rate whether or not anyone connects, and it has no
    /// launch time to measure — it is up by definition. So the measurable
    /// waste is idle time: nobody has connected for longer than the
    /// configured threshold. With no known connection at all there is
    /// nothing to measure and nothing is claimed.
    public func isWastefullyIdle(now: Date = Date(), thresholdHours: Double = 12) -> Bool {
        guard runningMode.isAlwaysOn, state.health == .available else { return false }
        guard connection?.state != .connected else { return false }
        guard let idle = idleTime(now: now) else { return false }
        return idle > thresholdHours * 3600
    }

    /// Same rule as an EC2 box's Owner tag, applied to the WorkSpace's
    /// assigned user. Powers the "YOU" badge and the "Only mine" filter.
    public func isOwned(by userName: String?) -> Bool {
        guard let userName, !userName.isEmpty,
              let owner = self.userName, !owner.isEmpty
        else { return false }
        return owner.caseInsensitiveCompare(userName) == .orderedSame
    }

    public var canStart: Bool { state == .stopped }
    public var canStop: Bool { state == .available }
    public var canReboot: Bool { state == .available }
}

// MARK: - Mapping raw -> domain

extension RawWorkspace {
    func toWorkspace(region: String, connection: WorkspaceConnection?) -> Workspace {
        Workspace(
            id: workspaceId,
            region: region,
            userName: userName,
            computerName: computerName,
            bundleId: bundleId,
            computeTypeName: properties?.computeTypeName,
            operatingSystemName: properties?.operatingSystemName,
            state: WorkspaceState(raw: state),
            runningMode: WorkspaceRunningMode(
                raw: properties?.runningMode,
                timeoutMinutes: properties?.runningModeAutoStopTimeoutInMinutes
            ),
            errorMessage: errorMessage,
            connection: connection
        )
    }
}

extension WorkspacesConnectionStatusResponse {
    /// Connection status arrives as a separate flat list; index it by id so
    /// a WorkSpace missing from it (common right after creation) simply has
    /// no connection info rather than blocking the whole region.
    public func byWorkspaceID() -> [String: WorkspaceConnection] {
        var result: [String: WorkspaceConnection] = [:]
        for status in statuses {
            guard let id = status.workspaceId, !id.isEmpty else { continue }
            result[id] = WorkspaceConnection(
                state: WorkspaceConnectionState(raw: status.connectionState),
                lastKnownUserConnection: AWSDateParser.parse(status.lastKnownUserConnectionTimestamp)
            )
        }
        return result
    }
}

extension WorkspacesDescribeResponse {
    public func toWorkspaces(
        region: String,
        connections: [String: WorkspaceConnection] = [:]
    ) -> [Workspace] {
        workspaces.map { $0.toWorkspace(region: region, connection: connections[$0.workspaceId]) }
    }
}

// MARK: - Sorting

extension Array where Element == Workspace {
    /// Available first, then broken, then transitional, then parked — and
    /// alphabetically within each band so the list doesn't reshuffle
    /// between refreshes.
    public func sortedForDisplay() -> [Workspace] {
        sorted { lhs, rhs in
            if lhs.state.sortRank != rhs.state.sortRank {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}
