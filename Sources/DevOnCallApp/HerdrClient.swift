import DevOnCallCore
import Foundation

struct HerdrPane: Hashable {
    let id: String
    let status: String
    let label: String
}

enum HerdrClient {
    static func listPanes() async -> Result<[HerdrPane], Error> {
        guard let executable = ExecutableLocator.find("herdr") else {
            return .failure(ClientError("Herdr CLI not found"))
        }

        let result = await CommandRunner.run(
            executable: executable,
            arguments: ["pane", "list"],
            timeout: 8
        )
        guard result.exitCode == 0 else {
            return .failure(ClientError(result.output.nonEmptyOr("Herdr pane list failed")))
        }

        do {
            let data = Data(result.output.utf8)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultObject = root["result"] as? [String: Any],
                  let paneObjects = resultObject["panes"] as? [[String: Any]]
            else { throw ClientError("Unexpected Herdr JSON response") }

            let panes = paneObjects.compactMap { pane -> HerdrPane? in
                guard let id = (pane["pane_id"] ?? pane["id"]) as? String else { return nil }
                let status = (pane["agent_status"] as? String) ?? "unknown"
                let label = ["label", "title", "agent_label", "process_name"]
                    .compactMap { pane[$0] as? String }
                    .first(where: { !$0.isEmpty }) ?? id
                return HerdrPane(id: id, status: status, label: label)
            }
            return .success(panes)
        } catch {
            return .failure(error)
        }
    }

    static func readRecent(paneID: String) async -> String? {
        guard let executable = ExecutableLocator.find("herdr") else { return nil }
        let result = await CommandRunner.run(
            executable: executable,
            arguments: ["pane", "read", paneID, "--source", "recent-unwrapped", "--lines", "100"],
            timeout: 8
        )
        return result.exitCode == 0 ? result.output : nil
    }

    private struct ClientError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
