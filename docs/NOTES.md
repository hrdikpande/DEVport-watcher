# Roadmap notes

These amendments are recorded for later phases and are intentionally not
implemented in Phase 0.

1. **Release 1 scope:** Release 1 includes Phases 0, 1, 2, 4, 10 (core), and
   Phase 5 limited to process-tree stopping plus Homebrew service and
   LaunchAgent stopping. Release 2 defers database protocol handshakes, QR
   codes, ngrok/cloudflared URL discovery, multi-select cleanup, custom
   classification editing, history analytics, AI setup prompts, and MCP stop.
2. **Supervisor confirmations:** Every supervisor action confirmation must state
   what will stop, how it will stop, whether it will auto-restart, and whether
   the change persists after login.
3. **Privacy documentation:** Add a Privacy section to Settings and README
   listing every HTTP, database, and Docker-socket probe, when it runs (panel
   open only), where it runs (loopback only), its timeout, and that it is
   read-only.
4. **Panel layout:** Reserve space for container, database, and tunnel badges
   in the Phase 10 row layout from the beginning.
5. **README opening:** README must open with:
   “Ports tells developers what is running locally, why it is running, whether
   it is safe, and how to stop it — without leaving the menu bar.”
