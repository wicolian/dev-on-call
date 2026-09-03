# Security policy

## Local trust boundary

Dev On Call is intentionally not sandboxed because its job is to invoke user-configured local health checks and already-installed agent CLIs. It runs with the permissions of the signed-in macOS user.

- Shell probes are arbitrary commands. Add only commands you trust.
- Herdr integration invokes only `pane list` and `pane read`. It does not focus, type into, create, move, or close panes.
- Inbox events are local JSON files under `~/Library/Application Support/DevOnCall`.
- No telemetry, credentials, pane transcripts, or alerts are sent to this project.

## AI narration

AI narration is off by default. When enabled, the alert source, title, and up to 600 characters of detail are sent through the selected local Claude or Codex CLI using that CLI's existing account.

Alert content is treated as untrusted input. Claude is launched with tools disabled and session persistence off. Codex is launched ephemerally in a read-only sandbox with user rules ignored. The result is used only as spoken text. Users should still avoid placing secrets in alert messages.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for `wicolian/dev-on-call`. Do not include credentials, private terminal output, or access tokens in a report.
