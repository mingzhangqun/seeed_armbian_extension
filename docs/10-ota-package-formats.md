# 10. OTA Package Formats and Apply Hooks

Specification for payload-format negotiation and package-provided apply hooks.
Mechanics background: [OTA Internals](09-ota-internals.md).

1. [Package layout](#1-package-layout)
2. [Format negotiation](#2-format-negotiation)
3. [Format map](#3-format-map)
4. [Apply hooks](#4-apply-hooks)
5. [Compatibility matrix and the transition train](#5-compatibility-matrix-and-the-transition-train)
6. [Build-side variables](#6-build-side-variables)

## 1. Package layout

Members at the package root (outer tar; see format map for compression):

| Member | Required | Role |
|---|---|---|
| `package.env` | yes | first member; mode, format, hook declaration |
| `boot.tar.<fmt>` | no | boot partition payload |
| `boot.sha256` | with boot tar | checksum |
| `boot.itb` | secure boot | raw FIT image (replaces boot tar) |
| `rootfs.tar.<fmt>` | yes | rootfs payload |
| `rootfs.sha256` | yes | checksum |
| `rootfs.tar.<fmt>.enc` | encrypted builds | replaces plaintext rootfs tar |
| `payload.manifest` + `.sig` | encrypted builds | cipher params + plaintext hashes, RSA-PSS signed |
| `ota-hook.sh` | no | package-provided OTA logic (see §4) |
| `hook.sha256` | with hook | checksum |
| `version.txt` | yes | provenance |

## 2. Format negotiation

The package declares what it needs; the runtime declares what it can do.
Phase 1 fails fast with actionable errors instead of dying in the initramfs.

`package.env` keys (all additive; old packages simply lack them):

| Key | Meaning | Default when absent |
|---|---|---|
| `PAYLOAD_FORMAT` | payload compression: `gz`, `xz`, `zstd` | inferred from the suffix actually staged (legacy behavior) |
| `MIN_RUNTIME_VERSION` | minimum `OTA_RUNTIME_VERSION` required | no check |
| `OTA_HOOK` | filename of the hook at package root | conventional name `ota-hook.sh` if present, else none (legacy `OTA_APPLY_HOOK`/`ota-apply-hook.sh` accepted) |
| `ROOTFS_BYTES` | rootfs payload extracted size (`du --apparent-size` of the build staging tree, mirroring the payload tar's excludes) | capacity gate skipped with a warning |
| `BOOT_BYTES` | boot payload extracted size (staged boot tree, or `boot.itb` on raw-FIT builds) | capacity gate skipped with a warning |
| `BOOT_KIND` | boot payload shape: `tar` (ext4 tree, extract margin) or `itb` (raw FIT, compared 1:1) | conservative extract margin |

Both backends compare `ROOTFS_BYTES`/`BOOT_BYTES` against the target partition
(`blockdev --getsize64`) **before** any write -- recovery before mkfs destroys
the old rootfs, A/B against the inactive slot (encrypted A/B targets reserve
the LUKS2 header). Recovery probes the running root source (LUKS mapper on
encrypted builds); A/B probes the slot partitions by PARTLABEL. Extracted
tar trees get a 110% ext4-metadata margin; a `BOOT_KIND=itb` payload is
dd'd verbatim and is compared 1:1.

Runtime constants (`common.sh`, mirrored in the initramfs lib):

```sh
OTA_RUNTIME_VERSION="1.1"
OTA_RUNTIME_FORMATS="gz xz"   # what this runtime's initramfs can decode
```

Phase-1 checks, in order:

1. `MIN_RUNTIME_VERSION` > device `OTA_RUNTIME_VERSION` →
   `device OTA runtime too old (have X, need Y); upgrade the OTA tooling first`
2. `PAYLOAD_FORMAT` ∉ `OTA_RUNTIME_FORMATS` →
   `device OTA runtime cannot decode '<fmt>' payloads (supports: ...)`; note
   the check applies to the **initramfs** capability set even though phase 1
   runs in the full system
3. suffix resolution and the magic-byte sniff must agree with the declaration

`OTA_RUNTIME_VERSION` tracks the `armbian-ota` deb version and must be bumped
whenever `OTA_RUNTIME_FORMATS` or the hook contract changes.

## 3. Format map

One table, mirrored in three places (`package-create.sh` build side,
`common.sh`, the initramfs payload lib). Adding a format means adding one row
everywhere — no scattered `if/else`:

| fmt | suffix | magic (first bytes) | build command | tar extract flag | initramfs tool |
|---|---|---|---|---|---|
| gz | `.tar.gz` | `1f 8b` | `tar -czf` | `-xzf` | gzip |
| xz | `.tar.xz` | `fd 37 7a 58 5a 00` | `tar -cf - \| xz -6 -T0` (multi-block for threaded decode) | `-xJf` | xz + liblzma |
| zstd | `.tar.zst` | `28 b5 2f fd` | `tar -cf - \| zstd -19 -T0 --long=27` | `--zstd` | zstd + libzstd |

The magic sniff (`ota_verify_tar_magic`) runs before extraction: a suffix that
disagrees with the file contents is refused, so a renamed archive cannot bypass
negotiation. Extraction flags are unified across modes: recovery-phase-2
extraction uses the same `--xattrs --acls --numeric-owner` set as A/B.

zstd is wired through the map and the build selector, but `OTA_RUNTIME_FORMATS`
only lists it once the image actually ships the zstd CLI (the initramfs hook
copies zstd + libzstd into the initrd whenever the rootfs has them, ~2 MB).

## 4. OTA hooks

A package may carry its own OTA logic (`ota-hook.sh`) so that format, layout
or migration changes can ship to deployed runtimes without a tool upgrade.
The hook is **sourced once per phase and must be definition-only** (nothing
but function definitions -- top-level code would run at every phase). At
fixed call points the runtime invokes a named function **only when the hook
defined it**; otherwise the built-in flow is untouched. Contract version:
`OTA_HOOK_API=1` (runtime 1.2+; packages may still use the pre-1.2
`ota-apply-hook.sh` name and `OTA_APPLY_HOOK` declaration).

### Call points

| Function | Phase / environment | When | Typical use | Non-zero return |
|---|---|---|---|---|
| `hook_after_unpack` | phase 1, live system (bash) | extraction + checksums + negotiation passed, before `state=prepared` | custom admission checks (version constraints, board compat), payload transcoding | cancels the OTA cleanly, nothing touched |
| `hook_pre_apply` | phase 2 initramfs (busybox sh); A/B live system | mounts done, before mkfs / target-slot write — the **old system is still readable** | back up files beyond the built-in preserve list (databases, custom /etc) | abort; recovery retries on next boot, so the hook must be idempotent |
| `hook_apply` | same | **replaces** the built-in payload application (rootfs + boot) | custom partition layout / format | abort, same retry semantics |
| `hook_post_apply` | same | extraction + config patch done, before the state commit — the **new system is still writable** | inject files the payload cannot carry, migrate old config forward | abort, same retry semantics |
| `hook_firstboot` | the **new system**, first boot | systemd oneshot (`armbian-ota-firstboot-hook.service`), runs once and removes itself | data migration, service notifications, telemetry | logged; on A/B it runs before the mark-success health check so the failure is visible in the same boot window |

When `hook_firstboot` is defined, the orchestrator automatically copies the
hook script into the new rootfs (`/usr/share/armbian-ota/firstboot-hook.sh`)
before the payload staging directory is deleted -- the service is gated by
`ConditionPathExists` and stays inert once the file is gone.

### Contract environment

| Variable | Recovery (initramfs) | A/B (live system) |
|---|---|---|
| `OTA_HOOK_MODE` | `recovery` | `ab` |
| `OTA_HOOK_PATH` | staged hook file | same |
| `OTA_DIR` | staging dir on userdata | staging dir |
| `ROOTFS_TAR`, `BOOT_TAR`, `BOOT_ITB` | resolved payload paths | same |
| `ROOT_MNT` (+ `BOOT_MNT` post-apply) | mounted targets | mounted target-slot root |

Recovery hooks can call the orchestrator's helpers (`log`,
`start_heartbeat`/`stop_heartbeat`, `extract_tar`, `ota_reformat_rootfs`,
`ota_patch_config`, the `device.sh` primitives); A/B hooks use the `log_*`
and `ab_*` families. Hooks must not unmount anything, write the state file,
or reboot -- the orchestrator owns teardown and state in success and failure
paths alike.

### Security

Plain packages: the hook runs as root, but the package already ships an
entire rootfs -- no new trust boundary; the hook is checksummed
(`hook.sha256`) like every member. Encrypted/secure-boot packages: the signed
manifest covers the hook name and hash, so a tampered hook fails signature
verification.

## 5. Compatibility matrix and the transition train

| Device runtime \ Package | gz (legacy) | xz/zstd, no hook | with hook |
|---|---|---|---|
| legacy (no negotiation, no hook) | works | clean refusal at extraction | hook ignored — behaves like the previous column |
| this runtime (`1.1`) | works | works (format within capability set) | hook takes over |

A hook cannot rescue a runtime that predates hook support — that code cannot
look for one. Therefore one release discipline applies:

> **Transition train:** the first runtime with negotiation + hooks ships to
> the installed base inside a **legacy gz package** (the new runtime is simply
> part of that rootfs). Every later format or layout evolution rides an apply
> hook, and deployed devices never need a two-step "upgrade tool, then
> upgrade system" dance again.

`version.txt` carries `RUNTIME_BOOTSTRAP=yes` on that one package so operators
can identify it.

## 6. Build-side variables

| Variable | Values | Effect |
|---|---|---|
| `OTA_PAYLOAD_COMP` | `xz` (default), `gz`, `zstd` | payload + outer package layout (see `package-create.sh`) |
| `OTA_HOOK_SCRIPT` | path | file shipped as `ota-hook.sh` + `hook.sha256`; absent by default (legacy `OTA_APPLY_HOOK_SCRIPT` still honored) |
| `OTA_MIN_RUNTIME_VERSION` | version | stamped into `package.env` |
