import Darwin
import DevOnCallCore
import Foundation

private let arguments = Array(CommandLine.arguments.dropFirst())

private func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func usage() {
    print("""
    Dev On Call companion CLI

    Usage:
      dev-on-call alert --title TEXT [--body TEXT] [--source NAME] [--severity info|warning|critical]
      dev-on-call paths

    Examples:
      npm test || dev-on-call alert --source tests --severity critical --title "npm test failed"
      dev-on-call alert --source review-bot --severity warning --title "Review needs attention" --body "Open PR 42"
    """)
}

guard let command = arguments.first else {
    usage()
    exit(0)
}

switch command {
case "alert", "emit":
    guard let title = value(after: "--title"), !title.isEmpty else {
        fputs("dev-on-call: --title is required\n", stderr)
        exit(2)
    }
    let severity = AlertSeverity(rawValue: value(after: "--severity") ?? "warning") ?? .warning
    let event = AlertEvent(
        severity: severity,
        source: value(after: "--source") ?? "Terminal",
        title: title,
        detail: value(after: "--body") ?? ""
    )
    do {
        try EventStore.enqueue(event)
        print("queued \(event.id.uuidString)")
    } catch {
        fputs("dev-on-call: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

case "paths":
    print("home:    \(AppPaths.root.path)")
    print("inbox:   \(AppPaths.inbox.path)")
    print("events:  \(AppPaths.archive.path)")
    print("log:     \(AppPaths.log.path)")

case "help", "--help", "-h":
    usage()

default:
    fputs("dev-on-call: unknown command '\(command)'\n", stderr)
    usage()
    exit(2)
}
