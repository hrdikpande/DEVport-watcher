#!/bin/zsh
# Every phase gate in one run (autopilot §5). Prints one line per gate: pass / FAIL / skipped / manual.
#
#   ./Scripts/check.sh            # all gates
#   ./Scripts/check.sh --quick    # builds and tests only
#
# Exits non-zero if any gate FAILs. "skipped" and "manual" never count as passed.
set -uo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1
failed=0
report() { printf '%-28s %s\n' "$1" "$2"; if [[ "$2" == FAIL* ]]; then failed=1; fi; return 0; }
warnings() { grep -E 'warning:|error:' | grep -vc 'ld: warning: search path' ; }

touch Sources/*/*.swift Tests/PortsCoreTests/*.swift
n=$(swift build -c release 2>&1 | warnings)
(( n == 0 )) && report "swift build -c release" "pass (0 warnings)" || report "swift build -c release" "FAIL ($n warnings/errors)"
touch Sources/*/*.swift Tests/PortsCoreTests/*.swift
n=$(swift build --build-tests 2>&1 | warnings)
(( n == 0 )) && report "swift build --build-tests" "pass (0 warnings)" || report "swift build --build-tests" "FAIL ($n warnings/errors)"

runs=() ok=1
for i in 1 2 3 4 5; do
  line=$(swift test 2>&1 | grep -E 'Test run with')
  runs+="$line"
  [[ "$line" == *passed* ]] || ok=0
done
count=$(print -r -- "${runs[1]}" | sed -E 's/.*with ([0-9]+) tests.*/\1/')
(( ok )) && report "swift test ×5" "pass ($count tests each)" || { report "swift test ×5" "FAIL"; print -rl -- $runs; }

if (( QUICK )); then exit $failed; fi

./Scripts/build_app.sh --no-install >/dev/null 2>&1 && report "build_app.sh --no-install" "pass" || report "build_app.sh --no-install" "FAIL"
out=$(./Scripts/dev_harness.sh --check 2>&1); rc=$?
(( rc == 0 )) && report "dev_harness.sh --check" "pass" || { report "dev_harness.sh --check" "FAIL"; print -r -- "$out" | grep FAIL; }
report "dev_harness --with-launchd" "manual: owner runs dev_harness.sh --with-launchd --check"
out=$(./Scripts/ui_smoke.sh 2>&1); rc=$?
case $rc in
  0) report "ui_smoke.sh" "pass" ;;
  77) report "ui_smoke.sh" "skipped (no Accessibility permission)" ;;
  *) report "ui_smoke.sh" "FAIL"; print -r -- "$out" | tail -n 15 ;;
esac
out=$(./Scripts/perf_check.sh 2>&1); rc=$?
summary=$(print -r -- "$out" | grep -E 'footprint|PASSED|FAIL' | tr '\n' ' ')
(( rc == 0 )) && report "perf_check.sh" "pass: $summary" || report "perf_check.sh" "FAIL: $summary"

priv=$( { grep -rniE 'hardik|pande' Tests Sources; grep -rn '/Users/' Tests | grep -v '/Users/test/'; \
          grep -rn -E '\bkill\(' Sources | grep -v 'Sources/PortsCore/Actions/'; \
          grep -rln -E 'Process\(\)|posix_spawn|NSTask' Sources | grep -v 'Sources/PortsCore/Exec.swift'; \
          grep -rn 'URLSession' Sources; } 2>/dev/null )
[[ -z "$priv" ]] && report "privacy/safety grep" "pass" || { report "privacy/safety grep" "FAIL"; print -r -- "$priv"; }
exit $failed
