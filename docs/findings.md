# Findings

_Research log in chronological order. Later rounds correct earlier ones; the supported code is in `Sources/` and the README. Paths such as `dist/` and `local/` refer to the original working tree and are not in the repository._

## Device
- `lsusb`-style IDs from macOS: vendor `0x1d2c` (equinux), product `0x1012`, version `0x0110`, "TubeStick Hybrid ATSC", USB 2.0 high speed, bus powered 500 mA.
- `EMBDA.INF` in the Windows 2.1 driver set maps `VID_1D2C&PID_1012` to the `USB2883` entry: an Empia EM2883 bridge.
- Other equinux IDs seen: mini `1d2c:1002` (`mod7700`); original TubeStick (D1010) is Afatech AF9015 `15a4:9015/9016`.

## Old Mac driver structure (EQTVKit.framework, unstripped i386)
- Class `com_equinux_dtv_usb_TubeStickHybrid` (vendorId 0x1d2c, productId 0x1012) sits on `com_equinux_dtv_usb_Empia`.
- Chip adapter classes present in the same binary: `Xceive3028Empia28XXAdapter`, `Xceive5000Empia2880Adapter`, `LGDT3304Empia288XAdapter`, `CX2584XEmpia288XAdapter`, `TVP5150`, `AVF49B`, `TDA18271`, `DRX39K`/`DRX397xD`, `MT2060`, `MT353`.
- Helper libs: `xc_*` and `xc3028_*` (Xceive tuner), `EM28XX_*` (bridge register/PIO/GOP), `LGS_*`, `I2CRead/I2CWrite`.
- Best guess for this stick's ATSC chain: EM2883 + tuner (Xceive XC3028 or XC5000) + LGDT3304 demod, with a CX2584x analog video decoder for composite/S-Video. **Unconfirmed**: need the device-construction path (which adapters TubeStickHybrid wires together) and an I2C bus scan from the real stick.

## Open questions
1. Which tuner (XC3028 vs XC5000) and which firmware blob does it need? `merlinFW.rom` (16 KB, 2006) in the Windows set may be unrelated to this; the XC3028 firmware (`xc3028-v27.fw`) may be needed.
2. Does Linux `em28xx` already have a board entry for `1d2c:1012`? If so, its init sequence is the fastest reference.
3. Isochronous vs bulk transfer mode for the TS stream on EM2883.

## Plan
1. Confirm the chip chain from the framework (vtable wiring) and, if possible, a Linux boot of the stick.
2. Write a libusb/IOUSBHost tool: reset, EM28xx register init, I2C scan, identify chips.
3. Load tuner firmware, lock an ATSC channel, dump MPEG-TS to a file.
4. Play the file, then wrap as a small daemon or app.

## Trace of the old driver's chip wiring (EQTVKit disassembly)
- `TubeStickHybrid` is only the USB identity (vendor `0x1d2c`, product `0x1012`). The classes `DexatekATSC`, `DexatekQAM`, `DexatekAnalog`, `DexatekComposite` and `DexatekSVideo` call its `_init`. "Dexatek" is probably the contract manufacturer's name; this is an inference from the class names.
- The chip wiring is not hard-coded per product. A shared `configureGPIO` routine (near `0x88b00`) reads the Empia EEPROM and then **probes I2C addresses at run time** to choose adapters. **Correction (after the hardware probe below):** the numbers in this table are probably *part codes read from the EEPROM*, not I2C addresses. The code reads six EEPROM bytes first, then switches on the value, and values like `0x53` and `0x81` do not look like bus addresses. Treat the 'addr' column as a part-code column until proven otherwise.

| Role | EEPROM part code (not an address) | Adapter chosen |
|---|---|---|
| Analog video decoder | `0x88` | `CX2584X` (Conexant, Linux `cx25840` at 7-bit `0x44`) |
| Analog video decoder | `0x82` | `AVF49B` (alternate board) |
| Digital demodulator | `0x1c` | `LGDT3304` (LG ATSC/QAM, 7-bit `0x0e`) |
| Digital demodulator | `0x1e` | `MT353` (DVB-T) |
| Digital demodulator | `0x53` | `MT353` path (same adapter family) |
| Digital demodulator | `0x81` | `DRX39K` |
| Tuner | `0x6a` | `Xceive5000` (XC5000) |
| Tuner | `0x6b` | `TDA18271` |
| Tuner | `0x81` | `MT2060` |
| Tuner | `0x5c` | falls through to generic path |

