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

This is the constraint the script is built around, not a style preference. UBX sent at the wrong rate produces framing errors, and M8 firmware disables its UART receiver after more than 100 of them. The module keeps transmitting NMEA — so it reads as healthy — while accepting no configuration, and HALPI2 has no GNSS reset line, so a warm reboot does not clear it. Recovery needs power physically removed.

Consequences for anyone editing this:

- **Baud discovery must stay read-only.** `read_port` is the only function that touches the device before the rate is known, and it never writes. Reordering the candidate bauds does not help: the hazard is symmetric, so probing 9600 first just moves the risk onto every boot of an already-configured unit.
- **Checksum validation is the discriminator.** `valid_nmea_line` verifies the NMEA checksum because a mismatched baud produces noise that can contain a stray `$`. Loosening it to a substring match would accept noise as a valid rate and then transmit into it.
- **gpsd is a second transmitter.** Pointed at a receiver still running at 9600, gpsd's own probes at 115200 trip the same protection. `reconcile_gpsd_speed` takes the receiver's actual baud, so a device that failed to reach 115200 is left working-but-degraded rather than bricked.
- **A detected-but-unconfigurable receiver must fail the unit.** Returning 0 there is what hid this in the field for months: systemd reported `0/SUCCESS` while the GPS chain was dead. `Before=gpsd.service` is ordering only, so failing does not stop gpsd from starting.

## What a live receiver actually sounds like

What only showed up against real hardware. Each of these made detection silently report "no receiver", which used to be a success exit:

- **NMEA is not the only protocol.** gpsd switches u-blox devices into UBX binary mode when it takes over, and that survives a warm reboot. A capture from a device in normal service held 11801 bytes, 210 UBX frame headers and zero NMEA sentences. `has_receiver_output` accepts either; do not narrow it back to NMEA.
- **The tty queue outlives a baud change.** Bytes already queued were framed by the UART at the previous rate, and `stty` neither re-frames nor discards them. Sampling immediately after the switch reads the *old* rate's valid output and accepts the new rate as correct — measured as an 11416-byte "9600" sample, four times what 9600 can carry in the window. `read_port` drains and discards before sampling; removing that reintroduces a false positive that picks the wrong baud.
- **The baud is raised before anything else is set.** 10 Hz on a 9600 link oversubscribes it: the receiver generates more than the line carries, its transmit buffer overflows, and poll replies get dropped — while set commands, travelling the other way, still land. Measured on halpi.hurma: no MON-VER reply even at a 12 s wait, yet a baud command sent at the same moment took effect. Setting the rate first and raising the baud after strands the receiver there if the second step fails, and it then looks to every later boot like a receiver that answers nothing. Do not reorder these back. It also follows that a silent receiver *below* the target rate is not a fault to abort on — it is probably one this script stranded — while silence *at* the target rate is, since there is no bandwidth excuse.
- **Silence is an absence unless a fault is evidenced.** `DEVICES` was once read as an assertion that a receiver exists, and it is not one: pi-gen writes `/dev/ttyAMA0` into `/etc/default/gpsd` for every HALPI2 marine image, module fitted or not, and that port is the SoC UART, which is there either way. Failing on silence therefore left every board without the module permanently `degraded`, with nothing an owner could do about it. The two field failures that motivated the old rule are now caught where they happen rather than inferred from silence — gpsd holding the port by `take_port`, a UBX-only stream by `has_ubx_frames` — and what remains of it is two direct checks: `port_holders` fails the unit when something else has the device open, and a non-existent port fails it too. Everything else exits with `NO_RECEIVER_RC`, which `main` counts separately so it can neither fail the unit nor mask a real failure on another device. Detection still retries before concluding, and gpsd is still left at whatever rate it already had — guessing one is what floods a receiver.
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
