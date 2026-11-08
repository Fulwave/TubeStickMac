# Contributing

Thanks for helping. This project drives one USB device, so the most useful contributions are small and testable.

## Build and test

```bash
swift build
swift test          # no stick needed: parsers are tested with synthetic transport streams
```

CI runs the same on macOS for every pull request. Hardware code (`Sources/CTubeStick/device.c`, `stream.m`) can only be tested with a real stick, so say in your pull request what you ran it on (macOS version, Mac model, how the stick was connected).

## Ground rules

- **Never commit vendor files**: no firmware images, drivers, installers, app bundles or captured vendor binaries, and no recorded TV broadcasts. Fixtures must be synthetic (see `Tests/TubeStickKitTests/TransportTests.swift`).
- **Do not help circumvent license checks or servers of the original software.** This project is a clean reimplementation of the hardware protocol.
- Explain protocol changes in `docs/findings.md`, with what you observed and how you checked it. Register values should come from your own observation or from public Linux driver behavior.
- Every code path that starts the stream must stop it (`ts_stream_stop`) on every exit. A stream left running can hang the stick.
- Use American English spelling in code, comments and docs.
- Keep it MIT-compatible: do not paste GPL code. Describe behavior and write your own implementation.

## Good first areas

- Support for other Empia-based tuner sticks (add a device table and test reports).
- QAM (cable) tuning.
- A program guide from the ATSC EIT tables.
- Signed and notarized releases, a Homebrew cask.
- Better lock-up diagnosis (see `docs/findings.md`).

## Reporting a problem

Please include: macOS version, Mac model, how the stick is connected, the output of `tubestick scan` or the command that failed, and whether unplugging the stick fixed it.
