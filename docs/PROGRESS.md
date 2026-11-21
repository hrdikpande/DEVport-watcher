# Progress — autopilot build of Phases 2–12

Resume from this file if a session ends. Spec: `docs/IMPLEMENTATION_PROMPT.md`;
run rules: `docs/AUTOPILOT_PROMPT.md`.

## Current state (checkpoint 2026-11-21, owner asked to stop)

- **Phase 2:** done. Branch `phase-2`, draft PR #5 → main, CI green.
- **Phase 3:** done. Branch `phase-3`, draft PR #6 → phase-2, CI green.
- **Phase 4:** in progress on `phase-4` (from `phase-3`). The last commit is "phase-4: WIP checkpoint". Not pushed.
  - Done: starter attribution (`Agents.swift`); orphan verdicts with evidence and Safe to stop?
    (`Orphans.swift`); duplicates; idle and starter memory; leftovers without ports; bulk clean-up via
    `stopAll` (StopRegistry + safe ladder); Doctor issues; AI setup prompt; Star; app Health, Leftovers,
    ORPHAN/TWICE badges, Clean Up dialog; CLI badges and Leftovers; harness orphan, duplicate and leftover
    scenarios (passed `--check`).
  - Tests: 111 (17 new in `Phase4Tests.swift`).
  - Remaining for Phase 4: run `build_app.sh`, `ui_smoke.sh` and `perf_check.sh`; update CHANGELOG,
    FEATURES and NOTES; push; open the PR (base `phase-3`); wait for CI.
- **Scan timing** (Phase 3, harness running): 2.9–3.7 ms warm, 627 processes.
- **Next step:** `git checkout phase-4`, then
  `./Scripts/build_app.sh --no-install && ./Scripts/ui_smoke.sh && ./Scripts/perf_check.sh`. Then do the
  docs, `swift test` ×5, push and the PR.

## Decisions

- 2026-11-21 — Scope: build all of Phases 2–12, including the items `docs/NOTES.md` once deferred
  to "Release 2". No extra feature flags; only the spec's defaults (MCP stop off, probes only while the
  panel is open, read-only, loopback only, bulk clean-up always confirms, §14 non-goals stay out).
- 2026-11-21 — Servers bound only to a LAN IP are never probed (autopilot amendment 5); Phase 9 adds
  "Copy LAN URL" instead. Settles the open question in NOTES.

## Gates

| Phase | build release | build tests | swift test ×5 | build_app | harness --check | ui_smoke | scan warm | RSS | idle CPU | CI |
|-------|---------------|-------------|---------------|-----------|-----------------|----------|-----------|-----|----------|----|
| 2     | 0 warnings    | 0 warnings  | 78/78 ×5      | pass      | pass (13 ports, 0 left) | pass | 2.0–6.7 ms (579 procs) | footprint 17.5 MB (RSS 56 MB) | n/a | pass (#5) |
| 3     | 0 warnings    | 0 warnings  | 94/94 ×5 (130 matcher cases) | pass | pass (14 ports + AirPlay explainer, 0 left) | pass | 2.9–3.7 ms (627 procs) | footprint 19.2 MB (RSS 60 MB) | n/a | pending |

Baseline before Phase 2 (main, `PortsApp --list`): scan 8–15 ms warm, 48 tests pass.

Perf numbers come from `Scripts/perf_check.sh` (added in Phase 3), with the harness running.

## Accessibility

- 2026-11-21: `UI elements enabled` = true for this terminal; `Scripts/ui_smoke.sh` reads the status-item
  menu (an accessory app's status item lives in `menu bar 1`, not 2).

## Open issues

- Phase 4: one `swift test` run of about 12 failed with 1 issue that I didn't capture. The next 9 runs passed.
  Find it with a repeated run before pushing (suspects: the perl orphan test and the bulk stop test).
- Phase 4: the auto-mode classifier blocked a harness scenario that registers a temporary LaunchAgent
  (`launchctl bootstrap gui/<uid>`). Launchd-job exclusion is covered only by unit tests that use
  `launchctl list` fixtures. Owner decision needed: allow it, or keep it out.

- Memory gate is measured as physical footprint (Activity Monitor "Memory"), since raw RSS of any AppKit
  status-item app is ~50 MB of shared framework pages. Both numbers are recorded. Owner may overrule.
- A `build/Ports.app` instance (PID 79213) started before this session is still running; I didn't start it,
  so I'm leaving it alone.
- `ld: warning: search path '/Library/Developer/CommandLineTools/...' not found` comes from this Mac's
  toolchain setup, not from code; it is excluded from the warning counts.
