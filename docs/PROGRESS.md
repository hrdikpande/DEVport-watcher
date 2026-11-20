# Progress — autopilot build of Phases 2–12

Resume from this file if a session ends. Spec: `docs/IMPLEMENTATION_PROMPT.md`;
run rules: `docs/AUTOPILOT_PROMPT.md`.

## Current state

- **Phase:** 2 (richer process model), gates passed locally; PR open, waiting for CI
- **Branch:** `phase-2` (from `main` at `42e64f2`)
- **Last commit:** see `git log -1 phase-2`
- **Next step:** CI green on the Phase 2 PR, then create `phase-3` from `phase-2`.

## Decisions

- 2026-11-21 — Scope: build all of Phases 2–12, including the items `docs/NOTES.md` once deferred
  to "Release 2". No extra feature flags; only the spec's defaults (MCP stop off, probes only while the
  panel is open, read-only, loopback only, bulk clean-up always confirms, §14 non-goals stay out).
- 2026-11-21 — Servers bound only to a LAN IP are never probed (autopilot amendment 5); Phase 9 adds
  "Copy LAN URL" instead. Settles the open question in NOTES.

## Gates

| Phase | build release | build tests | swift test ×5 | build_app | harness --check | ui_smoke | scan warm | RSS | idle CPU | CI |
|-------|---------------|-------------|---------------|-----------|-----------------|----------|-----------|-----|----------|----|
| 2     | 0 warnings    | 0 warnings  | 78/78 ×5      | pass      | pass (13 ports, 0 left) | pass | 2.0–6.7 ms (579 procs) | footprint 17.5 MB (RSS 56 MB) | n/a | pending |

Baseline before Phase 2 (main, `PortsApp --list`): scan 8–15 ms warm, 48 tests pass.

## Accessibility

- 2026-11-21: `UI elements enabled` = true for this terminal; `Scripts/ui_smoke.sh` reads the status-item
  menu (an accessory app's status item lives in `menu bar 1`, not 2).

## Open issues

- Memory gate is measured as physical footprint (Activity Monitor "Memory"), since raw RSS of any AppKit
  status-item app is ~50 MB of shared framework pages. Both numbers are recorded. Owner may overrule.
- A `build/Ports.app` instance (PID 79213) started before this session is still running; I didn't start it,
  so I'm leaving it alone.
- `ld: warning: search path '/Library/Developer/CommandLineTools/...' not found` comes from this Mac's
  toolchain setup, not from code; it is excluded from the warning counts.
