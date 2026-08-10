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
SYSCTL_ACTIVE=1   # legacy single-unit knob, used by the reconcile tests below
SERVICE_ACTIVE=1  # is-active exit codes per unit: 0 = active, 1 = inactive
SOCKET_ACTIVE=1

# Recording stub. `is-active` answers per unit, not with one global value: the
# whole point of keying take_port on gpsd.service is that the socket is active
# on every boot, and a unit-blind stub cannot tell the two apart.
systemctl() {
    printf '%s\n' "systemctl $*" >> "$SYSCTL_LOG"
    case "$1" in
        is-active)
            case "$*" in
                *gpsd.service*) return "$SERVICE_ACTIVE" ;;
                *gpsd.socket*)  return "$SOCKET_ACTIVE" ;;
            esac
            return "$SYSCTL_ACTIVE" ;;
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
tmp=$(mktemp); : > "$SYSCTL_LOG"; SYSCTL_ACTIVE=0; SERVICE_ACTIVE=0
printf 'GPSD_OPTIONS="-n -s 9600"\n' > "$tmp"
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed 115200 >/dev/null
if grep -q 'try-restart gpsd.service' "$SYSCTL_LOG" && grep -q -- '--no-block' "$SYSCTL_LOG"; then
    pass "restarts gpsd non-blocking when active and the file changed"
else
    fail "expected a non-blocking try-restart; log: [$(cat "$SYSCTL_LOG")]"
fi
rm -f "$tmp"

# --- idempotent: no rewrite and no restart when already correct ---
tmp=$(mktemp); : > "$SYSCTL_LOG"; SYSCTL_ACTIVE=0; SERVICE_ACTIVE=0
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

# --- reconcile replaces the file rather than truncating it ---
# The target names the device gpsd opens and the devices this script looks for,
# so a half-written copy costs the GPS permanently and silently. A failed write
# must therefore leave the original intact, not a truncated remnant.
tmp=$(mktemp); : > "$SYSCTL_LOG"
printf 'DEVICES="/dev/ttyAMA0"\nGPSD_OPTIONS="-n -s 9600"\n' > "$tmp"
chmod 0644 "$tmp"
before=$(cat "$tmp")
GPSD_DEFAULTS="$tmp" reconcile_gpsd_speed 115200 >/dev/null
mode_after=$(ls -l "$tmp" | cut -c1-10)
if [ "$mode_after" = "-rw-r--r--" ]; then
    pass "replacement keeps the original file mode"
else
    fail "mode changed to $mode_after"
fi

# Make the rename fail by making the directory unwritable; the original must survive.
dir=$(mktemp -d); target="$dir/gpsd"
printf '%s\n' "$before" > "$target"
chmod 0500 "$dir"
GPSD_DEFAULTS="$target" reconcile_gpsd_speed 115200 >/dev/null 2>&1 || true
if [ "$(cat "$target")" = "$before" ]; then
    pass "a failed write leaves the original file intact"
else
    fail "failed write damaged the file: [$(cat "$target")]"
fi
chmod 0700 "$dir"; rm -rf "$dir" "$tmp"

# --- main() orchestration ---
# Stub discovery, per-device configuration, and reconcile so main()'s decisions
# (which baud gpsd is pointed at, and whether the unit fails) are observable.
# main() runs in this shell (not a subshell) so the recorded values stick.
DEVICE_LIST="/dev/ttyAMA0"
get_uart_devices() { printf '%s\n' $DEVICE_LIST; }
# Logged to the same file as systemctl so the ORDER between reconciling the
# speed and restarting gpsd is observable, not just the fact that both happened.
# gpsd must never come back before the file it reads has been corrected.
reconcile_gpsd_speed() {
    RECONCILE_CALLED=$((RECONCILE_CALLED + 1)); RECONCILE_BAUD="$1"
    printf 'reconcile %s\n' "$1" >> "$SYSCTL_LOG"
}
# Per-device outcome, keyed on the device name: "<rc>:<baud>".
declare -A DEVICE_RESULT=()
configure_device() {
    local spec="${DEVICE_RESULT[$1]:-0:115200}"
    RECEIVER_BAUD="${spec#*:}"
    return "${spec%%:*}"
}
outfile=$(mktemp)

