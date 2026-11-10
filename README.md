# radiacode-perl

A Perl command-line client for RadiaCode radiation detectors (RC-10x family). It talks to
the device directly over Bluetooth Low Energy, so the vendor app is not needed for reading
data.

It can:

- show live count rate, dose rate and temperature
- show the device status, including the battery charge level and charging events
- read and save the energy spectrum (all 1024 channels, as CSV or JSON)
- dump the device's buffered records and configuration
- read and write device settings, the energy calibration and the device clock
- run as a logger that writes daily CSV files, and draw SVG charts from those files

The full manual is in the script itself: run `./radiacode.pl --man`.

## Requirements

- Linux with BlueZ. The script opens L2CAP sockets directly.
- Perl 5. It uses only core modules, so there is nothing to install from CPAN.
- The device must not be connected to another host (for example the phone app) at the
  same time.

## Quick start

Find the device's Bluetooth address (for example with `bluetoothctl scan on`), then:

```sh
./radiacode.pl -d AA:BB:CC:DD:EE:FF --info        # serial number and firmware
./radiacode.pl -d AA:BB:CC:DD:EE:FF --status      # rates, temperature, battery
./radiacode.pl -d AA:BB:CC:DD:EE:FF -i 1 -n 10    # ten readings, one per second
./radiacode.pl -d AA:BB:CC:DD:EE:FF               # live readings until Ctrl-C
```

## Common tasks

Save the current spectrum with every channel:

```sh
./radiacode.pl -d AA:BB:CC:DD:EE:FF --spectrum --format csv \
    -o radiacode-data/spectrum-$(date +%Y%m%d-%H%M).csv
```

Log to daily files, with a spectrum every 5 minutes:

```sh
./radiacode.pl -d AA:BB:CC:DD:EE:FF --monitor --spectrum-every 300
```

This writes `rates-DATE.csv`, `events-DATE.csv` and `spectrogram-DATE.csv` to
`./radiacode-data` (change it with `--dir`).

Draw SVG charts from the monitor logs (no device needed):

```sh
./radiacode.pl --plot
```

## Actions

| Action | What it does |
| --- | --- |
| `--info` | Serial number and firmware version |
| `--status` | Count and dose rates, temperature, status, charge level, last charge event |
| `--spectrum` | Current energy spectrum (add `--accum` for the accumulated one) |
| `--spectrum-reset` | Clear the device's current spectrum (writes to the device) |
| `--energy-calib` | Read the energy calibration (a0, a1, a2) |
| `--set-energy-calib A0,A1,A2` | Write the energy calibration (writes to the device) |
| `--set NAME=VALUE` | Write a device setting and read it back (writes to the device) |
| `--set-time [T]` | Write the device clock (writes to the device) |
| `--alarms`, `--settings`, `--config` | Read alarm thresholds, settings and configuration |
| `--buffer` | Dump all buffered records once |
| `--monitor` | Long-running logger with daily files |
| `--plot [DIR]` | Draw charts from the monitor logs |
| `--poweroff` | Power the device down (writes to the device) |
| `--man` | Show the manual page |

With no action, the script polls the device's buffered records and prints new ones.

## Output

`-f, --format` accepts `text` (default), `csv` or `json`. `-o, --output FILE` appends to a
file instead of printing; a CSV header is written only when the file is new or empty.

## Notes

- **Calibration.** Spectrum energies come from the device's calibration
  (a0 + a1·ch + a2·ch²). Channel 1023 is an overflow bin, so its counts are not real
  energies.
- **Battery.** The charge level comes from the device's "rare" buffer records, which are
  written every few minutes. Until one is written, `--status` says there is no reading.
  The realtime record's flags field is not decoded to a charging state.
- **Writes.** Actions marked "writes to the device" change the device. Settings and the
  calibration are read back after writing so the result can be checked.

## Tests

```sh
prove -r t
```

## Credits

The protocol was worked out from the [cdump](https://github.com/cdump/radiacode) project's
RadiaCode code.