- For an ATSC/QAM stick the matching chain is **EM2883 + CX2584x + LGDT3304 + XC5000**. That agrees with the "Connexant ATSC Hybrid" product string. It is still a prediction until we scan the real stick.
- The `0x24` chip-ID branch sets bridge GPIO/PIO lines 7, 6, 5 and 3 before it builds the XC5000 adapter, so the tuner needs those pins toggled (reset and power) before it answers on I2C.
- Implication: the tuner is XC5000, not XC3028. XC5000 needs a firmware blob loaded over I2C (Linux: `dvb-fe-xc5000-1.6.114.fw`). We have not located that firmware yet; it might be embedded in `EQTVKit` or in `emBDA.sys`.

## Next
1. Find the XC5000 firmware (search `EQTVKit` data and the Windows driver files for the known image header).
2. Write an EM28xx probe: reset, register read of chip ID, EEPROM dump, I2C scan. This will confirm or correct the table above.

## XC5000 firmware: found
- Location: symbol `_XC5000_firmware_SEQUENCE` in EQTVKit `__DATA`, vmaddr `0x344d10`, 12,370 bytes. It ends exactly at the next symbol (`0x347d62`), so the size is right.
- Format (read from `xc_load_i2c_sequence`): big-endian 16-bit words. `0xFFFF` ends the list; `0x0000` is a reset action; bit 15 set means wait `(word & 0x7fff)` ms; any other word N is followed by N bytes written to the tuner (2-byte register address, then data, sent in 64-byte chunks).
- Parsed result: 13 writes carrying 12,336 payload bytes, 2 waits, 1 reset, terminator in the right place. The size is close to the Linux `dvb-fe-xc5000-1.6.114.fw` image (about 12.4 KB).
- Confirms the tuner: after loading it, `_wakeup` checks the product ID against `0x1388` (5000).
- The extracted file is Xceive/MaxLinear firmware. It lives in `local/` (git-ignored). The extraction script is not included in this repository; use the public linux-firmware file instead. SHA-256 of this extraction: `f6996b1fe085fd7f9deb5d92da8aab2bc50a70a64cbf9a0480c6ff67d8734b8b`.
- Not yet verified on hardware: nothing has been written to the real tuner.

## First hardware probe (tools/em28xxprobe.c, read-only)
Run on the real stick, nothing written to the bridge:
- Opens fine with plain IOKit user-space access (no kext, no sudo). macOS does not claim the device.
- Bridge registers `0x00-0x1f`: `f0 93 6a 03 00 00 0c 0f ff ff 24 00 00 40 88 07 / 00 00 05 bf 2f fb ff 37 7f bf ef 00 5f 1c ef 1d`.
- **Chip ID (reg 0x0a) = 0x24.** The old driver branches on exactly this value (`cmpb $0x24`) before it toggles PIO lines 7, 6, 5, 3 and builds the XC5000 adapter. So this is the board class the old code treats as XC5000-based. Registers read back sensibly, so the Empia vendor protocol works from macOS.
- **I2C is not usable yet.** The I2C status register (`0x05`) reads `0x10` (busy) for every address, so the scan found nothing and the "EEPROM" bytes it returned are stale buffer data (they look like USB endpoint descriptors), not a real EEPROM. The I2C clock register (`0x06 = 0x0c`) and the GPIO/PIO state are still at power-on defaults.
- Next requires **writes**: set the I2C clock, configure GPIO, pulse the tuner/demod reset lines (the PIO 7/6/5/3 sequence), then rescan. Disassemble `EM28XX_setPIO` and the Empia init path to copy the exact values.

