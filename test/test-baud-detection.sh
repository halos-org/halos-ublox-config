#!/bin/bash
# Unit tests for passive baud detection in configure-ublox-marine.sh.
#
# The property under test is that the script transmits nothing until it has
# established the receiver's current baud by listening. Transmitting UBX at a
# mismatched rate produces framing errors, and u-blox M8 firmware disables its
# UART receiver after more than 100 of them -- a state that only a full power
# removal clears, because HALPI2 has no GNSS reset line.
#
# read_port is the seam: it is the only function that touches the device, so
# stubbing it lets every path be driven from a canned serial sample.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../usr/libexec/halos/configure-ublox-marine.sh"

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

GGA='$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47'
RMC='$GNRMC,120000.00,A,5956.94000,N,02407.68000,E,0.5,180.0,070826,,,A*49'
RXOFF='$GNTXT,01,01,01,More than 100 frame errors, UART RX was disabled*70'
# What a 9600 receiver looks like when the port is opened at 115200. No NUL:
# bash drops those at different points on different libcs, so leaving one here
# makes the fixture mean something different per platform. Real samples never
# carry one this far anyway -- command substitution strips them. The high bytes
# are the load-bearing part: they are invalid UTF-8, which is what breaks
# line splitting under glibc.
GARBAGE=$'\xfe\xf8\xc0\x1f\xe0$\x03\xff\xfc\x80\x7f\xf0\x01\xe0'

# --- valid_nmea_line: checksum is the discriminator ---
if valid_nmea_line "$GGA"; then pass "accepts a sentence with a correct checksum"; else fail "rejected a valid GGA"; fi
if valid_nmea_line "${GGA%??}00"; then fail "accepted a wrong checksum"; else pass "rejects a sentence with a wrong checksum"; fi
if valid_nmea_line "\$GPGGA,123519,4807.038,N"; then fail "accepted a sentence with no checksum"; else pass "rejects a sentence with no checksum"; fi
if valid_nmea_line "$GARBAGE"; then fail "accepted garbage"; else pass "rejects line noise"; fi
if valid_nmea_line ""; then fail "accepted an empty line"; else pass "rejects an empty line"; fi
# A stray '$' in noise must not be enough on its own.
if valid_nmea_line '$GPGGA,4807.038*ZZ'; then fail "accepted a non-hex checksum"; else pass "rejects a non-hex checksum"; fi

# --- has_valid_nmea: finds a good sentence inside a noisy sample ---
if has_valid_nmea "$GARBAGE"$'\n'"$GGA"$'\n'"$GARBAGE"; then
    pass "finds a valid sentence surrounded by noise"
else
    fail "missed a valid sentence surrounded by noise"
fi
if has_valid_nmea "$(printf '%s\r\n' "$RMC")"; then pass "tolerates CRLF line endings"; else fail "CRLF sentence not recognised"; fi
# Regression: glibc's read consumes the newline after an invalid UTF-8 byte, so
# a sentence directly behind such noise used to vanish into the noise line. This
# is the shape the re-listen after a baud switch actually produces.
if has_valid_nmea "$(printf '\xfe\xf8%s\n%s\n' "" "$RMC")"; then
    pass "finds a sentence on the line after an invalid UTF-8 byte"
else
    fail "invalid UTF-8 byte swallowed the newline before a valid sentence"
fi
if has_valid_nmea "$GARBAGE"; then fail "reported NMEA in a pure-noise sample"; else pass "reports no NMEA in a pure-noise sample"; fi
if has_valid_nmea ""; then fail "reported NMEA in an empty sample"; else pass "reports no NMEA in an empty sample"; fi

# --- has_ubx_frames: a gpsd-driven receiver emits no NMEA at all ---
# Real capture from halpi.hurma showed 11801 bytes, 210 UBX sync headers and
# zero NMEA sentences: gpsd puts u-blox devices into binary mode and that
# survives a warm reboot, so NMEA alone is not a sufficient sign of life.
UBXFRAME=$'\xb5\x62\x01\x07\x5c\x00\x18\xa8'
if has_ubx_frames "$UBXFRAME$UBXFRAME$UBXFRAME"; then
    pass "detects a UBX binary stream"
else
    fail "missed a UBX binary stream"
fi
if has_ubx_frames "$UBXFRAME"; then
    fail "accepted a single sync header as a stream"
