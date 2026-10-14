# Changelog

All notable changes to ULPM are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- Signature policy: forged or corrupted packages are always refused; unsigned or unknown-key
  packages warn, or are refused with `ULPM_STRICT_SIGNATURES=1`.
- Manifest `id` / `name` are validated before use in paths, the install database and D-Bus
  filters (blocks path traversal on `remove --purge` and `sed` command injection).
- The install database is edited without interpreting package-controlled text as code.
- `--unshare-pid` in app and RootFS modes; `--cap-drop ALL` in RootFS mode.
- No D-Bus `--own` grant for ids inside `org.freedesktop`, `org.gnome`, `org.kde`, `org.mpris`.
- `pack` no longer executes AppImages on the host (ELF header parsing + `unsquashfs -o`).
  Legacy behaviour: `ULPM_ALLOW_APPIMAGE_EXEC=1`.
- `ulpm trust` shows the key fingerprint and refuses to overwrite a different key of the same name.
- `self-update` checks syntax before replacing files and updates them one by one.
- `install.sh`: `ULPM_REQUIRE_CHECKSUMS=1` makes checksum verification mandatory.

### Added
- `--no-input` runtime flag (disables `/dev/input`, `/dev/js*`, `/dev/uinput`).
- Ed25519 signing fallback for OpenSSL builds where `dgst -sign` does not support Ed25519
  (existing signatures stay valid).
- Project tooling: `Makefile`, shellcheck CI, issue/PR templates, `SECURITY.md`,
  `CONTRIBUTING.md`, `.lpk` format specification, man page.

### Fixed
- CLI: `search`, `token`, `doctor`, `self-update`, `completion` dropped their first argument.
- `upgrade` aborted on the first available update (`((n++))` under `set -e`), never recorded the
  real package version, and could not upgrade packages installed from a native `.lpk`.
- `--bind` was silently ignored in RootFS mode.
- `"network": false` in a manifest was ignored.
- `normalize_target` mangled paths containing backslashes.

## [4.1.0]
- `.lpk` format v4: SquashFS (zstd) payload with an embedded 104-byte Ed25519 trailer.
- Bubblewrap sandbox with `xdg-dbus-proxy`, runtime kill-switches (`--offline`, `--no-gpu`,
  `--no-audio`, `--no-gui`), per-app XDG directories.
- RootFS mode, RAM streaming (`stream`), `.deb` dependency resolution (`deb-pack`), smart HTTP cache.