## Probe round 2: writes enabled (tools/em28xxprobe.c --i2c / --gpio)
- **Bug fixed in the probe:** the I2C chip address goes in the USB request's `wIndex` (with `wValue = 0`), as in the Linux driver, not in `wValue`. The first run used the wrong field, so every address looked busy and the "EEPROM" data was garbage.
- `--i2c` writes bridge reg `0x06` (I2C clock) = `0x41`. It reads back `0x4d`, so the low bits are partly fixed by hardware. Harmless; resets on replug.
- **Result: exactly two 7-bit addresses ACK, `0x1c` and `0x1d`.** Nothing answers at `0x44` (CX2584x), `0x61`/`0x35`/`0x60` (tuner guesses) or `0x0e`.
- The `0x50` EEPROM read still returns the same stale bytes (not the Empia `1a eb 67 95` magic), so this board's EEPROM is either not at `0x50` or the read form is wrong.
- `--gpio` (clear reg `0x08` bits 7,6,5,3 as the old code does) and `--gpio-high` change nothing in the scan. The tuner and analog decoder may sit behind a gate or need a reset sequence we have not reproduced.
- Open: what lives at `0x1c`/`0x1d` (the demodulator would be my guess, but it is unproven), and where the tuner, analog decoder and EEPROM are.

## Round 3: chip chain confirmed on the real stick
Key fix: the bridge takes the I2C address in `wIndex` in **8-bit form** (7-bit address shifted left once), the same convention the old driver uses (`LGDT3304` adapter sends to `0x1c`, `Xceive5000` to `0xc2`, `CX2584X` to `0x88`). My earlier hits at `0x1c`/`0x1d` were the LGDT3304's write/read address pair read through the wrong convention. The probe now defaults to the correct form (`ADDR7=1` restores the raw form).

Scan with `./build/em28xxprobe --i2c` (7-bit address shown):
| 7-bit | 8-bit | Chip |
|---|---|---|
| `0x0e` | `0x1c` | LG LGDT3304 ATSC/QAM demodulator |
| `0x44` | `0x88` | Conexant CX2584x analog video decoder |
| `0x50` | `0xa0` | EEPROM (valid Empia header `1a eb 67 95`, then `2c 1d 12 10` = vendor `1d2c` product `1012`) |
| `0x61` | `0xc2` | Xceive XC5000 tuner |

- **XC5000 product ID reads `0x2000` or `0x0020`, alternating between runs** (`XCID=1 ./build/em28xxprobe --i2c`; four runs gave 2000, 0020, 2000, 0020). Never `0x1388`. The alternation looks like a byte-order or read-alignment quirk in how the probe reads two bytes, not two real states. If it is `0x2000`, that is Xceive's "firmware not loaded" value (`0x1388` means loaded), which is the expected state. Treat as probable, not proven; the real test is whether it reads `0x1388` after the firmware load.
- The earlier note that the table's numbers were "EEPROM part codes" stays unproven either way; it no longer matters for the chain, which is now confirmed by hardware.
- **Not yet done:** loading the firmware (`local/xc5000_sequence.bin`) into the tuner and reading `0x1388`; then configuring the LGDT3304 and tuning an ATSC channel.

## Round 4: XC5000 firmware loaded on hardware
- Command: `XCFW=local/xc5000_sequence.bin ./build/em28xxprobe --i2c`
- 211 I2C writes to `0x61` (7-bit, sent as `0xc2`), 2-byte register header repeated on every chunk of up to 62 data bytes, 0 errors. The `0x0000` reset action in the sequence was skipped (the tuner is already out of reset and answered before loading), and the two waits were honored.
- **Product ID then reads `0x1388` on all four consecutive reads.** The tuner is alive, firmware accepted. This also resolved the earlier alternating `0x2000`/`0x0020` readings: `0x1388` is stable once the firmware is in.
- The load is volatile; unplugging the stick clears it.
- Next: configure the LGDT3304 (register init copied from the old `LGDT3304` code), program the tuner frequency (`xc_set_RF_frequency`, ATSC IF settings), route the bridge to capture the MPEG-TS stream, and lock an ATSC channel.