else
    pass "one stray sync header is not a stream"
fi
if has_ubx_frames "$GARBAGE"; then fail "UBX false positive on noise"; else pass "no UBX false positive on noise"; fi
# b5:62 must only match on a byte boundary: ab 56 2c hexdumps to "ab562c",
# which contains "b562" one nibble in.
STRADDLE=$'\xab\x56\x2c\xab\x56\x2c\xab\x56\x2c\xab\x56\x2c'
if has_ubx_frames "$STRADDLE"; then
    fail "matched a sync header straddling a byte boundary"
else
    pass "does not match b562 across a byte seam"
fi

# --- has_receiver_output: either protocol counts ---
if has_receiver_output "$GGA" && has_receiver_output "$UBXFRAME$UBXFRAME$UBXFRAME"; then
    pass "accepts either NMEA or UBX as a live receiver"
else
    fail "has_receiver_output rejected a live receiver"
fi
if has_receiver_output "$GARBAGE"; then fail "accepted noise as a receiver"; else pass "rejects noise as a receiver"; fi

# --- rx_disabled ---
if rx_disabled "$RXOFF"; then pass "detects the UART-RX-disabled notice"; else fail "missed the UART-RX-disabled notice"; fi
if rx_disabled "$GGA"; then fail "false positive on a normal sentence"; else pass "no false positive on a normal sentence"; fi
# The notice reaches us mid-stream, so noise ahead of it must not hide it.
if rx_disabled "$GARBAGE"$'\n'"$RXOFF"; then
    pass "detects the notice behind line noise"
else
    fail "line noise hid the UART-RX-disabled notice"
fi

# --- read_port: the only function that touches the device ---
# Not stubbed here. The property this package exists to guarantee lives in this
# function, and a stub cannot witness it: a mutation writing to the device inside
# read_port passed the entire suite before this test existed. Pointing it at a
# regular file lets the write be detected -- the file's contents must come back
# unchanged -- while stty and timeout are shadowed so no real tty is needed.
PORT_FILE=$(mktemp)
PORT_LOG=$(mktemp)
printf '%s\n' "$RMC" > "$PORT_FILE"
PORT_BEFORE=$(cat "$PORT_FILE")

stty() {
    printf 'stty %s\n' "$*" >> "$PORT_LOG"
    case "$*" in
        *speed*) printf '%s\n' "$STTY_SPEED" ;;   # the readback after sampling
    esac
}
timeout() {
    printf 'timeout %s\n' "$1" >> "$PORT_LOG"
    shift
    "$@"
}

STTY_SPEED=115200
sample=$(read_port "$PORT_FILE" 115200)

if [ "$(cat "$PORT_FILE")" = "$PORT_BEFORE" ]; then
    pass "read_port leaves the device untouched"
else
    fail "read_port WROTE to the device — the one thing it must never do"
fi
if [ "$(grep -c '^timeout' "$PORT_LOG")" -eq 2 ]; then
    pass "read_port drains before sampling"
else
    fail "expected a drain read and a sample read; got: [$(cat "$PORT_LOG")]"
fi
if [ "$(grep -c "^timeout $SNIFF_FLUSH\$" "$PORT_LOG")" -eq 1 ]; then
    pass "the drain uses the short flush window"
else
    fail "drain window wrong: [$(cat "$PORT_LOG")]"
fi
case "$sample" in
    *"$RMC"*) pass "read_port returns what the device emitted" ;;
    *) fail "sample did not contain the device's output: [$sample]" ;;
esac

# A rate that changed under us means the sample was framed by someone else's
# termios, so it must not be credited to the rate we asked for.
STTY_SPEED=9600
if read_port "$PORT_FILE" 115200 >/dev/null; then
    fail "accepted a sample after the port rate changed mid-listen"
else
    pass "rejects a sample whose port rate changed mid-listen"
fi
STTY_SPEED=115200
unset -f stty timeout
rm -f "$PORT_FILE" "$PORT_LOG"

# --- detect_baud: listens only, and reports where the receiver actually is ---
READ_LOG=$(mktemp)
# Canned port: $SAMPLE_115200 / $SAMPLE_9600 decide what each baud yields.
read_port() {
    printf '%s\n' "read_port $1 $2" >> "$READ_LOG"
    case "$2" in
        115200) printf '%s' "$SAMPLE_115200" ;;
        9600)   printf '%s' "$SAMPLE_9600" ;;
    esac
}

