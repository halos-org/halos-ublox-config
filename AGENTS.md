# halos-ublox-config - Agent Instructions

## Repository Purpose

Debian package that auto-configures u-blox GNSS receivers for marine use on every boot. Runs as a systemd oneshot service before gpsd, ensuring the receiver is set to 115200 bps, 10 Hz update rate, and Sea dynamic model.

## Background

ROM-based u-blox modules (such as the MAX-M8Q on HALPI2) have no flash memory. Configuration saved via UBX-CFG-CFG only persists in Battery-Backed RAM (BBR), which is lost when V_BCKP power is interrupted. This package reconfigures the receiver on every boot to ensure correct operation.

## For Agentic Coding: Use the HaLOS Workspace

Work from the halos workspace repository for full context across all HaLOS repositories.

## Quick Start

```bash
./run lint         # Run shellcheck
./run test         # Run shellcheck + unit tests
./run build-deb    # Build .deb package
./run clean        # Remove build artifacts
```

## Structure

```
halos-ublox-config/
├── usr/libexec/halos/
│   └── configure-ublox-marine.sh     # Main configuration script
├── lib/systemd/system/
│   └── configure-ublox-marine.service # Systemd service unit
├── test/                              # Unit tests (shellcheck-clean bash)
├── debian/                            # Debian packaging
└── .github/                           # CI/CD workflows
```

## How It Works

1. Systemd starts `configure-ublox-marine.service` before `gpsd.service`
2. Script reads UART devices from `/etc/default/gpsd`
3. For each `/dev/ttyAMA*` device, detects the current rate by **listening only** — 115200 then 9600, accepting the rate that yields either a checksum-valid NMEA sentence or a UBX binary stream
4. If found, raises the receiver to 115200 first, then sets update rate and dynamic model at that rate and saves to BBR, addressing the receiver at its current rate throughout
5. Reconciles `/etc/default/gpsd` so gpsd's `-s` speed matches where the receiver actually is, restarting gpsd if it is already running
6. gpsd then reads the receiver at a baud that matches it

## Never transmit at an unverified baud

This is the constraint the script is built around, but not for the reason it was originally written down. UBX sent at the wrong rate produces framing errors, and past 100 of them in a second the receiver stops listening — for the rest of that second. From UBX-13003221 R28, the section the `$GNTXT` notice comes from:

> As of Protocol version 18+, the UART RX interface will be disabled when more than 100 frame errors are detected during a one-second period. […] The error message appears when the UART RX interface is re-enabled at the end of the one-second period.

It is a rate limit that clears itself, and `More than 100 frame errors, UART RX was disabled` is the receiver saying RX is **back**. Frame errors cost time, not hardware, and no amount of them requires a power cycle to recover from.

What is real is next door: `SAVE` writes the baud into BBR, HALPI2 holds BBR up on V_BCKP, and a rate saved there survives a warm reboot. A receiver left at a rate nothing on the host uses looks dead until power is physically removed — the observation that produced the wrong explanation. Blind transmission is what strands a receiver; the frame errors are only noise along the way.

So detection stays read-only because listening needs no guess about the rate and costs nothing, not because a wrong-rate write destroys hardware. Keep the design, and do not restate its rationale as damage to the module: that version of the story has been checked against the spec and is false.

Consequences for anyone editing this:

- **Baud discovery must stay read-only.** `read_port` is the only function that touches the device before the rate is known, and it never writes. Reordering the candidate bauds does not help: the hazard is symmetric, so probing 9600 first just moves the risk onto every boot of an already-configured unit.
- **Checksum validation is the discriminator.** `valid_nmea_line` verifies the NMEA checksum because a mismatched baud produces noise that can contain a stray `$`. Loosening it to a substring match would accept noise as a valid rate and then transmit into it.
- **gpsd cannot read a receiver it is pointed at with the wrong speed.** It sees framing garbage, finds no packets, and its own probes go out at a rate the receiver discards. `reconcile_gpsd_speed` takes the receiver's actual baud, so a device that failed to reach 115200 is left readable rather than silent.
- **A detected-but-unconfigurable receiver must fail the unit.** Returning 0 there is what hid this in the field for months: systemd reported `0/SUCCESS` while the GPS chain was dead. `Before=gpsd.service` is ordering only, so failing does not stop gpsd from starting.

## What a live receiver actually sounds like

What only showed up against real hardware. Each of these made detection silently report "no receiver", which used to be a success exit:

