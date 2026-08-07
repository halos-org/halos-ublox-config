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
3. For each `/dev/ttyAMA*` device, detects the current baud by **listening only** — 115200 then 9600, accepting the rate that yields a checksum-valid NMEA sentence
4. If found, configures rate, dynamic model, baud rate, and saves to BBR, addressing the receiver at the detected rate throughout
5. Reconciles `/etc/default/gpsd` so gpsd's `-s` speed matches where the receiver actually is, restarting gpsd if it is already running
6. gpsd then reads the receiver at a baud that matches it

## Never transmit at an unverified baud

This is the constraint the script is built around, not a style preference. UBX sent at the wrong rate produces framing errors, and M8 firmware disables its UART receiver after more than 100 of them. The module keeps transmitting NMEA — so it reads as healthy — while accepting no configuration, and HALPI2 has no GNSS reset line, so a warm reboot does not clear it. Recovery needs power physically removed.

Consequences for anyone editing this:

- **Baud discovery must stay read-only.** `read_port` is the only function that touches the device before the rate is known, and it never writes. Reordering the candidate bauds does not help: the hazard is symmetric, so probing 9600 first just moves the risk onto every boot of an already-configured unit.
- **Checksum validation is the discriminator.** `valid_nmea_line` verifies the NMEA checksum because a mismatched baud produces noise that can contain a stray `$`. Loosening it to a substring match would accept noise as a valid rate and then transmit into it.
- **gpsd is a second transmitter.** Pointed at a receiver still running at 9600, gpsd's own probes at 115200 trip the same protection. `reconcile_gpsd_speed` takes the receiver's actual baud, so a device that failed to reach 115200 is left working-but-degraded rather than bricked.
- **A detected-but-unconfigurable receiver must fail the unit.** Returning 0 there is what hid this in the field for months: systemd reported `0/SUCCESS` while the GPS chain was dead. `Before=gpsd.service` is ordering only, so failing does not stop gpsd from starting.

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
