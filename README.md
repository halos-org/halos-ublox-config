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
3. Listens to each `/dev/ttyAMA*` device at 115200 then 9600 bps, accepting the rate that yields a checksum-valid NMEA sentence
4. Configures rate, dynamic model, and baud rate via `ubxtool`, at the detected rate
5. Saves settings to BBR (persists until next power loss)
6. Points gpsd's `-s` speed at the receiver's actual baud

## Why detection is read-only

Transmitting UBX at a baud the receiver is not running at produces framing errors, and u-blox M8 firmware disables its UART receiver after more than 100 of them. The module keeps transmitting NMEA, so it still looks alive, but it accepts no further configuration — and HALPI2 has no GNSS reset line, so only fully removing power clears the state.

Detection therefore transmits nothing. The receiver streams NMEA continuously at whatever rate it is currently running, so the baud can be established by listening, and UBX only goes out once the rate is known. A receiver that has already latched into the RX-disabled state announces it in a `$GNTXT` sentence, which the same read picks up and reports.

The corollary is that a receiver configured for UBX-only output cannot be detected. Nothing in HaLOS produces that state — factory default and this package both leave NMEA enabled — and probing for it would mean transmitting blind, which is the hazard above.

## Part of HaLOS

This package is part of the [HaLOS](https://github.com/halos-org/halos) distribution and is installed automatically on HALPI2 marine images via the `halos-halpi2-marine` metapackage.

## License

MIT
