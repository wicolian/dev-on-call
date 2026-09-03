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

    public init() {}
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
