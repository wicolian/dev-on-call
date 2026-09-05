// Models.swift
// DevOnCallAWS
//
// Ported from the standalone "AWS Boxes" menu-bar app
// (Sources/AWSBoxesCore/Models.swift, github.com/koushik/aws-boxes, by Koushik)
// and folded into Dev On Call so the two personal menu-bar tools can live in
// one app. Decoding shapes, domain model, sorting, and uptime formatting are
// unchanged from the original.
//
// One deliberate change from the original: the SwiftUI `dotColor` convenience
// that lived on `InstanceState` was dropped. This module stays UI-agnostic
// (Foundation only) — Dev On Call's view layer (WatchPalette) now owns what
// color represents each state, matching how the rest of the app keeps
// presentation decisions out of its core/model layers.

import Foundation

// MARK: - Shared defaults

public enum AWSBoxesDefaults {
    public static let regions = [
        "ap-south-1",
        "us-east-1",
        "us-east-2",
        "us-west-2",
        "eu-west-1",
        "eu-north-1",
        "ap-southeast-1",
        "ap-southeast-2"
    ]
}

// MARK: - Raw AWS CLI JSON shapes (aws ec2 describe-instances --output json)
//
// These mirror the subset of the EC2 DescribeInstances response we care
// about. Every field we read is optional or defaulted so a partially
// populated / future-shaped response never crashes decoding.

public struct EC2DescribeInstancesResponse: Decodable {
    public var reservations: [EC2Reservation]

    enum CodingKeys: String, CodingKey {
        case reservations = "Reservations"
    }
}

public struct EC2Reservation: Decodable {
    public var instances: [EC2RawInstance]

    enum CodingKeys: String, CodingKey {
        case instances = "Instances"
    }
}

public struct EC2RawInstance: Decodable {
    var instanceId: String
    var instanceType: String?
    var state: EC2State?
    var publicIpAddress: String?
    var launchTime: String?
    var instanceLifecycle: String?
    var tags: [EC2Tag]?

    enum CodingKeys: String, CodingKey {
        case instanceId = "InstanceId"
        case instanceType = "InstanceType"
        case state = "State"
        case publicIpAddress = "PublicIpAddress"
        case launchTime = "LaunchTime"
        case instanceLifecycle = "InstanceLifecycle"
        case tags = "Tags"
    }
}

struct EC2State: Decodable {
    var name: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

struct EC2Tag: Decodable {
    var key: String?
    var value: String?

    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case value = "Value"
    }
}

// MARK: - Domain model used by the UI

public enum InstanceState: String, Hashable, Sendable {
    case running
    case stopped
    case pending
    case stopping
    case shuttingDown = "shutting-down"
    case terminated
    case unknown

    public init(rawState: String?) {
        self = InstanceState(rawValue: rawState ?? "") ?? .unknown
    }

    public var label: String {
        switch self {
        case .shuttingDown: return "Shutting down"
        case .unknown: return "Unknown"
        default: return rawValue.capitalized
        }
    }

    /// Sort priority: running instances float to the top.
    public var sortRank: Int {
        switch self {
        case .running: return 0
        case .pending: return 1
        case .stopping: return 2
        case .stopped: return 3
        case .shuttingDown: return 4
        case .terminated: return 5
        case .unknown: return 6
        }
    }
}

public enum InstanceLifecycle: String, Hashable, Sendable {
    case spot
    case onDemand

    public init(raw: String?) {
        self = (raw?.lowercased() == "spot") ? .spot : .onDemand
    }

    public var label: String {
        switch self {
        case .spot: return "Spot"
        case .onDemand: return "On-Demand"
        }
    }
}

public struct Instance: Identifiable, Hashable, Sendable {
    public let id: String
    public let region: String
    public let name: String?
    public let owner: String?
    public let instanceType: String
    public let state: InstanceState
    public let lifecycle: InstanceLifecycle
    public let publicIP: String?
    public let launchTime: Date?

    public init(
        id: String,
        region: String,
        name: String?,
        owner: String?,
        instanceType: String,
        state: InstanceState,
        lifecycle: InstanceLifecycle,
        publicIP: String?,
        launchTime: Date?
    ) {
        self.id = id
        self.region = region
        self.name = name
        self.owner = owner
        self.instanceType = instanceType
        self.state = state
        self.lifecycle = lifecycle
        self.publicIP = publicIP
        self.launchTime = launchTime
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return id
    }

    /// Elapsed time since launch, if known. For a terminated/stopped instance
    /// this is time-since-launch, not necessarily "still running" time, but
    /// it is the number the AWS API actually gives us cheaply.
    public func uptime(now: Date = Date()) -> TimeInterval? {
        guard let launchTime else { return nil }
        return max(0, now.timeIntervalSince(launchTime))
    }

    public func uptimeString(now: Date = Date()) -> String {
        guard let uptime = uptime(now: now) else { return "-" }
        return Instance.formatUptime(uptime)
    }

    public static func formatUptime(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Waste flag: running for more than 12 hours straight (the default —
    /// configurable in Dev On Call's AWS settings tab).
    public func isLongRunning(now: Date = Date(), thresholdHours: Double = 12) -> Bool {
        guard state == .running, let uptime = uptime(now: now) else { return false }
        return uptime > thresholdHours * 3600
    }
}

// MARK: - Date parsing

enum AWSDateParser {
    /// AWS CLI emits LaunchTime as an ISO-8601 string, typically with
    /// fractional seconds and a "Z" or "+00:00" offset. Try a small set of
    /// formatters rather than trusting a single exact format.
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }

        return nil
    }
}

// MARK: - Mapping raw -> domain

extension EC2RawInstance {
    func toInstance(region: String) -> Instance {
        let tagDict = Dictionary(
            (tags ?? []).compactMap { tag -> (String, String)? in
                guard let key = tag.key, let value = tag.value else { return nil }
                return (key, value)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return Instance(
            id: instanceId,
            region: region,
            name: tagDict["Name"],
            owner: tagDict["Owner"] ?? tagDict["owner"],
            instanceType: instanceType ?? "unknown",
            state: InstanceState(rawState: state?.name),
            lifecycle: InstanceLifecycle(raw: instanceLifecycle),
            publicIP: publicIpAddress,
            launchTime: AWSDateParser.parse(launchTime)
        )
    }
}

extension EC2DescribeInstancesResponse {
    public func toInstances(region: String) -> [Instance] {
        reservations.flatMap { reservation in
            reservation.instances.map { $0.toInstance(region: region) }
        }
    }
}

// MARK: - Sorting

extension Array where Element == Instance {
    /// Running first, then by launch time (oldest first, so forgotten boxes
    /// surface at the top of their group). Every instance in the array is
    /// kept — this never filters by state or lifecycle.
    public func sortedForDisplay() -> [Instance] {
        sorted { lhs, rhs in
            if lhs.state.sortRank != rhs.state.sortRank {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            let lhsTime = lhs.launchTime ?? .distantFuture
            let rhsTime = rhs.launchTime ?? .distantFuture
            return lhsTime < rhsTime
        }
    }
}
