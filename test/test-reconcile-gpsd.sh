#!/bin/bash
# Unit tests for configure-ublox-marine.sh: reconcile_gpsd_speed and main().
# Sources the script (its BASH_SOURCE guard keeps main() from running) and
# exercises the functions against temporary fixtures with a recording systemctl
# stub, so the gpsd-restart branch and main()'s orchestration are covered.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../usr/libexec/halos/configure-ublox-marine.sh"

failures=0
SYSCTL_LOG=$(mktemp)
SYSCTL_ACTIVE=1   # is-active exit code passed to the stub: 0 = active, 1 = inactive

# Recording stub: logs every invocation, drives `is-active` via $SYSCTL_ACTIVE.
systemctl() {
    printf '%s\n' "systemctl $*" >> "$SYSCTL_LOG"
    case "$1" in
        is-active) return "$SYSCTL_ACTIVE" ;;
    esac
    return 0
}

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
read_options() {
    # shellcheck source=/dev/null
    . "$1" && printf '%s' "${GPSD_OPTIONS:-}"
}

# --- reconcile_gpsd_speed: resulting GPSD_OPTIONS value ---
check_reconcile() {
    local desc="$1" body="$2" expected="$3" tmp actual
    tmp=$(mktemp)
    printf '%b' "$body" > "$tmp"
    SYSCTL_ACTIVE=1
    GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed 115200 >/dev/null
    actual=$(read_options "$tmp")
    if [ "$actual" = "$expected" ]; then pass "$desc"; else fail "$desc: expected [$expected] got [$actual]"; fi
    rm -f "$tmp"
}

check_reconcile "replaces wrong baud, preserves -n" 'DEVICES="/dev/ttyAMA0"\nGPSD_OPTIONS="-n -s 9600"\nUSBAUTO=true\n' "-n -s 115200"
check_reconcile "appends -s when absent, preserves -n" 'GPSD_OPTIONS="-n"\n' "-n -s 115200"
check_reconcile "idempotent when already correct" 'GPSD_OPTIONS="-n -s 115200"\n' "-n -s 115200"
check_reconcile "replaces baud with no other options" 'GPSD_OPTIONS="-s 4800"\n' "-s 115200"
check_reconcile "adds GPSD_OPTIONS when the line is absent entirely" 'DEVICES="/dev/ttyAMA0"\nUSBAUTO=true\n' "-s 115200"

# --- reconcile preserves the rest of the file ---
tmp=$(mktemp)
printf 'DEVICES="/dev/ttyAMA0"\nGPSD_OPTIONS="-n -s 9600"\nUSBAUTO=true\n' > "$tmp"
SYSCTL_ACTIVE=1
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed 115200 >/dev/null
if grep -q '^DEVICES="/dev/ttyAMA0"$' "$tmp" && grep -q '^USBAUTO=true$' "$tmp"; then
    pass "preserves DEVICES and USBAUTO lines"
else
    fail "DEVICES/USBAUTO not preserved"
fi
rm -f "$tmp"

# --- reconcile restart branch (the actual self-heal mechanism) ---
tmp=$(mktemp); : > "$SYSCTL_LOG"; SYSCTL_ACTIVE=0
printf 'GPSD_OPTIONS="-n -s 9600"\n' > "$tmp"
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed 115200 >/dev/null
if grep -q 'try-restart gpsd.service' "$SYSCTL_LOG" && grep -q -- '--no-block' "$SYSCTL_LOG"; then
    pass "restarts gpsd non-blocking when active and the file changed"
else
    fail "expected a non-blocking try-restart; log: [$(cat "$SYSCTL_LOG")]"
fi
rm -f "$tmp"

# --- idempotent: no rewrite and no restart when already correct ---
tmp=$(mktemp); : > "$SYSCTL_LOG"; SYSCTL_ACTIVE=0
printf 'GPSD_OPTIONS="-n -s 115200"\n' > "$tmp"
before=$(cat "$tmp")
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed 115200 >/dev/null
if [ "$(cat "$tmp")" = "$before" ] && [ ! -s "$SYSCTL_LOG" ]; then
    pass "no file rewrite and no gpsd restart when already correct"
else
    fail "idempotent case rewrote the file or restarted gpsd; log: [$(cat "$SYSCTL_LOG")]"
fi
rm -f "$tmp"

# --- missing file is a no-op success ---
: > "$SYSCTL_LOG"
if GPSD_DEFAULTS="/nonexistent/gpsd-$$" reconcile_gpsd_speed 115200 >/dev/null; then
    pass "missing defaults file is a no-op"
else
    fail "missing defaults file returned non-zero"
fi

# --- probe_receiver: no false negative on a streaming receiver ---
# Regression guard: a large ubxtool output (receiver already tracking) must not
# read as "no receiver" via an echo|grep-q SIGPIPE under pipefail.
ubxtool() { printf 'UBX-MON-VER:\n  swVersion ROM CORE 3.01\n'; seq 1 200000; }
if probe_receiver /dev/ttyAMA0 115200 >/dev/null; then
    pass "probe_receiver detects a streaming receiver (large output)"
else
    fail "probe_receiver false-negative on large output"
fi
ubxtool() { printf 'garbage\nno marker here\n'; }
if probe_receiver /dev/ttyAMA0 115200 >/dev/null; then
    fail "probe_receiver should report no receiver when MON-VER is absent"
