# Integration recipes

## Repository pre-commit

```bash
dev-on-call install --repo . --command 'npm test'
```

The command is optional. Without it, Dev On Call observes the repository's existing pre-commit hook. Existing hook code is moved to a reversible sibling backup and called first with its exit status preserved. Shared `core.hooksPath` setups use a repository-local opt-in so unrelated repositories remain unaffected.

## Generic command

```bash
your-command || dev-on-call alert \
  --source your-tool \
  --severity critical \
  --title "Command failed" \
  --body "Open the terminal log."
```

## GitHub Actions

Put repository-specific GitHub CLI logic in a script, test it manually, then add that script as a shell probe. The script should exit `0` for queued, running, or successful states and non-zero only for terminal failures.

Keeping API parsing in a script makes credentials, repository selection, and retry behavior explicit instead of hiding them in the app.

## Review bots

If a review bot exposes a CLI, poll its last completed state with a shell probe. If it offers hooks, invoke `dev-on-call alert` directly from the failure hook. Include the review URL in `--body` when it is not sensitive.

## Local test watcher

```bash
if ! swift test; then
  dev-on-call alert \
    --source swift-test \
    --severity critical \
    --title "Swift tests failed" \
    --body "Open the current terminal for the failure output."
fi
```

## Inbox protocol

The supported public interface is the companion CLI. Internally it writes one JSON file per event to `~/Library/Application Support/DevOnCall/inbox`. Atomic file writes let the menu app consume events without a network listener or privileged daemon.

## AWS boxes (in-app producer)

Not every alert comes from outside the app. The AWS boxes feature (Settings → AWS) is an in-app example of the same alert pipeline: when a running EC2 instance crosses the configured hour limit, the app builds the same `AlertEvent` type the CLI and Herdr scanner use and passes it through the same ingest/dedup path — no separate queue, no second delivery mechanism. If you build another in-app monitor, follow this pattern rather than writing to the inbox from inside the app process itself.
