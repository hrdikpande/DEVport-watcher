# Progress — autopilot build of Phases 2–12

Resume from this file if a session ends. Spec: `docs/IMPLEMENTATION_PROMPT.md`;
run rules: `docs/AUTOPILOT_PROMPT.md`.

## Current state

- **Phase:** 2 (richer process model), in progress
- **Branch:** `phase-2` (from `main` at `42e64f2`)
- **Last commit:** see `git log -1 phase-2`
- **Next step:** implement Phase 2 items 1–8, add `Scripts/ui_smoke.sh`, run gates.

## Decisions

- 2026-11-21 — Scope: build all of Phases 2–12, including the items `docs/NOTES.md` once deferred
  to "Release 2". No extra feature flags; only the spec's defaults (MCP stop off, probes only while the
  panel is open, read-only, loopback only, bulk clean-up always confirms, §14 non-goals stay out).
- 2026-11-21 — Servers bound only to a LAN IP are never probed (autopilot amendment 5); Phase 9 adds
  "Copy LAN URL" instead. Settles the open question in NOTES.

## Gates

| Phase | build release | build tests | swift test ×5 | build_app | harness --check | ui_smoke | scan warm | RSS | idle CPU | CI |
|-------|---------------|-------------|---------------|-----------|-----------------|----------|-----------|-----|----------|----|
| 2     |               |             |               |           |                 |          |           |     | n/a      |    |

Baseline before Phase 2 (main, `PortsApp --list`): scan 8–15 ms warm, 48 tests pass.

## Open issues

- (none yet)
