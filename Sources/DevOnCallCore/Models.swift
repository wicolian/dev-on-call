import Foundation

public enum AlertSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
    case info
    case warning
    case critical

    public var id: String { rawValue }
}

public struct AlertEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var severity: AlertSeverity
    public var source: String
    public var title: String
    public var detail: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        severity: AlertSeverity,
        source: String,
        title: String,
        detail: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.severity = severity
        self.source = source
        self.title = title
        self.detail = detail
    }

    public var fingerprint: String {
        "\(severity.rawValue)|\(source.lowercased())|\(title.lowercased())|\(detail.lowercased())"
    }

    public var fallbackSpokenMessage: String {
        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanDetail.isEmpty { return "\(source): \(title)." }
        return "\(source): \(title). \(cleanDetail)"
    }
}

public struct ProbeRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var intervalSeconds: Int
    public var timeoutSeconds: Int
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        intervalSeconds: Int = 60,
        timeoutSeconds: Int = 20,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.enabled = enabled
    }
}

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off — deterministic message"
        case .claude: return "Claude CLI"
        case .codex: return "Codex CLI"
        }
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var isArmed = true
    public var herdrEnabled = true
    public var herdrPollSeconds = 10
    public var blockedDelaySeconds = 90
    public var soundEnabled = false
    public var customSoundPath = ""
    public var speechEnabled = false
    public var systemNotificationsEnabled = false
    public var quietHoursEnabled = true
    public var quietStartHour = 23
    public var quietEndHour = 8
    public var allowCriticalDuringQuietHours = false
    public var snoozedUntil: Date?
    public var aiProvider: AIProvider = .off
    public var aiModel = ""
    public var aiExecutablePath = ""
    public var aiTimeoutSeconds = 45
    public var probes: [ProbeRule] = []

    // AWS Boxes — off by default. Region list empty means "use the built-in
    // default region list" (owned by DevOnCallAWS, which this module does
    // not depend on).
    public var awsBoxesEnabled = false
    public var awsProfile = "sako"
    public var awsRegions: [String] = []
    public var awsLongRunningAlertEnabled = true
    public var awsLongRunningAlertHours = 12
    /// Which owner name counts as "you" for the YOU badge and the "Only
    /// mine" filter. Empty means "use the username derived from the AWS
    /// caller identity", which is right whenever the IAM user is named
    /// after the person. It isn't always: a shared account can hand out
    /// per-machine bot users (`bots/kela-mac`) whose name has nothing to do
    /// with the `Owner` tags or WorkSpace users they own, and then nothing
    /// ever badges. This field is the manual override for that case.
    public var awsOwnerName = ""
    /// Whether the one-time local pre-fill of `awsOwnerName` has already
    /// happened. Kept separate so clearing the field stays cleared instead
    /// of being helpfully re-filled on the next launch.
    public var awsOwnerNameDidPrefill = false

    public init() {}

    // A custom decoder so preferences saved before the AWS Boxes fields
    // existed still load their probes, quiet hours, sound settings, etc.
    // instead of getting reset to AppPreferences() the first time this
    // decode would otherwise fail on a missing key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isArmed = try container.decodeIfPresent(Bool.self, forKey: .isArmed) ?? true
        herdrEnabled = try container.decodeIfPresent(Bool.self, forKey: .herdrEnabled) ?? true
        herdrPollSeconds = try container.decodeIfPresent(Int.self, forKey: .herdrPollSeconds) ?? 10
        blockedDelaySeconds = try container.decodeIfPresent(Int.self, forKey: .blockedDelaySeconds) ?? 90
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        customSoundPath = try container.decodeIfPresent(String.self, forKey: .customSoundPath) ?? ""
        speechEnabled = try container.decodeIfPresent(Bool.self, forKey: .speechEnabled) ?? false
        systemNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? false
        quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? true
        quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? 23
        quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? 8
        allowCriticalDuringQuietHours = try container.decodeIfPresent(Bool.self, forKey: .allowCriticalDuringQuietHours) ?? false
        snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        aiProvider = try container.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? .off
        aiModel = try container.decodeIfPresent(String.self, forKey: .aiModel) ?? ""
        aiExecutablePath = try container.decodeIfPresent(String.self, forKey: .aiExecutablePath) ?? ""
        aiTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .aiTimeoutSeconds) ?? 45
        probes = try container.decodeIfPresent([ProbeRule].self, forKey: .probes) ?? []

        awsBoxesEnabled = try container.decodeIfPresent(Bool.self, forKey: .awsBoxesEnabled) ?? false
        awsProfile = try container.decodeIfPresent(String.self, forKey: .awsProfile) ?? "sako"
        awsRegions = try container.decodeIfPresent([String].self, forKey: .awsRegions) ?? []
        awsLongRunningAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .awsLongRunningAlertEnabled) ?? true
        awsLongRunningAlertHours = try container.decodeIfPresent(Int.self, forKey: .awsLongRunningAlertHours) ?? 12
        awsOwnerName = try container.decodeIfPresent(String.self, forKey: .awsOwnerName) ?? ""
        awsOwnerNameDidPrefill = try container.decodeIfPresent(Bool.self, forKey: .awsOwnerNameDidPrefill) ?? false
    }
}

public struct Detection: Equatable, Sendable {
    public let severity: AlertSeverity
    public let title: String
    public let detail: String

    public init(severity: AlertSeverity, title: String, detail: String) {
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}
