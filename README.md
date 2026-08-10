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
3. Listens to each `/dev/ttyAMA*` device at 115200 then 9600 bps, accepting the rate that yields either a checksum-valid NMEA sentence or a UBX binary stream
4. Raises the receiver to 115200 first, then sets update rate and dynamic model at that rate
5. Saves settings to BBR (persists until next power loss)
6. Points gpsd's `-s` speed at the receiver's actual rate

A device listed in `/etc/default/gpsd` that produces nothing is reported as having no receiver, and the service still succeeds. The listing is not evidence that hardware is there: pi-gen writes the HALPI2 UART into that file for every marine image, fitted module or not, and the port itself belongs to the SoC.

Silence is only ever the answer once every fault that produces it has been ruled out. The service still fails when the port does not exist, when it cannot be opened, when another process holds it now or held it when the run began, when another process changed its rate mid-listen, or when the port carries traffic that parses at neither candidate rate — a receiver at some other speed, or one that is not u-blox. An unfitted UART reads exactly zero bytes, so traffic is the discriminator between an empty socket and a receiver this package cannot address.

## Why detection is read-only

Transmitting UBX at a baud the receiver is not running at produces framing errors, and past 100 of them in a second the receiver stops listening for the remainder of that second. It re-enables itself — the `More than 100 frame errors, UART RX was disabled` notice is emitted when RX comes back — so this costs time, not hardware.

The lasting damage comes from the other end. Configuration is saved to battery-backed RAM, which HALPI2 keeps powered, so a baud written blindly and saved survives a warm reboot: the receiver ends up at a rate nothing on the host is using and looks dead until power is physically removed.

Detection therefore transmits nothing. The receiver streams continuously at whatever rate it is currently running, so the baud can be established by listening, and UBX only goes out once the rate is known — which is both free and impossible to get wrong. A receiver reporting the frame-error notice is picked up by the same read and logged, since something on the line is talking at the wrong rate even though the receiver recovers.

Listening accepts either protocol. A factory receiver emits NMEA, but gpsd switches u-blox devices into UBX binary mode when it takes over, and that survives a warm reboot — a capture from a device in normal service showed 11801 bytes containing 210 UBX frame headers and not one NMEA sentence. Treating NMEA as the only sign of life would report every gpsd-driven receiver as absent and skip configuring it.

Two details matter for the listening itself. Bytes already queued when the rate changes were framed by the UART at the *previous* baud, and switching the rate neither re-frames nor discards them, so the queue is drained and discarded before a sample is taken — otherwise the old rate's valid output authenticates the new rate. And gpsd must not hold the device: it is stopped for the duration whenever it is running, because a sample taken underneath it is empty and reads as "no receiver".

## Part of HaLOS

This package is part of the [HaLOS](https://github.com/halos-org/halos) distribution and is installed automatically on HALPI2 marine images via the `halos-halpi2-marine` metapackage.

## License

MIT