detect_at() {
    SAMPLE_115200="$1"; SAMPLE_9600="$2"
    : > "$READ_LOG"
    DETECTED_BAUD=""; DETECTED_RX_DISABLED=0
    detect_baud /dev/ttyAMA0 >/dev/null 2>&1
}

if detect_at "$GGA" "$GARBAGE" && [ "$DETECTED_BAUD" = "115200" ]; then
    pass "detects an already-configured receiver at 115200"
else
    fail "did not detect 115200 (got [${DETECTED_BAUD:-}])"
fi
if [ "$(wc -l < "$READ_LOG")" -eq 1 ]; then
    pass "stops listening once the receiver answers at the target baud"
else
    fail "kept probing after a successful detection: [$(cat "$READ_LOG")]"
fi

if detect_at "$GARBAGE" "$RMC" && [ "$DETECTED_BAUD" = "9600" ]; then
    pass "detects a factory receiver at 9600"
else
    fail "did not detect 9600 (got [${DETECTED_BAUD:-}])"
fi

if detect_at "$GARBAGE" "$GARBAGE"; then
    fail "claimed detection when no baud yielded receiver output"
else
    pass "reports no receiver when no baud yields output"
fi

# The regression this whole predicate exists for: a gpsd-driven receiver.
if detect_at "$UBXFRAME$UBXFRAME$UBXFRAME" "$GARBAGE" && [ "$DETECTED_BAUD" = "115200" ]; then
    pass "detects a UBX-only receiver that gpsd already switched to binary"
else
    fail "missed a UBX-only receiver (got [${DETECTED_BAUD:-}])"
fi

if detect_at "$GARBAGE" "$RXOFF" && [ "$DETECTED_BAUD" = "9600" ] && [ "$DETECTED_RX_DISABLED" -eq 1 ]; then
    pass "flags a receiver whose UART RX is already disabled"
else
    fail "did not flag the RX-disabled receiver"
fi

# Line number of the first matching call, empty if never called. grep returning
# 1 must not abort the suite, so it is guarded before the pipe.
order_of() { { grep -n -e "$1" "$UBX_LOG" || true; } | head -1 | cut -d: -f1; }

# --- configure_device against a simulated receiver ---
# One receiver with a real current rate, held in a file because probe_receiver
# runs ubxtool inside a command substitution and a subshell's variable writes are
# lost. Every ubxtool call is checked against that rate, so "transmitted at a
# rate the receiver is not running at" is caught mechanically instead of by an
# assertion someone has to remember to write. That is the whole safety property.
UBX_LOG=$(mktemp)
MISMATCH_LOG=$(mktemp)
RATE_FILE=$(mktemp)

arg_after() {   # arg_after <flag> <args...>
    local want="$1" prev=""; shift
    for a in "$@"; do
        [ "$prev" = "$want" ] && { printf '%s' "$a"; return 0; }
        prev="$a"
    done
    return 1
}

STUB_PROTVER=27          # deliberately != DEFAULT_PROTVER so the two are distinguishable
STUB_SILENT_BELOW_TARGET=0
STUB_FAIL_ON=""

ubxtool() {
    printf 'ubxtool %s\n' "$*" >> "$UBX_LOG"
    local addressed actual
    addressed=$(arg_after -s "$@") || addressed=""
    actual=$(cat "$RATE_FILE")

    if [ -n "$addressed" ] && [ "$addressed" != "$actual" ]; then
        printf 'addressed %s while receiver at %s: %s\n' "$addressed" "$actual" "$*" >> "$MISMATCH_LOG"
        return 0        # a receiver that cannot hear us simply says nothing
    fi
    if [ -n "$STUB_FAIL_ON" ]; then
        case "$*" in *"$STUB_FAIL_ON"*) return 1 ;; esac
    fi
    # A set command lands even when polls get no reply.
    local newrate
    newrate=$(arg_after -S "$@") && printf '%s' "$newrate" > "$RATE_FILE"

    if [ "$STUB_SILENT_BELOW_TARGET" -eq 1 ] && [ "$actual" != "$TARGET_BAUD" ]; then
        return 0        # oversubscribed link: command lands, reply is dropped
    fi
    printf 'UBX-MON-VER:\n  PROTVER=%s\n' "$STUB_PROTVER"
}

