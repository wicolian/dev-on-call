# Contributing

Issues and focused pull requests are welcome.

Before opening a pull request:

```bash
swift run dev-on-call-self-test
swift build --product DevOnCall
swift build --product dev-on-call
```

Design constraints:

- keep the primary experience in the menu bar;
- default to silence and preserve quiet hours;
- never change system volume or loop audio;
- keep Herdr and terminal integrations read-only unless the user explicitly initiates an action;
- do not collect telemetry or credentials;
- expose new integrations through a small adapter, the inbox protocol, or a shell probe.

Please describe the failure signal, deduplication behavior, and recovery behavior for every new monitor.
