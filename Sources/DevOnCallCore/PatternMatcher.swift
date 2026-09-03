import Foundation

public enum PatternMatcher {
    private static let quotaPatterns = [
        "usage limit", "session limit", "rate limit", "quota exceeded",
        "spend limit", "spend cap", "too many requests", "resets at", "http 429"
    ]

    private static let permissionPatterns = [
        "permission required", "approval required", "waiting for approval",
        "allow this command", "needs your permission", "waiting for input",
        "permission dialog"
    ]

    private static let failurePatterns = [
        "build failed", "tests failed", "test failed", "ci failed",
        "review bot failed", "code review failed", "fatal error", "fatal:"
    ]

    public static func detect(in transcript: String) -> Detection? {
        let compact = transcript
            .suffix(8_000)
            .replacingOccurrences(of: "\u{001B}", with: "")
        let lower = compact.lowercased()

        if let phrase = quotaPatterns.first(where: { lower.contains($0) }) {
            return Detection(
                severity: .critical,
                title: "Account or session limit",
                detail: context(around: phrase, in: compact)
            )
        }

        if let phrase = permissionPatterns.first(where: { lower.contains($0) }) {
            return Detection(
                severity: .warning,
                title: "Agent needs permission",
                detail: context(around: phrase, in: compact)
            )
        }

        if let phrase = failurePatterns.first(where: { lower.contains($0) }) {
            return Detection(
                severity: .critical,
                title: "Automation failure",
                detail: context(around: phrase, in: compact)
            )
        }

        return nil
    }

    private static func context(around phrase: String, in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        if let line = lines.last(where: { $0.localizedCaseInsensitiveContains(phrase) }) {
            return String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        }
        return String(text.suffix(280)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
