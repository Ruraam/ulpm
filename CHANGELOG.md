# Changelog

All notable changes to ULPM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [5.0.0] - 2025-05-18

### Added
- **Manifest Schema v5 & Declarative Permissions**:
- Granular `permissions` object controlling network, audio, GUI, GPU, devices, custom filesystem binds, and D-Bus namespaces.
- Full backward compatibility with Schema v1–v4 manifests.
- **Declarative User Overrides System**:
- Persistent per-application overrides stored in `~/.config/ulpm/overrides/<app_id>.json`.
- New `ulpm override <app><flags|key=val...>` command to adjust permissions without modifying or rebuilding packages.
- New `ulpm permissions <app>` audit tool displaying the combined effective permission matrix.
- New `ulpm permissions reset <app>` command to instantly restore baseline package permissions.
- **Execution Profiles**:
- `--gaming`: Automatic passthrough for DRI, input gamepads, raw HID (`/dev/hidraw*`), and raw USB controllers.
- `--strict`: Complete lockdown removing network, GPU acceleration, downloads directory, and host device passthrough.
- `--desktop`: Default balanced desktop profile.
- **Hardware Passthrough Controls**:
- Support for raw HID controllers (`--dev-hidraw` / `--no-hidraw`), raw USB subsystems (`--dev-usb` / `--no-usb`), and hardware virtualization acceleration (`--dev-kvm`).
- **Filesystem Isolation Modes**:
- Support for configurable `$HOME` isolation: `"isolated"` (`~/.var/app/<id>`), `"read"` (host home read-only), and `"read-write"` (direct host home).
- CLI flags `--isolate-home`, `--share-home`, and `--share-home-ro`.
- **Hybrid Shared Runtimes Foundation**:
- New `ulpm runtime list` and `ulpm runtime install` commands.
- Support for shared commonbase layers installed in `~/.local/share/ulpm/runtimes/`.
- Manifest fields`runtime` and `shared` for modular packaging.
- **Packaging & Unpacking Improvements**:
- AppImage Type-2 safe unpacking by calculating SquashFS section offsets via `readelf` without executing untrusted binaries.
- Heuristic hardwareand permission pre-scanning when generating Schema v5 packages in `pack.sh`.
- Pass-through support for runtime and fast-pack flags (`--no-scan`, `--fast`, `--shared`, `--runtime`).

### Security
- **Deep Purge (`remove --purge`)**:
- Automatically cleans persistent application sandbox storage (`~/.var/app/<id>`) and user overrides (`~/.config/ulpm/overrides/<id>.json`).
- **D-Bus Namespace Hardening**:
- Blocked arbitrary bus ownership grants for system/desktop namespaces (`org.freedesktop.*`, `org.gnome.*`, `org.kde.*`, `org.mpris.*`).
- **Signature Integrity**:
- Strict Ed25519 signature validation enforcement via `ULPM_STRICT_SIGNATURES=1`.
- Safe payload inspection during installation using isolated temporary mounts.

### Changed
- `install.sh`: Full supportfor ULPM v5 directories, updated shell completions (Bash/Zsh) with new subcommands and execution profile flags.
- Default packaging format version bumped to 5 (`ULPM_FORMAT_VERSION=5`).
- Documentation: Updated `LPK-FORMAT.md`, `SECURITY.md`, and `CONTRIBUTING.md` to reflect Schema v5 and declarative sandboxing.

---

##[4.1.0]

### Added
- `.lpk` format v4: SquashFS (zstd)payload with an embedded 104-byte Ed25519 trailer.
- Bubblewrap sandbox with `xdg-dbus-proxy`, runtime kill-switches (`--offline`, `--no-gpu`, `--no-audio`, `--no-gui`), and per-app XDG directories.
- RootFS container mode for embedded distributions.
- Ephemeral volatile RAMexecution (`ulpm stream`).
- Debian `.deb` package and APT dependency resolution and converter (`ulpm deb-pack`).
- Smart GitHub release resolution and download cache.
