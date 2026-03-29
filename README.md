# halos-ublox-config

Debian package that auto-configures u-blox GNSS receivers for marine use on every boot.

## Why every boot?

ROM-based u-blox modules (such as the MAX-M8Q on HALPI2) have no flash memory. Configuration is saved to Battery-Backed RAM (BBR) only, which is lost when backup battery power is interrupted. This package runs a systemd service before gpsd to ensure the receiver is always correctly configured.

## Configuration applied

| Parameter | Value |
|:----------|:------|
| Baud rate | 115200 bps |
| Update rate | 10 Hz (100 ms) |
| Dynamic model | Sea |

## How it works

1. `configure-ublox-marine.service` runs before `gpsd.service` on every boot
2. Reads UART devices from `/etc/default/gpsd`
3. Probes each `/dev/ttyAMA*` device for a u-blox receiver (115200 then 9600 bps)
4. Configures rate, dynamic model, and baud rate via `ubxtool`
5. Saves settings to BBR (persists until next power loss)

## Part of HaLOS

This package is part of the [HaLOS](https://github.com/halos-org/halos) distribution and is installed automatically on HALPI2 marine images via the `halos-halpi2-marine` metapackage.

## License

MIT