run_main() {
    RECONCILE_CALLED=0; RECONCILE_BAUD=""; MAIN_RC=0
    : > "$SYSCTL_LOG"
    main > "$outfile" 2>&1 || MAIN_RC=$?
    trap - EXIT   # main arms an EXIT trap; don't let it fire in the test shell
}

SERVICE_ACTIVE=1; SOCKET_ACTIVE=1   # exit codes: 0 = active

DEVICE_LIST="/dev/ttyAMA0"; DEVICE_RESULT=([/dev/ttyAMA0]="0:115200")
run_main
if [ "$RECONCILE_CALLED" -eq 1 ] && [ "$RECONCILE_BAUD" = "115200" ] && [ "$MAIN_RC" -eq 0 ]; then
    pass "main reconciles to the target baud and succeeds after a configured receiver"
else
    fail "success path: reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD] rc=$MAIN_RC"
fi

# The bricking guard: a receiver we detected but could not configure must leave
# gpsd at the receiver's real baud, so gpsd does not flood it at 115200.
DEVICE_RESULT=([/dev/ttyAMA0]="1:9600")
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
DEVICE_RESULT=([/dev/ttyAMA0]="1:")
run_main
if [ "$RECONCILE_CALLED" -eq 0 ] && [ "$MAIN_RC" -ne 0 ]; then
    pass "main leaves gpsd untouched when no baud was established"
else
    fail "unknown-baud path: reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD] rc=$MAIN_RC"
fi

# A board with no module fitted must not sit degraded for its whole life. The
# port is listed in /etc/default/gpsd on every HALPI2 marine image regardless of
# what is soldered to it, so its presence there proves nothing.
DEVICE_RESULT=([/dev/ttyAMA0]="$NO_RECEIVER_RC:")
run_main
if [ "$MAIN_RC" -eq 0 ] && [ "$RECONCILE_CALLED" -eq 0 ]; then
    pass "main succeeds and leaves gpsd alone when no receiver is fitted"
else
    fail "absent receiver: rc=$MAIN_RC reconcile=$RECONCILE_CALLED out: [$(cat "$outfile")]"
fi
if grep -q "No GNSS receiver present on 1" "$outfile"; then
    pass "main records the absence in the journal"
else
    fail "absence not reported: [$(cat "$outfile")]"
fi

# Absence is counted separately from failure, so it cannot swallow one.
DEVICE_LIST="/dev/ttyAMA0 /dev/ttyAMA1"
DEVICE_RESULT=([/dev/ttyAMA0]="$NO_RECEIVER_RC:" [/dev/ttyAMA1]="1:115200")
run_main
if [ "$MAIN_RC" -ne 0 ]; then
    pass "an absent receiver does not mask a failure on another device"
else
    fail "absence masked a failure: rc=$MAIN_RC out: [$(cat "$outfile")]"
fi

# An empty port alongside a working one must not cost the working one its baud:
# the absent device establishes no rate, so there is nothing for it to disagree
# with and gpsd still gets pointed at the receiver that is there.
DEVICE_RESULT=([/dev/ttyAMA0]="$NO_RECEIVER_RC:" [/dev/ttyAMA1]="0:115200")
run_main
if [ "$MAIN_RC" -eq 0 ] && [ "$RECONCILE_CALLED" -eq 1 ] && [ "$RECONCILE_BAUD" = "115200" ]; then
    pass "an empty port does not stop gpsd being pointed at a working receiver"
else
    fail "absent+working: rc=$MAIN_RC reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD]"
fi
DEVICE_LIST="/dev/ttyAMA0"; DEVICE_RESULT=([/dev/ttyAMA0]="0:115200")

# Ordering: gpsd's config must be corrected before gpsd is allowed back.
SERVICE_ACTIVE=0
DEVICE_RESULT=([/dev/ttyAMA0]="0:115200")
run_main
rec_at=$({ grep -n '^reconcile' "$SYSCTL_LOG" || true; } | head -1 | cut -d: -f1)
start_at=$({ grep -n -- '--no-block start' "$SYSCTL_LOG" || true; } | head -1 | cut -d: -f1)
if [ -n "$rec_at" ] && [ -n "$start_at" ] && [ "$rec_at" -lt "$start_at" ]; then
    pass "reconciles the speed before letting gpsd back on the port"