read_port() {
    printf 'read_port %s %s\n' "$1" "$2" >> "$READ_LOG"
    local actual; actual=$(cat "$RATE_FILE")
    if [ "$2" = "$actual" ]; then printf '%s' "$RECEIVER_SAMPLE"; else printf '%s' "$GARBAGE"; fi
}

start_receiver() {      # start_receiver <rate> [sample]
    printf '%s' "$1" > "$RATE_FILE"
    RECEIVER_SAMPLE="${2:-$RMC}"
    : > "$UBX_LOG"; : > "$MISMATCH_LOG"; : > "$READ_LOG"
    RECEIVER_BAUD=""
    STUB_FAIL_ON=""; STUB_SILENT_BELOW_TARGET=0
}

no_mismatch() {         # the safety property, asserted after every case
    if [ -s "$MISMATCH_LOG" ]; then
        fail "$1 — TRANSMITTED AT THE WRONG RATE: [$(cat "$MISMATCH_LOG")]"
    else
        pass "$1"
    fi
}

# Already at the target rate.
start_receiver "$TARGET_BAUD"
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "configured receiver: rc=$rc"
no_mismatch "never addresses the wrong rate on an already-configured receiver"
if grep -q -- "-P $STUB_PROTVER" "$UBX_LOG"; then
    pass "uses the protocol version the receiver reported"
else
    fail "did not use the reported protocol version: [$(cat "$UBX_LOG")]"
fi

# Factory rate: must move up, and every command must track the receiver.
start_receiver "$FACTORY_BAUD"
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "factory receiver: rc=$rc"
no_mismatch "never addresses the wrong rate while moving a 9600 receiver up"
if [ "$(cat "$RATE_FILE")" = "$TARGET_BAUD" ]; then
    pass "leaves the receiver at the target rate"
else
    fail "receiver ended at $(cat "$RATE_FILE")"
fi
baud_at=$(order_of "\-S $TARGET_BAUD"); rate_at=$(order_of "CFG-RATE")
if [ -n "$baud_at" ] && [ -n "$rate_at" ] && [ "$baud_at" -lt "$rate_at" ]; then
    pass "raises the rate before setting 10 Hz"
else
    fail "ordering wrong (baud@${baud_at:-none} rate@${rate_at:-none})"
fi

# Stranded at 9600 answering no polls: recover, still without a wrong-rate write.
start_receiver "$FACTORY_BAUD"; STUB_SILENT_BELOW_TARGET=1
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "stranded receiver: rc=$rc"
no_mismatch "never addresses the wrong rate recovering a silent 9600 receiver"
if grep -q -- "-P $DEFAULT_PROTVER" "$UBX_LOG" && grep -q -- "-P $STUB_PROTVER" "$UBX_LOG"; then
    pass "assumes the default protocol below target, then re-reads it above"
else
    fail "protocol fallback not exercised: [$(cat "$UBX_LOG")]"
fi

# Silent at the target rate is a real fault.
start_receiver "$TARGET_BAUD"; STUB_FAIL_ON="MON-VER"
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && ! grep -q "CFG-RATE" "$UBX_LOG"; then
    pass "fails on a receiver that is silent at the target rate"
else
    fail "did not fail on a silent target-rate receiver (rc=$rc): [$(cat "$UBX_LOG")]"
fi

# Each ubxtool failure branch must abort the run and stop later steps.
for step in "-S $TARGET_BAUD" "CFG-RATE" "MODEL" "SAVE"; do
    start_receiver "$FACTORY_BAUD"; STUB_FAIL_ON="$step"
    rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "aborts when $step fails"
    else
        fail "$step failure did not abort (rc=$rc): [$(cat "$UBX_LOG")]"
    fi
    no_mismatch "no wrong-rate write when $step fails"
done

# A receiver that vanishes after the switch: its rate is unknown, so nothing may
# be asserted about it. Guessing the pre-switch rate would point gpsd at the one
# rate the receiver is known to have left.
start_receiver "$FACTORY_BAUD"
_rp_saved=$(declare -f read_port)
read_port() {
    printf 'read_port %s %s\n' "$1" "$2" >> "$READ_LOG"
    # Answers at 9600 until the switch lands, then nothing at either rate.
    if [ "$(cat "$RATE_FILE")" = "$FACTORY_BAUD" ] && [ "$2" = "$FACTORY_BAUD" ]; then
        printf '%s' "$RMC"
    else
        printf '%s' "$GARBAGE"
    fi
}
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ -z "$RECEIVER_BAUD" ]; then
    pass "reports an unknown rate when the receiver vanishes after the switch"
