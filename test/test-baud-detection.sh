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
# What a 9600 receiver looks like when the port is opened at 115200.
GARBAGE=$'\xfe\xf8\x00\xc0\x1f\xe0$\x03\xff\xfc\x80\x7f\xf0\x01\xe0'

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
if has_valid_nmea "$GARBAGE"; then fail "reported NMEA in a pure-noise sample"; else pass "reports no NMEA in a pure-noise sample"; fi
if has_valid_nmea ""; then fail "reported NMEA in an empty sample"; else pass "reports no NMEA in an empty sample"; fi

# --- rx_disabled ---
if rx_disabled "$RXOFF"; then pass "detects the UART-RX-disabled notice"; else fail "missed the UART-RX-disabled notice"; fi
if rx_disabled "$GGA"; then fail "false positive on a normal sentence"; else pass "no false positive on a normal sentence"; fi

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
    fail "claimed detection when no baud yielded NMEA"
else
    pass "reports no receiver when no baud yields NMEA"
fi

if detect_at "$GARBAGE" "$RXOFF" && [ "$DETECTED_BAUD" = "9600" ] && [ "$DETECTED_RX_DISABLED" -eq 1 ]; then
    pass "flags a receiver whose UART RX is already disabled"
else
    fail "did not flag the RX-disabled receiver"
fi

# --- configure_device: nothing is transmitted before the baud is known ---
UBX_LOG=$(mktemp)
ubxtool() { printf '%s\n' "ubxtool $*" >> "$UBX_LOG"; printf 'UBX-MON-VER:\n  PROTVER=18\n'; }

# No receiver anywhere: the script must stay silent on the wire.
: > "$UBX_LOG"; SAMPLE_115200="$GARBAGE"; SAMPLE_9600="$GARBAGE"
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq "$RC_NO_RECEIVER" ] && [ ! -s "$UBX_LOG" ]; then
    pass "undetected receiver: returns no-receiver and transmits nothing"
else
    fail "undetected receiver: rc=$rc, transmitted: [$(cat "$UBX_LOG")]"
fi

# RX already disabled: reconfiguration is impossible, so do not add to the flood.
: > "$UBX_LOG"; SAMPLE_115200="$GARBAGE"; SAMPLE_9600="$RXOFF"
rc=0; configure_device /dev/ttyAMA0 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && [ ! -s "$UBX_LOG" ] && [ "$RECEIVER_BAUD" = "9600" ]; then
    pass "RX-disabled receiver: fails, transmits nothing, reports its real baud"
else
    fail "RX-disabled receiver: rc=$rc baud=[${RECEIVER_BAUD:-}] transmitted: [$(cat "$UBX_LOG")]"
fi

# Every transmission must name the detected baud, never the other candidate.
: > "$UBX_LOG"; SAMPLE_115200="$GARBAGE"; SAMPLE_9600="$RMC"
configure_device /dev/ttyAMA0 >/dev/null 2>&1 || true
if grep -q -- "-s 115200" "$UBX_LOG" && ! grep -q -- "-s 9600" "$UBX_LOG"; then
    fail "transmitted at 115200 to a receiver detected at 9600: [$(cat "$UBX_LOG")]"
else
    pass "addresses the receiver at its detected baud"
fi

rm -f "$READ_LOG" "$UBX_LOG"
unset -f read_port ubxtool

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