else
    fail "ordering wrong (reconcile@${rec_at:-none} start@${start_at:-none})"
fi
SERVICE_ACTIVE=1

# Two receivers at different rates cannot both be served by one global -s, so
# neither may be written: whichever is chosen points gpsd at a rate the other
# is not using, which is the flood this package exists to prevent.
DEVICE_LIST="/dev/ttyAMA0 /dev/ttyAMA1"
DEVICE_RESULT=([/dev/ttyAMA0]="0:115200" [/dev/ttyAMA1]="1:9600")
run_main
if [ "$RECONCILE_CALLED" -eq 0 ] && [ "$MAIN_RC" -ne 0 ]; then
    pass "leaves gpsd untouched when two devices disagree on rate"
else
    fail "wrote a global speed for disagreeing devices: baud=[$RECONCILE_BAUD] rc=$MAIN_RC"
fi
# Order must not decide the outcome.
DEVICE_RESULT=([/dev/ttyAMA0]="1:9600" [/dev/ttyAMA1]="0:115200")
run_main
if [ "$RECONCILE_CALLED" -eq 0 ]; then
    pass "device order does not decide which rate gpsd is given"
else
    fail "reverse order wrote [$RECONCILE_BAUD]"
fi
# Agreeing devices are fine.
DEVICE_RESULT=([/dev/ttyAMA0]="0:115200" [/dev/ttyAMA1]="0:115200")
run_main
if [ "$RECONCILE_CALLED" -eq 1 ] && [ "$RECONCILE_BAUD" = "115200" ] && [ "$MAIN_RC" -eq 0 ]; then
    pass "writes the shared rate when every device agrees"
else
    fail "agreeing devices: reconcile=$RECONCILE_CALLED baud=[$RECONCILE_BAUD] rc=$MAIN_RC"
fi
DEVICE_LIST="/dev/ttyAMA0"; DEVICE_RESULT=([/dev/ttyAMA0]="0:115200")

# --- port handover: gpsd owns the device while it runs ---
# Keyed on gpsd.service alone. The socket is active from early boot on every
# device and owns no hardware, so keying on it would churn gpsd every boot.
SERVICE_ACTIVE=0; SOCKET_ACTIVE=0
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

# Boot shape: the socket is up but the service is not. Nothing may be stopped,
# or every boot on every device churns gpsd for no reason.
SERVICE_ACTIVE=1; SOCKET_ACTIVE=0
run_main
if grep -q "systemctl stop" "$SYSCTL_LOG"; then
    fail "stopped gpsd at boot when only its socket was active"
else
    pass "leaves gpsd alone when only the socket is active"
fi

# The restore must survive a run that dies part-way. main's own EXIT trap is the
# only thing that can do it, so the failure has to happen inside a subshell that
# main controls -- calling release_port by hand here would prove nothing.
SERVICE_ACTIVE=0; SOCKET_ACTIVE=0
: > "$SYSCTL_LOG"; GPSD_STOPPED=0
( configure_device() { exit 9; }; main ) >/dev/null 2>&1 || true
if grep -q -- "--no-block start gpsd.socket gpsd.service" "$SYSCTL_LOG"; then
    pass "restores gpsd when the run dies part-way"
else
    fail "gpsd left stopped after a fatal error; log: [$(cat "$SYSCTL_LOG")]"
fi

# A stop that reports failure has usually already taken one unit down, so the
# restore must be armed before the stop, not after it.
: > "$SYSCTL_LOG"; GPSD_STOPPED=0
systemctl() {
    printf '%s\n' "systemctl $*" >> "$SYSCTL_LOG"
    case "$1" in
        is-active) case "$*" in *gpsd.service*) return "$SERVICE_ACTIVE";; *gpsd.socket*) return "$SOCKET_ACTIVE";; esac ;;
        stop) return 1 ;;
    esac
    return 0
}
take_port >/dev/null 2>&1 || true
release_port >/dev/null 2>&1 || true
if grep -q -- "--no-block start" "$SYSCTL_LOG"; then
    pass "restores gpsd even when the stop reports failure"
else
    fail "a failed stop left gpsd down; log: [$(cat "$SYSCTL_LOG")]"
fi
GPSD_STOPPED=0

rm -f "$outfile" "$SYSCTL_LOG"

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