else
    fail "guessed a rate after the switch (rc=$rc baud=[${RECEIVER_BAUD:-}])"
fi
eval "$_rp_saved"

# --- silence: absence unless a fault is evidenced ---
# The port has to exist for these, because a missing one is itself one of the
# faults under test. A regular file stands in for the tty: nothing here reads it,
# read_port is stubbed, and only the path's existence is inspected.
PORT_NODE=$(mktemp)
HOLDERS=""
_ph_saved=$(declare -f port_holders)
port_holders() { printf '%s' "$HOLDERS"; }

# The reason this issue exists: /etc/default/gpsd lists the port on every HALPI2
# marine image whether or not a module is fitted, so silence on an idle port is a
# hardware configuration and must not fail the unit.
start_receiver 4800    # neither candidate rate
rc=0; configure_device "$PORT_NODE" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq "$NO_RECEIVER_RC" ] && [ ! -s "$UBX_LOG" ] && [ -z "$RECEIVER_BAUD" ]; then
    pass "an idle, unheld port reports no receiver and transmits nothing"
else
    fail "idle port: rc=$rc transmitted [$(cat "$UBX_LOG")]"
fi
if [ "$(grep -c '^read_port' "$READ_LOG")" -eq $((DETECT_RETRIES * 2)) ]; then
    pass "retries detection before declaring a device silent"
else
    fail "expected $((DETECT_RETRIES * 2)) listens, got: [$(cat "$READ_LOG")]"
fi

# Something else eating the receiver's bytes looks exactly like an empty port,
# and was one of the two field failures that used to exit 0.
start_receiver 4800; HOLDERS="gpsd[431]"
rc=0; out=$(configure_device "$PORT_NODE" 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
    pass "a held port fails the unit"
else
    fail "held port did not fail (rc=$rc)"
fi
case "$out" in
    *"gpsd[431]"*) pass "names what is holding the port" ;;
    *) fail "holder not named: [$out]" ;;
esac
HOLDERS=""

# A port named in DEVICES that does not exist is a broken image, not a missing
# module: gpsd cannot open it either.
start_receiver 4800
rc=0; configure_device "$PORT_NODE.absent" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then
    pass "a port that does not exist fails the unit"
else
    fail "missing port did not fail (rc=$rc)"
fi

rm -f "$READ_LOG" "$UBX_LOG" "$MISMATCH_LOG" "$RATE_FILE" "$PORT_NODE"
unset -f read_port ubxtool arg_after
eval "$_ph_saved"

# --- port_holders: reads the real /proc, so only where there is one ---
if [ -d /proc/self/fd ]; then
    HELD_FILE=$(mktemp)
    # A held descriptor, kept open by a process that is not this one.
    sleep 30 < "$HELD_FILE" &
    holder_pid=$!
    # The kernel resolves symlinks in the temp path, and readlink reports the
    # resolved target, so compare against the same form.
    held_real=$(readlink "/proc/$holder_pid/fd/0" 2>/dev/null || printf '%s' "$HELD_FILE")
    found=$(port_holders "$held_real")
    case "$found" in
        *"sleep[$holder_pid]"*) pass "port_holders names the process holding a device" ;;
        *) fail "port_holders missed the holder: [$found]" ;;
    esac
    if [ -z "$(port_holders "$held_real.unheld")" ]; then
        pass "port_holders reports nothing for a path no one has open"
    else
        fail "port_holders invented a holder"
    fi
    # The script reads the port itself; counting its own shell would make every
    # silent port look held and reinstate the failure this change removes.
    exec 9< "$HELD_FILE"
    if [ -z "$(port_holders "$held_real" | grep -o "\[$$\]" || true)" ]; then
        pass "port_holders excludes the shell doing the reading"
    else
        fail "port_holders counted our own descriptor"
    fi
    exec 9<&-
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    rm -f "$HELD_FILE"
else
    echo "skip - port_holders tests need /proc (not this platform)"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