## Round 5: first ATSC scan (no lock yet)
Recovered from the old driver and now implemented in `tools/em28xxprobe.c` (`--i2c --scan`, with `XCDIAG=1` for tuner registers):
- **LGDT3304** (7-bit `0x0e`, 16-bit register + 1 data byte): reset = clear then set bit 0 of reg `0x0002` with 1 ms between; `initVSB` = RMW `0x0000|=03`, writes `000d=02 000e=02 0012=32 0013=c4 0112=17 0113=15 0114=18 0115=ff`, RMW `0116 &f8|04`, `0214 &f0|07`, writes `0424=8d 0427=12 0428=4f 0308=80 0309=00`, RMW `030d|=10`, `030d|=04`, `030e&=bf`, `030e&=fe`, writes `0314=e1 050e=5b`. Lock check for VSB reads `0409`, `0417`, `0418`, `0419`.
- **XC5000 tune for ATSC (6 MHz):** reg `0x0d`=0 (air), reg `0x01`=`0x8002` (video DTV6), reg `0x02`=`0x00c0` (audio DTV6), reg `0x05`=IF 6.0 MHz x 1024, reg `0x03`=(center - 1.75 MHz) / 0.015625 MHz. The standard values match the public Linux `xc5000` table (DTV7 `0x8007`, DTV8 `0x800b` also appear in the old code). The register map is confirmed on hardware: reg `0x08`=`0x1388`, reg `0x07` (version)=`0x3213`, and every tuner write returned I2C status 0.
- **Result:** scanning channels 2-51 gave tuner ADC level 0, SNR 0, tuner lock 0, and the LGDT3304 lock registers stayed at their no-signal values (`0409=07, 0417=03, 0418=ff, 0419=ff`) on every channel. All I2C traffic succeeded, so the chain is talking; this looks like **no RF signal reaching the stick** (no antenna or cable connected, or no ATSC channels in range), but that is a guess: the demodulator lock registers' meaning is not verified, and the old driver may also need steps not yet reproduced.
- **Still to do:** confirm with an antenna; copy the bridge's digital stream setup (`startDigitalStream`: regs `0x1c-0x1f`, `0x1b`, `0x5d`, `0x5f`, `0x12`) and read the transport stream from the isochronous endpoint.

## Round 6: tuner brought alive; signal candidates, no confirmed lock
- **Fix:** the earlier all-zero scan was caused by skipping `xc_initialize` (write `0` to XC5000 reg `0x00`, which the old `_wakeup` does right after the firmware load). With it, plus a wait on the busy flag (reg `0x09`) after each tune, the tuner's ADC envelope (reg `0x00`) varies by channel.
- Scan (antenna moved next to a window): the ADC level runs 20-1020 (it clips near 1020 on several channels, so the gain is probably too high for a strong nearby signal or the reading is just noisy), and quiet at the top UHF channels (45-51 read about 28), which is plausible for empty spectrum.
- The LGDT3304 lock registers (`0409`, `0417-0419`) changed on about a dozen channels, but on re-reads the values keep moving (`0419` jumps between samples on nearly every channel). Channels 10 and 30 show a steadier pattern (`0417=00`, `0418` about `0x23-0x28`) but I cannot say that means lock: the meaning of these registers is not verified.
- Not yet confirmed: any real lock. Needs ground truth of which RF channels actually carry ATSC signals at this location (the user is going to check with the original software on a Windows PC).
- Probe additions: `CHS=10,30 ./build/em28xxprobe --i2c --scan` limits the scan and re-reads each channel 4 times; `RFSRC=0|1` selects air/cable signal source.

## Round 7: the old driver's lock test, applied
Reading `_isLocked` (VSB branch) showed that my earlier use of `0409`/`0417-0419` was wrong: the old driver treats the demodulator as **locked when bit 1 of reg `0x0409` is clear**, and regs `0x0417-0x0419` form a **24-bit error counter** (it converts that to a quality figure with a `log10`; smaller count = better). The `07/03/ff/ff` pattern seen on empty channels is the unlocked state.

