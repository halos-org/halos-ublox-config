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
    GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed >/dev/null
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
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed >/dev/null
if grep -q '^DEVICES="/dev/ttyAMA0"$' "$tmp" && grep -q '^USBAUTO=true$' "$tmp"; then
    pass "preserves DEVICES and USBAUTO lines"
else
    fail "DEVICES/USBAUTO not preserved"
fi
rm -f "$tmp"

# --- reconcile restart branch (the actual self-heal mechanism) ---
tmp=$(mktemp); : > "$SYSCTL_LOG"; SYSCTL_ACTIVE=0
printf 'GPSD_OPTIONS="-n -s 9600"\n' > "$tmp"
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed >/dev/null
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
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed >/dev/null
if [ "$(cat "$tmp")" = "$before" ] && [ ! -s "$SYSCTL_LOG" ]; then
    pass "no file rewrite and no gpsd restart when already correct"
else
    fail "idempotent case rewrote the file or restarted gpsd; log: [$(cat "$SYSCTL_LOG")]"
fi
rm -f "$tmp"

# --- missing file is a no-op success ---
: > "$SYSCTL_LOG"
if GPSD_DEFAULTS="/nonexistent/gpsd-$$" reconcile_gpsd_speed >/dev/null; then
    pass "missing defaults file is a no-op"
else
    fail "missing defaults file returned non-zero"
fi

# --- main() orchestration ---
# Stub discovery, per-device configuration, and reconcile so main()'s decisions
# (reconcile only after a configured receiver; warn only on genuine failure) are
# observable. main() runs in this shell (not a subshell) so RECONCILE_CALLED sticks.
get_uart_devices() { echo "/dev/ttyAMA0"; }
reconcile_gpsd_speed() { RECONCILE_CALLED=$((RECONCILE_CALLED + 1)); }
CONFIGURE_RC=0
configure_device() { return "$CONFIGURE_RC"; }
outfile=$(mktemp)

RECONCILE_CALLED=0; CONFIGURE_RC=0
main > "$outfile" 2>&1 || true
if [ "$RECONCILE_CALLED" -eq 1 ]; then pass "main reconciles after a configured receiver"; else fail "main did not reconcile on success"; fi

RECONCILE_CALLED=0; CONFIGURE_RC=$RC_NO_RECEIVER
main > "$outfile" 2>&1 || true
if [ "$RECONCILE_CALLED" -eq 0 ] && ! grep -q WARNING "$outfile"; then
    pass "main skips reconcile and stays quiet when no receiver is present"
else
    fail "main mishandled the no-receiver path; out: [$(cat "$outfile")]"
fi

RECONCILE_CALLED=0; CONFIGURE_RC=1
main > "$outfile" 2>&1 || true
if [ "$RECONCILE_CALLED" -eq 0 ] && grep -q WARNING "$outfile"; then
    pass "main warns and skips reconcile on a configuration failure"
else
    fail "main mishandled the failure path; out: [$(cat "$outfile")]"
fi

rm -f "$outfile" "$SYSCTL_LOG"

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
