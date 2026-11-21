# Progress — autopilot build of Phases 2–12

Resume from this file if a session ends. Spec: `docs/IMPLEMENTATION_PROMPT.md`;
run rules: `docs/AUTOPILOT_PROMPT.md`.

## Current state

- **Phase 2:** done. Branch `phase-2`, draft PR #5 → main, CI green.
- **Phase 3:** done. Branch `phase-3`, draft PR #6 → phase-2, CI green.
- **Phase 4:** done. Branch `phase-4`, draft PR #7 → phase-3, CI green. All local gates pass except one
  manual gate (below).
- **Next step:** owner review. Phase 5 starts from `phase-4`; its FIRST commit splits `PortsCore.swift`
  (owner's rule 6). The owner asked me to stop after the Phase 4 PR.

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
| 3     | 0 warnings    | 0 warnings  | 94/94 ×5 (130 matcher cases) | pass | pass (14 ports + AirPlay explainer, 0 left) | pass | 2.9–3.7 ms (627 procs) | footprint 19.2 MB (RSS 60 MB) | n/a | pass (#6) |
| 4     | 0 warnings    | 0 warnings  | 111/111 ×5; flake hunt 20/20 clean | pass | pass (16 ports + orphan, duplicate, leftover; 0 left) | pass | ≤ 4.6 ms | footprint 20.8 MB (RSS 62 MB) | n/a | pass (#7) |

Phase 4 manual gate: **`dev_harness.sh --with-launchd --check` is manual. The owner runs it.** It is not
"passed" until the owner reports it. Launchd-job exclusion is unit-tested with `launchctl list` fixtures.
All gates in one run: `./Scripts/check.sh`.

Baseline before Phase 2 (main, `PortsApp --list`): scan 8–15 ms warm, 48 tests pass.

Perf numbers come from `Scripts/perf_check.sh` (added in Phase 3), with the harness running.

## Accessibility

- 2026-11-21: `UI elements enabled` = true for this terminal; `Scripts/ui_smoke.sh` reads the status-item
  menu (an accessory app's status item lives in `menu bar 1`, not 2).

## Open issues

- Earlier uncaptured flake: 20 more runs of `swift test` showed no failure, so it is not reproduced. Watch CI.
- The LaunchAgent scenario is implemented behind `--with-launchd` (owner-run; refused when CI is set). The agent
  never runs it.
- The app computes orphan verdicts only on menu-open scans, because those have the launchd job list. So "an agent
  that started it has exited" is noticed only if the menu was opened while the agent was alive.

- Memory gate is measured as physical footprint (Activity Monitor "Memory"), since raw RSS of any AppKit
  status-item app is ~50 MB of shared framework pages. Both numbers are recorded. Owner may overrule.
- A `build/Ports.app` instance (PID 79213) started before this session is still running; I didn't start it,
  so I'm leaving it alone.
- `ld: warning: search path '/Library/Developer/CommandLineTools/...' not found` comes from this Mac's
  toolchain setup, not from code; it is excluded from the warning counts.