Scan with antenna by a window, 5 samples per channel (`./build/em28xxprobe --i2c --scan`), channels reporting lock 5/5, with the last error count:
- Low counts (most believable, 60 or less): ch 3 (21), 7 (60), 18 (29), 25 (19), 27 (10), 34 (36), 35 (12), 36 (18).
- Middle: ch 13 (592), 21 (184), 22 (170), 23 (289), 26 (105), 24 (3388).
- High counts (likely false or marginal locks): ch 8 (9389), 10 (9770), 30 (9108), 33 (6622).
- Eighteen channels out of 50 reporting lock is a lot for one location, so some are probably false. **Not yet verified against a real signal list.** Next: compare with the channels the original software finds on Windows.

## Round 8: transport stream capture attempt (not working yet)
- `tools/usbdesc.c` dumps the USB layout: 1 configuration, interface 0 with alternate settings 0-7, all class `0xff`. Endpoints: `0x81` interrupt; `0x82`, `0x83`, `0x84` isochronous. `0x82` max packet grows with the alternate setting (0 in alt 0-1, 2772 in alt 2, 3072 in alt 3, 4864 in alt 4, 4956/5060/5120 in alt 5-7); `0x83` is 196 bytes and `0x84` 752 bytes from alt 1.
- Old driver's digital start (`_startDigitalStream`, chip id `0x24` path): writes `0x1c=00`, `0x1d=0x1e=0x1f=20`, two read-modify-writes of `0x1b` (values not recovered), then `0x12=0x37`, then opens an isochronous reader with arguments `4`, `0x400`, `0x200` (meaning not decoded: could be pipe/endpoint 4, alt setting 4, or a packet size).
- `./build/em28xxprobe --i2c --capture 27` (env `ALT`, `EP`, `SECS`, `OUT`) tunes a channel, checks lock (ch 27 reported LOCKED), applies those bridge writes and reads the isochronous pipe through `IOUSBInterface`. **Result so far: no data.** ALT 4 with endpoint `0x82` gives callbacks but every frame reports `kIOReturnUnderrun` (the device sent nothing); other alt/endpoint pairs produced no callbacks at all, and several runs printed nothing, so the USB state may also have been disturbed by repeated opens.
- Likely missing pieces: the board-specific GPIO routing that connects the demodulator's TS output to the bridge in digital mode (Linux calls this the board's `dvb_gpio` sequence), the remaining `_init` register setup, and the `0x1b` read-modify-writes. All of these need decoding from `_init` / `_openDevice` in the old binary, which reads values through indirect variables that my simple extractor mishandles.
- Everything before this point (chip chain, firmware load, tuning, lock indication) is working on hardware.

## Round 9: decoding the old stream start (still no data)
Decoded from `_startDigitalStream`, `_openDevice` and `_init` in EQTVKit:
- `_startDigitalStream` (chip id `0x24` path): selects USB alternate setting **4** (call with argument 4), writes `0x1c=00`, `0x1d=0x1e=0x1f=20`, clears bit 0 then bit 1 of reg `0x1b` (two read-modify-writes), writes `0x12=0x37`, then opens an isochronous reader (`4`, packet size `0x400`, `0x200` buffers). For chip id `0x44` it instead writes `0x5d=05`, sets bit 0 of reg `0x5f` and uses a buffered reader (`0xa`, `0x3ac`, `0x200`).
- `_openDevice`: clears bit 2 of reg `0x06` (only on the first branch), sets bit 6 (`0x40`, I2C wait enable), then runs an **EEPROM-driven GPIO setup**: two config bytes from the EEPROM copy (object offsets `0x8a`, `0x8b`) have a high nibble action (`0xc`: set PIO bit, `0xd`: clear PIO bit, `0xe`: set bit in reg `0x04`, `0xf`: clear bit in reg `0x04`) and a low nibble bit number. Board GPIO is therefore data in the EEPROM, not code.
- Probe changes: `FMUL` (frame size multiplier; IOKit already reports bytes per microframe including the high-bandwidth multiplier, so `x8` per 1 ms frame stalled transfers, `x1`-`x4` complete), `WRITES=reg=val,...` for extra bridge writes before the stream start, and `--capture` now applies the `0x1b` clears and prints the bridge registers.
- **Result: still zero bytes.** With alternate setting 4 and endpoint `0x82`, transfers complete on time but every frame is an underrun (`kIOReturnUnderrun`): the pipe works, the stick sends nothing. Tried extra writes of `0x10`, `0x11`, `0x13`, `0x0c`, `0x0f` in several combinations without effect. Endpoint `0x84` transfers never completed.
- Still unknown: which register change makes the bridge forward the demodulator's TS output, and whether the TS comes in on `0x82` at all. The old `_init` is full of register writes whose values the extractor could not recover.
- **Best next experiment (needs the older Mac or Windows):** while the original software is streaming, read bridge registers `0x00-0x7f` with a small tool and diff against the idle state. The control-endpoint reads do not interfere with a running stream, and that shows the exact register values that make it stream.