else
    pass "probe_receiver reports no receiver when MON-VER is absent"
fi
unset -f ubxtool   # don't let the stub leak into later tests

# --- main() orchestration ---
# Stub discovery, per-device configuration, and reconcile so main()'s decisions
# (which baud gpsd is pointed at, and whether the unit fails) are observable.
# main() runs in this shell (not a subshell) so the recorded values stick.
get_uart_devices() { echo "/dev/ttyAMA0"; }
reconcile_gpsd_speed() { RECONCILE_CALLED=$((RECONCILE_CALLED + 1)); RECONCILE_BAUD="$1"; }
CONFIGURE_RC=0
CONFIGURE_BAUD=""
configure_device() { RECEIVER_BAUD="$CONFIGURE_BAUD"; return "$CONFIGURE_RC"; }
outfile=$(mktemp)

run_main() {
    RECONCILE_CALLED=0; RECONCILE_BAUD=""; MAIN_RC=0
    : > "$SYSCTL_LOG"
    main > "$outfile" 2>&1 || MAIN_RC=$?
    trap - EXIT   # main arms an EXIT trap; don't let it fire in the test shell
}

# --- port handover: gpsd owns the device while it runs ---
# Keyed on gpsd.service alone. The socket is active from early boot on every
# device and owns no hardware, so keying on it would churn gpsd every boot.
SYSCTL_ACTIVE=0   # gpsd.service reports active
CONFIGURE_RC=0; CONFIGURE_BAUD=115200
run_main
if grep -q "^systemctl stop gpsd.socket gpsd.service" "$SYSCTL_LOG"; then
    pass "stops gpsd and its socket when gpsd holds the port"
else
    fail "did not take the port from a running gpsd; log: [$(cat "$SYSCTL_LOG")]"
fi
if grep -q -- "--no-block start gpsd.socket gpsd.service" "$SYSCTL_LOG"; then
    pass "gives the port back without blocking on its own unit"
else
    fail "did not restart gpsd; log: [$(cat "$SYSCTL_LOG")]"
fi

# A crash part-way through must not leave the boat without gpsd.
: > "$SYSCTL_LOG"; SYSCTL_ACTIVE=0; GPSD_STOPPED=0
take_port >/dev/null
( trap release_port EXIT; false ) >/dev/null 2>&1 || true
GPSD_STOPPED=1 release_port >/dev/null
if grep -q -- "--no-block start" "$SYSCTL_LOG"; then
    pass "restores gpsd even when the run fails part-way"
else
    fail "gpsd left stopped after a failed run; log: [$(cat "$SYSCTL_LOG")]"
fi

# Boot path: gpsd.service inactive, so nothing should be stopped.
: > "$SYSCTL_LOG"; SYSCTL_ACTIVE=1; GPSD_STOPPED=0
CONFIGURE_RC=0; CONFIGURE_BAUD=115200
run_main
if grep -q "systemctl stop" "$SYSCTL_LOG"; then
    fail "stopped gpsd at boot when it was not holding the port"
else
    pass "leaves gpsd alone when it is not running"
fi
SYSCTL_ACTIVE=1

CONFIGURE_RC=0; CONFIGURE_BAUD=115200
run_main
if [ "$RECONCILE_CALLED" -eq 1 ] && [ "$RECONCILE_BAUD" = "115200" ] && [ "$MAIN_RC" -eq 0 ]; then
    pass "main reconciles to the target baud and succeeds after a configured receiver"
else
    fail "success path: reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD] rc=$MAIN_RC"
fi

CONFIGURE_RC=$RC_NO_RECEIVER; CONFIGURE_BAUD=""
run_main
if [ "$RECONCILE_CALLED" -eq 0 ] && [ "$MAIN_RC" -eq 0 ] && ! grep -q WARNING "$outfile"; then
    pass "main skips reconcile, stays quiet and succeeds when no receiver is present"
else
    fail "no-receiver path: reconcile=$RECONCILE_CALLED rc=$MAIN_RC out: [$(cat "$outfile")]"
fi

# The bricking guard: a receiver we detected but could not configure must leave
# gpsd at the receiver's real baud, so gpsd does not flood it at 115200.
CONFIGURE_RC=1; CONFIGURE_BAUD=9600
run_main
if [ "$RECONCILE_CALLED" -eq 1 ] && [ "$RECONCILE_BAUD" = "9600" ] && grep -q WARNING "$outfile"; then
    pass "main points gpsd at the detected baud when configuration fails"
else
    fail "failure path: reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD] out: [$(cat "$outfile")]"
fi

if [ "$MAIN_RC" -ne 0 ]; then
    pass "main exits non-zero when a detected receiver could not be configured"
else
    fail "main reported success despite a configuration failure"
fi

# Nothing to point gpsd at: a failure before the receiver's baud was established
# must leave the existing setting alone rather than guessing.
CONFIGURE_RC=1; CONFIGURE_BAUD=""
run_main
if [ "$RECONCILE_CALLED" -eq 0 ] && [ "$MAIN_RC" -ne 0 ]; then
    pass "main leaves gpsd untouched when no baud was established"
else
    fail "unknown-baud path: reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD] rc=$MAIN_RC"
fi

rm -f "$outfile" "$SYSCTL_LOG"

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
