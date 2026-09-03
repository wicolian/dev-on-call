import Foundation

public enum TranscriptDelta {
    public static func newText(previous: String, current: String) -> String? {
        guard previous != current else { return nil }
        if current.hasPrefix(previous) {
            let delta = String(current.dropFirst(previous.count))
            return delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : delta
        }

        let anchor = String(previous.suffix(400))
        if anchor.count == 400,
           let range = current.range(of: anchor, options: .backwards) {
            let delta = String(current[range.upperBound...])
            return delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : delta
        }

        // A cleared, restarted, or substantially shifted buffer becomes a new
        // baseline. Returning the whole replacement would replay old output.
        return nil
    }
}