- **NMEA is not the only protocol.** gpsd switches u-blox devices into UBX binary mode when it takes over, and that survives a warm reboot. A capture from a device in normal service held 11801 bytes, 210 UBX frame headers and zero NMEA sentences. `has_receiver_output` accepts either; do not narrow it back to NMEA.
- **The tty queue outlives a baud change.** Bytes already queued were framed by the UART at the previous rate, and `stty` neither re-frames nor discards them. Sampling immediately after the switch reads the *old* rate's valid output and accepts the new rate as correct — measured as an 11416-byte "9600" sample, four times what 9600 can carry in the window. `read_port` drains and discards before sampling; removing that reintroduces a false positive that picks the wrong baud.
- **The baud is raised before anything else is set.** 10 Hz on a 9600 link oversubscribes it: the receiver generates more than the line carries, its transmit buffer overflows, and poll replies get dropped — while set commands, travelling the other way, still land. Measured on halpi.hurma: no MON-VER reply even at a 12 s wait, yet a baud command sent at the same moment took effect. Setting the rate first and raising the baud after strands the receiver there if the second step fails, and it then looks to every later boot like a receiver that answers nothing. Do not reorder these back.

  One unanswered poll is not evidence of anything, at any rate. Against a live 10 Hz MAX-M8Q at 115200, with the link at about half capacity, 7 of 90 `MON-VER` polls got no answer — so aborting on the first miss threw away the whole configuration on roughly one run in twelve of perfectly good hardware, on every warm reboot and every package upgrade. Waiting longer is not the answer: the receiver drops the reply rather than delaying it, so it never arrives late. (Measured 1/30 lost at `-w 2` against 3/30 at `-w 4`, which is too small a sample to separate from noise on its own; the mechanism is what carries this, not the numbers.)

  `probe_protver` retries instead, and `configure_device` polls in two rounds. Exhausting both is what fails the unit, because six consecutive misses at an 8% drop rate is not luck — a receiver that answers nothing will not accept `CFG-RATE` either, and reporting success over it is the `0/SUCCESS`-while-dead shape this file warns about. Exhausting only the first round is tolerated, and `DEFAULT_PROTVER` covers the gap: the poll's sole product is the protocol version, and M8 reports the 18 that is already the default.
- **Silence is an absence only once every fault that produces it is ruled out.** `DEVICES` was once read as an assertion that a receiver exists, and it is not one: pi-gen writes `/dev/ttyAMA0` into `/etc/default/gpsd` for every HALPI2 marine image, module fitted or not, and that port is the SoC UART, which is there either way. Failing on silence therefore left every board without the module permanently `degraded`, with nothing an owner could do about it. So each fault is now evidenced directly instead of inferred: the port does not exist; `port_usable` cannot open it; `port_holders` finds something holding it, either now or when the run began; `read_port` reports a rate changed under it mid-listen; or `port_byte_count` finds traffic on a port that parsed at neither candidate rate. Only what survives all of those exits `NO_RECEIVER_RC`, which `main` counts separately so it can neither fail the unit nor mask a real failure on another device.

  The traffic check is what keeps the promise the rest of this file makes — a receiver that is present but mute must never pass as absent. An unfitted UART reads **exactly zero bytes** (measured, ten windows at both candidate rates), so any traffic at all means something is transmitting: a receiver at a rate outside {115200, 9600}, or a HAT that is not u-blox. `port_byte_count` counts the raw stream rather than reusing `read_port`'s sample, because that sample returns through a command substitution, which drops NULs — and a receiver read at the wrong rate produces mostly those, so a talking port arrives looking empty. Its exit status is not about the count either: `timeout` kills `cat` with 124 and `pipefail` carries that out, so `n=$(port_byte_count …) || n=0` silently zeroes every real measurement.

  Detection still retries before concluding, and gpsd is still left at whatever rate it already had — guessing one is what floods a receiver.
- **gpsd owns the device while it runs.** A sample taken underneath it is empty. Boot is safe because of `Before=gpsd.service`, but the apt-upgrade path restarts this unit on a live system, and on a marine device Signal K holds a client connection that keeps re-activating gpsd through its socket. `take_port` stops both units, keyed on `gpsd.service` — keying on the socket instead would stop and churn gpsd on every boot for nothing, since the socket is active from early boot and owns no hardware.

## Version Management

Use `./run bumpversion [patch|minor|major]`. Never edit VERSION or debian/changelog manually.

## CI/CD

Uses shared-workflows for Debian package building:
- **pr.yml**: PR checks (shellcheck, unit tests, lintian)
- **main.yml**: Builds and publishes to apt.halos.fi unstable on push to main
- **release.yml**: Publishes to apt.halos.fi stable when release is published

## Related

- **halos-pi-gen**: Image builder that configures `/etc/default/gpsd` with HALPI2 UART device
- **halos-metapackages**: `halos-halpi2-marine` metapackage depends on this package
- **signalk-halpi**: Signal K plugin for HALPI2; depends on `halos-halpi2-marine`

Part of the [HaLOS](https://github.com/halos-org/halos) distribution.