## Round 10: what the open-source Linux em28xx driver says
Read from `em28xx-core.c` in the Linux kernel source (the part that does not depend on the old app):
- `em28xx_capture_start()` for old Empia chips (EM2880/2882/2883), digital mode: set bit `0x10` of reg `0x0c` (USB suspend control), write `0x48 = 0x00`, write `0x12 = 0x37` (analog uses `0x67`), wait about 10 ms. `em28xx_gpio_set()` also writes `0x48 = 0` and `0x12` before applying the board's GPIO sequence. Stop is `0x12 = 0x27` and clearing bit `0x10` of reg `0x0c`.
- Linux selects the alternate setting first, then does the above, then submits isochronous transfers.
- The earlier capture runs here wrote `0x12 = 0x37` but not `0x0c |= 0x10` or `0x48 = 0`; `--capture` now includes both, in the Linux order (after the alternate setting). **Not yet tested on hardware:** the stick moved to the old Mac before the test.
- Authorization: TheTube needs equinux servers that no longer exist, so it could not be used for the register-diff plan and was not used. This project's own tools run without it. Prebuilt binaries are not committed; build from source.

## Round 11: first runs on the Snow Leopard Mac (10.6.8, i386 kernel, 64-bit user programs)
- The 10.6 builds run. First fresh plug-in: all four chips answered; firmware load: 211 writes, 0 errors, product id `0x1388` (four times).
- **Capture on 10.6 fails differently:** `ReadIsochPipeAsync` returns `0xe00002c2` (`kIOReturnBadArgument`) for every submission with `FMUL=2`, alternate setting 4, endpoint `0x82` (4608 bytes per 1 ms frame). The older IOUSBFamily rejects the request shape that the modern stack accepts; untested which request size 10.6 wants.
- **The stick wedges after repeated probe runs.** Pattern across two sessions: after about three runs of `em28xxprobe` without a physical replug, the XC5000 stops answering (missing from the scan), the next firmware load stops after 1-4 writes, and every later request returns `0xe00002ed` (`kIOReturnNotResponding`). A software re-enumeration (`--reset`, `USBDeviceReEnumerate`) did not recover it; a physical unplug/replug did. Suspects: the blind I2C scan reading every address (it includes the tuner) or a power dip (the stick draws up to 500 mA on a bus-powered port).
- Probe additions: `--reset` (re-enumerate), `NOSCAN=1` (skip the scan and EEPROM dump so firmware load and capture do not run it first).

## Round 12: transport stream capture works (endpoint 0x84)
- **The stream comes out of isochronous endpoint `0x84`, not `0x82`.** On the Snow Leopard Mac, with TheTube and its helper stopped: `NOSCAN=1 FMUL=4 ALT=4 EP=84 ./em28xxprobe --i2c --capture 27` captured 9,244,524 bytes in 30 s, which is exactly 49,173 packets of 188 bytes, every one starting with `0x47`. The bridge setup that works is the Linux `em28xx_capture_start()` sequence (`0x0c |= 0x10`, `0x48 = 0`, `0x12 = 0x37`) after selecting alternate setting 4, with the tuner firmware loaded and the LGDT3304 in 8VSB mode. The extra GPIO, input-mode and capture-window registers tried earlier were not needed.
- Contents: a real ATSC multiplex on RF channel 27: PAT lists programs 3-7 (PMT PIDs `0x30`-`0x70`), each with an MPEG-2 video PID (`0x31`, `0x41`, `0x51`, `0x61`, `0x71`) and AC-3 audio (`0x34`/`0x35`, `0x44`, `0x54`, `0x64`, `0x74`), PSIP on `0x1ffb`, 5.9% null packets. The main video PID has continuity-counter steps of exactly 1 for 96.5% of its packets, so the capture is close to lossless; the remaining gaps are probably dropped frames at transfer boundaries.
- macOS 10.6 limits: `ReadIsochPipeAsync` accepts at most 4x the pipe's packet size per 1 ms frame (`kIOReturnBadArgument` above that). The 4x size works; `FMUL` 1, 2 and 4 gave the same data rate.
- The earlier "no data" results came from reading `0x82`/`0x83` (which stay silent); the three wedge episodes coincided with TheTube and its helper (which launches itself on plug-in) running alongside the probe, plus my own GPIO writes (bit 0 of reg `0x08` low) and blind I2C scans. The recommended routine: no TheTube running, `NOSCAN=1`, no GPIO writes.
- Not yet checked: that VLC plays the video (a 30 s capture was opened in VLC on the development Mac), whether other channels behave the same, and the modern macOS result for endpoint `0x84` (never retested after finding it).

