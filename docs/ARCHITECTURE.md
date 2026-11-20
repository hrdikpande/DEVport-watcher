# Architecture

Ports is a local macOS menu-bar application with three package targets:

```text
PortsCore
├── Native process and socket inspection
├── Docker discovery and safe command execution
├── Listener classification
├── Listener scanning
└── Safe process termination

PortsApp
└── AppKit status item, menu, dialogs, and actions

ports
└── Secondary command-line listing interface
```

`PortsCore` has no AppKit dependency and is shared by the application and CLI.
The current implementation intentionally preserves the existing scanner,
classifier, Docker behavior, and termination ladder. Phase 1 and later phases
may improve those behaviors only after the characterization tests establish a
baseline.

All destructive actions remain confirmation-gated. Process termination checks
PID identity and ownership immediately before signaling. Docker commands use a
fixed executable path, argument arrays, validated container names, and a
timeout.
