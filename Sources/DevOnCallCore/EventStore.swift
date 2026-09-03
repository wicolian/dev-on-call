import Foundation

public enum EventStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func enqueue(_ event: AlertEvent) throws {
        try AppPaths.prepare()
        let destination = AppPaths.inbox.appendingPathComponent("\(event.id.uuidString).json")
        try encoder.encode(event).write(to: destination, options: .atomic)
    }

    public static func drainInbox() -> [AlertEvent] {
        try? AppPaths.prepare()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let event = try? decoder.decode(AlertEvent.self, from: data)
                else { return nil }
                try? FileManager.default.removeItem(at: url)
                return event
            }
    }

    public static func loadArchive() -> [AlertEvent] {
        guard let data = try? Data(contentsOf: AppPaths.archive) else { return [] }
        return (try? decoder.decode([AlertEvent].self, from: data)) ?? []
    }

    public static func saveArchive(_ events: [AlertEvent]) {
        try? AppPaths.prepare()
        try? encoder.encode(Array(events.prefix(200))).write(to: AppPaths.archive, options: .atomic)
    }

    public static func appendLog(_ message: String) {
        try? AppPaths.prepare()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp)  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: AppPaths.log.path),
           let handle = try? FileHandle(forWritingTo: AppPaths.log) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {}
        } else {
            try? data.write(to: AppPaths.log, options: .atomic)
        }
    }
}
