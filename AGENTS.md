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
├── debian/                            # Debian packaging
└── .github/                           # CI/CD workflows
```

## How It Works

1. Systemd starts `configure-ublox-marine.service` before `gpsd.service`
2. Script reads UART devices from `/etc/default/gpsd`
3. For each `/dev/ttyAMA*` device, probes for a u-blox receiver at 115200 then 9600 bps
4. If found, configures rate, dynamic model, baud rate, and saves to BBR
5. gpsd then starts with the receiver at the expected 115200 bps

## Version Management

Use `./run bumpversion [patch|minor|major]`. Never edit VERSION or debian/changelog manually.

## CI/CD

Uses shared-workflows for Debian package building:
- **pr.yml**: PR checks (shellcheck, lintian)
- **main.yml**: Builds and publishes to apt.halos.fi unstable on push to main
- **release.yml**: Publishes to apt.halos.fi stable when release is published

## Related

- **halos-pi-gen**: Image builder that configures `/etc/default/gpsd` with HALPI2 UART device
- **halos-metapackages**: `halos-halpi2-marine` metapackage depends on this package
- **signalk-halpi**: Signal K plugin for HALPI2; depends on `halos-halpi2-marine`

Part of the [HaLOS](https://github.com/halos-org/halos) distribution.
