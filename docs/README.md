# Documentation Index

Step-by-step guides for building and using Seeed RK35xx Armbian firmware.
Read in order for a full walkthrough, or jump to what you need.

| # | Guide | For whom |
|---|---|---|
| 1 | [Getting Started](01-getting-started.md) | First build: environment, staging, first image |
| 2 | [Build Reference](02-build-reference.md) | All profiles, options, and environment variables |
| 3 | [Recovery OTA](03-ota-recovery.md) | Build, flash, and update single-system firmware |
| 4 | [A/B OTA](04-ota-ab.md) | Dual-slot firmware with automatic rollback |
| 5 | [Encryption](05-encryption.md) | LUKS rootfs with automatic unlock |
| 6 | [Secure Boot](06-secure-boot.md) | Signed bootchain and signing keys |
| 7 | [Tools & CI](07-tools-and-ci.md) | Offline FIT re-signing, deb release, CI builds |
| 8 | [Hardening](08-hardening.md) | Always-on brute-force defense and ssh-protect |
<<<<<<< Updated upstream
| 9 | [OTA Internals](09-ota-internals.md) | Developer reference: flow, payloads, state machines |
| 10 | [OTA Package Formats](10-ota-package-formats.md) | Format negotiation, apply hooks, compatibility |
=======
| 9 | [Partition Layouts](09-partition-layouts.md) | Plain / A/B / Secure Recovery / Secure A/B — on-disk structure with diagram |
>>>>>>> Stashed changes

## Pick your path

- **"I don't want to build anything"** → grab a prebuilt image from the
  [armbian-build releases](https://github.com/Seeed-Studio/armbian-build/releases)
  (per-board IMAGE/OTA tables), then flash per
  [Getting Started §5](01-getting-started.md#5-flash-and-boot).
- **"I just want a working image"** → [Getting Started](01-getting-started.md), then flash and use; updates come via [Recovery OTA](03-ota-recovery.md).
- **"I need updates that cannot brick the device"** → [A/B OTA](04-ota-ab.md) (dual slot, automatic rollback).
- **"The data on the device must be unreadable if it is stolen"** → [Encryption](05-encryption.md).
- **"The bootchain must resist tampering"** → [Secure Boot](06-secure-boot.md).
- **"What is my image already protected against?"** → [Hardening](08-hardening.md).
- **"I want to change device-tree overlays on a signed image without rebuilding"** → [Tools & CI](07-tools-and-ci.md) (`repack-fit.sh`).
- **"What does the disk actually look like under each profile?"** → [Partition Layouts](09-partition-layouts.md) (one diagram, four profiles).

## Conventions

- Variables and options link to the source file that reads them, e.g.
  [`OTA_BOOT_SIZE`](../armbian-ota/common/build-hooks/partitions.sh#L31) —
  follow the link to see the default and validation with your own eyes.
- Commands assumed to run on the build host unless marked **on device**.
- Developer-oriented internals (hook ordering, runtime file layout) live in
  [`armbian-ota/README.md`](../armbian-ota/README.md); these guides stay
  usage-focused.