## Round 13: capture quality on Snow Leopard (packet loss, so no picture)
- VLC opens the 30 s capture but shows no picture. Analysis of the file (`local/captures/ch27-30s.ts`): 49,173 packets, but heavy loss. Main video PID `0x31`: 22,559 continuity steps of 1 against 872 gaps costing about 6,300 packets (about 21% lost); the four other programs lose about 50% (each about 6,000 lost of about 5,000 received). Transport-error flags set on 0.8% of main-program packets (weak signal or demodulator uncorrectable blocks). Each MPEG-2 key frame spans hundreds of packets, so nearly every I-frame (5-8 per 30 s) has holes and the decoder shows nothing. No real scrambling (the few "scrambled" flags are corrupted headers).
- Cause on 10.6: a histogram of per-frame sizes shows every 1 ms frame returns 188-751 bytes (typically 250-315) and never more than 752 bytes, even with requests of 3008 bytes per frame. So the old USB stack services one 752-byte slot per millisecond on this endpoint (interval 1, so the stick offers up to 8 per ms) and the rest of the stick's FIFO is lost. Requests above about 3-3.7 KB per frame are rejected (`kIOReturnBadArgument`) on every alternate setting tried (1, 2, 3, 4, 7).
- Next: capture on the modern macOS stack (xHCI), which should poll every microframe. Endpoint `0x84` at `FMUL` 1-4 has not been tried there (earlier tests there used `0x82`, or `0x84` with an oversized `FMUL=8` that stalled).

## Round 14: picture
- Reading isochronous endpoint `0x84` with `IOUSBHostIsochronousTransaction` (one microframe per transaction, 512 per transfer, 8 transfers in flight, `tools/tshost.m`) collects all eight 752-byte slots per millisecond: 12.27 MB in 5 s (about 2.45 MB/s, the full ATSC rate) with 0.22% packet loss by continuity counters and 0.14% error-flagged packets. A 30 s capture had 4.5% loss and 1.7% error-flagged packets (indoor antenna by a window; reception varies). VLC plays it with picture.
- The earlier lock-ups were the stream left enabled after each capture. `captureStopRegs()` (R0C bit 4 cleared, R12 = 0x27, as the Linux driver does on stop) fixed them: two consecutive captures and a firmware load stayed healthy.
- Remaining work, roughly in order: live viewing (pipe the stream to VLC/ffplay instead of a file), a channel scan that reports signal quality, a small command-line tool or menu-bar app that does firmware load plus tune plus stream, better antenna placement or signal-quality reporting, EPG/PSIP parsing, and recording. The legacy-API capture path stays for macOS 10.6-11 Macs but only collects about one eighth of the stream there.

