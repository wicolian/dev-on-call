import DevOnCallCore
import SwiftUI

enum WatchPalette {
    static let healthy = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)
    static let informational = Color(nsColor: .systemBlue)
    static let border = Color.primary.opacity(0.09)
    static let borderSoft = Color.primary.opacity(0.055)
    static let inset = Color.primary.opacity(0.045)

    static func color(for severity: AlertSeverity) -> Color {
        switch severity {
        case .info: return informational
        case .warning: return warning
        case .critical: return critical
        }
    }
}
