# Security

## Reporting a vulnerability

Please report security vulnerabilities privately through the repository's
security advisory feature rather than opening a public issue. Include the
affected version, reproduction steps, expected impact, and any suggested fix.

## Security model

Ports is a local macOS utility. It reads process and socket information from
macOS APIs and does not send telemetry.

The app can signal processes only after confirmation and only when the process
belongs to the current user. It re-checks process identity before signaling,
protects itself and system processes, uses a graceful termination first, and
validates Docker arguments.

The app signals processes. Review the confirmation details before approving a
destructive action.