## Round 15: live viewing
- `tools/live.sh [channel]` loads the tuner firmware, starts VLC (`/Applications/VLC.app/Contents/MacOS/VLC udp://@127.0.0.1:1234`; `open -a VLC --args` is ignored when VLC is already running) and streams the transport stream to loopback UDP in 1316-byte datagrams (`UDP=host:port` in `tools/tshost.m`; Ctrl-C or SIGTERM ends the capture cleanly and stops the stream). A listener test received 14.1 MB with zero misaligned datagrams; headless VLC parses the PAT/PMT, selects program 3 and starts the MPEG-2 and AC-3 decoders.
- First live view on channel 27: picture but frozen. The channel is marginal at this antenna position (1.7% error-flagged packets plus losses; every MPEG-2 key frame spans hundreds of packets, so almost every key frame is damaged and the decoder stalls).
- Per-channel quality with the full-rate reader, 8 s captures: ch 3: 0.00% error-flagged, 0.00% lost; ch 22: 0.02% / 0.02%; ch 18: 1.7% / 0.4%; ch 21: 2.5% / 0.5%; ch 7: 10% / 0.9%; ch 23: 4.5% / 0.2%. Channels 3 and 22 are the ones to watch from this spot.
- The stick still locks up after some minutes of use, even with the stop sequence (observed mid-sweep and between runs). Cause not identified: suspects are heat, the hub, or macOS suspending the device; `tools/idlewatch.sh` is there to test the idle case. Workaround: replug, then start `tools/live.sh` promptly.

## Round 16: live TV works
- `tools/live.sh 3` (after a fresh replug) gave live, moving video in VLC. The earlier frozen picture on channel 27 was damaged key frames from that channel's error rate; channel 3 had 0.00% error-flagged and 0.00% lost packets at this antenna position.

## Round 17: lock-up investigation
- A 4-minute stream (583 MB) did not lock the stick up. A read-only check every 20 s for 6 minutes did not either (19 of 19 answered). The check at 16:46:51 was the last of the idle test; the next test began 16:47:19 and the stick had already stopped answering. Lock-ups so far have always followed a gap with no host access (between runs), never active use.
- Working hypothesis: when nothing has the device open for roughly 25-60 s, macOS (or the stick) puts it into USB suspend and it does not resume properly. `tools/gapwatch.sh` measures the longest silence it survives after a fresh replug.

## Round 18: lock-ups traced to reloading the tuner firmware
- Ruled out with polling and stress tests on one power cycle (stick replugged 16:50): no clock (alive and answering every 30 s for 66 minutes), no heat/running-tuner effect (firmware loaded, alive another 26 minutes), no silence effect (gaps of 10-180 s all survived), no streaming effect (4 minutes, 583 MB, fine).
- Every lock-up had the same signature: a firmware load into a tuner that already had its firmware (product id `0x1388`) stops after about 4 I2C writes with `kIOReturnNotResponding`, and every later request fails until the stick is replugged. The sessions that never reloaded never died.
- Fix (copied from the Linux xc5000 driver): read the tuner's product id first and skip the load if it is `0x1388` (`xcAlreadyLoaded()` in `tools/em28xxprobe.c`; `FORCE_FW=1` overrides). After the fix: 14 consecutive 5 s captures plus 13 channel captures of 6 s (27 start/stop cycles in 3 minutes) all ran at the full 2.4 MB/s with no lock-up; previously a run of 6 or 7 captures was enough to hang it.
- Not proven: this is the best explanation, not a controlled proof (a deliberate forced reload into a loaded tuner would show it, but that would force a replug).
- Channel quality in that sweep (6 s captures, error-flagged% / lost%): ch 3: 0.00 / 0.00; ch 27: 0.00 / 0.00; ch 35: 0.01 / 0.02; ch 36: 2.1 / 0.6; ch 18: 4.8 / 0.4; ch 34: 4.7 / 0.7; ch 22: 5.3 / 0.2; ch 21: 7.8 / 4.1; ch 26: 13.6 / 1.1; ch 25: 16.9 / 2.4; ch 7: 26 / 1.6; ch 13: 26 / 3.0; ch 23: 29 / 2.6. Channel 27 was bad an hour earlier, so reception at this antenna spot changes over time; re-measure before choosing a channel.
- Tools added: `tools/idlewatch.sh`, `tools/gapwatch.sh`, `tools/lifewatch.sh`, `tools/cyclewatch.sh` (stability tests) and `tools/keepalive.sh` (not needed, silence is not the problem).
