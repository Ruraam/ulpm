# Architecture

ULPM is a modular Bash engine. There is no daemon, no root requirement and no database server.

## Overview

```text
bin/ulpm            CLI entry point, environment bootstrap, command dispatch
bin/ulrm            Standalone repository manager
lib/utils.sh        Paths, locking, versions, manifests, DB, GitHub, doctor
lib/crypto.sh       Ed25519 keys, signing, trust, repositories crypto
lib/sandbox.sh      Bubblewrap sandbox, permissions, D-Bus, rootfs mode
lib/pack.sh         LPK creation, source detection, library bundling
lib/deb.sh          Debian/APT/AppImage conversion
lib/run.sh          Run/stream target resolution and mount lifecycle
lib/stream.sh       Ephemeral RAM streaming
lib/manage.sh       Install, remove, list, inspect, overrides, rollback
lib/repo.sh         Repository add/update/verify/index, install, upgrade
lib/deps.sh         Dependency parsing, checking, graph resolution
lib/transaction.sh  Multi-package plans, WAL, snapshots, rollback
install.sh          Installer and updater
tests/run.sh        Integration test suite
```

Modules are sourced in strict dependency order:

```text
utils crypto sandbox pack deb run stream manage repo deps transaction
```

Each module defines `cmd_*` functions; `bin/ulpm` maps command names to them with `_dispatch`. Unknown command functions fail fast with an explicit error.

## Startup sequence

1. `set -Eeuo pipefail` for strict shell behavior.
2. Resolve the executable path, preserving symlinks.
3. Locate the library directory from `ULPM_LIB_DIR`, the script directory, or standard install paths.
4. Add the ULPM binary directory and `~/.local/bin` to `PATH`.
5. Export XDG-derived `ULPM_*` paths and create directories.
6. Create the key directory with `umask 077`.
7. Source the modules.
8. Run `init_environment`, which also repairs/canonicalizes state directories.
9. Auto-register desktop/MIME integration when the handler is missing.
10. Special-case `ulpm package.lpk` to mean `run`.
11. Dispatch the command.

## Execution paths

### `run` (FUSE-preferred)

1. Resolve the target: installed app, local file, URL or repository ID.
2. Verify the signature.
3. Read and validate the manifest.
4. Mount with `squashfuse`, reusing an instance when one is already active.
5. Fall back to extraction with `unsquashfs` when FUSE is unavailable.
6. Build the Bubblewrap command line from permissions and CLI flags.
7. Launch, wait, clean up mounts and temporary directories.

### `stream` (ephemeral)

1. Resolve the source: HTTP(S), local file, or GitHub `owner/repo[@tag]` with architecture-assisted asset selection.
2. Download to `/dev/shm`, `XDG_RUNTIME_DIR` or cache with a size limit.
3. Verify the signature.
4. Run through the same sandbox pipeline.
5. Delete the temporary package, using `shred -u` when available.

Streaming never writes the package into the installed database.

### `pack`

1. Detect the source type (directory, AppImage, deb, tar, zip).
2. Extract into an isolated build stage.
3. Build or patch `meta/manifest.json`.
4. Validate the manifest against the format schema.
5. Bundle dynamic libraries for application packages.
6. Normalize permissions and timestamps.
7. Create the SquashFS image with `mksquashfs`.
8. Sign the result by appending the 104-byte trailer.

### `install` and transactions

Single installs stage the package, verify it, atomically rename it into place and update the database. Transactions resolve the full graph first, snapshot state, write a WAL, then commit packages one by one; any failure restores the snapshot in LIFO order.

## State consistency

ULPM is designed so an interrupted command cannot leave a half-installed package visible:

- `flock` serializes mutations on `installed.db.lock`.
- Database updates are written to a temporary file and renamed.
- `sync_file` and `sync_dir` flush files and directories.
- `durable_write` implements write, `fsync`, rename, directory `fsync`.
- Transactions use a WAL plus a snapshot of every affected artifact.
- Signal traps (`INT`, `TERM`, `HUP`) trigger rollback.
- Recovery on the next transaction replays or rolls back pending WAL entries.

## Package model

An LPK is a SquashFS image with:

```text
meta/manifest.json
meta/icon.png       (optional)
root/...            (payload)
```

plus the 104-byte signature trailer outside the SquashFS payload. See [LPK format](lpk-format.md).

Application IDs use reverse-DNS style (`io.lpk.app`). Names are restricted to `[A-Za-z0-9._-]`. Versions are sanitized to alphanumerics, `.`, `+`, `_`, `-`.

## Trust architecture

Three independent pins protect upgrades:

1. **Repository pin**: the repository public key fingerprint stored at `repo add`.
2. **Package signature**: Ed25519 over the payload digest, with the public key embedded.
3. **Publisher pin**: the signer fingerprint recorded per app in `installed.db`.

Each can only be changed deliberately, through `repo remove`/`repo add`, `ulpm trust`, or `ULPM_ALLOW_KEY_ROTATION=1`.

## Sandbox architecture

`lib/sandbox.sh` computes an effective permission set:

```text
manifest permissions
  merged with ~/.config/ulpm/overrides/<app_id>.json
  adjusted by CLI profiles and flags
  translated into bubblewrap arguments
```

SANDBOX profiles:

| Profile | Effect |
| :--- | :--- |
| default | Manifest-driven |
| `--gaming` | GPU, input, hidraw, USB, audio |
| `--strict` | No network/GPU/input, isolated home, seccomp filter |
| `--desktop` | GUI, GPU, audio |

Rootfs packages use a separate path that mounts the image as `/` and provides container-like startup.

Shared runtimes are resolved by the four-axis matrix `id/version/arch/abi` under `~/.local/share/ulpm/runtimes`.

## Repositories

`lib/repo.sh` implements:

- Index fetch and detached-signature verification
- Fingerprint pinning and key byte comparison
- Index schema validation
- Package download with SHA-256 checks
- Install/upgrade integration with the transaction engine

`ulpm repo index` canonicalizes and signs `index.json` deterministically.

## Concurrency

- All mutating state operations take the database lock.
- `run` and `stream` do not take the database lock; they use per-instance mount identifiers and clean up on exit.
- Repository index updates write to a cache directory per repository.
- WAL files are unique per transaction and removed on commit or successful rollback.

## Testing

`tests/run.sh` is a self-contained integration suite (34 tests) covering signatures, manifests, packing, repositories, dependency parsing, transactions, sandbox argument generation and utility functions. It does not require network access except for optional crates and runs with fakes for external tools.

CI runs ShellCheck and the test suite. See [Development](development.md).

## Design constraints

- POSIX-heavy environments only; GNU coreutils are assumed where called.
- No resident process and no root privileges.
- All state is per-user and XDG-compliant.
- External tools (`bwrap`, `mksquashfs`, `unsquashfs`, `openssl`, `jq`, `curl`) are required at the point of use, not at startup.
- Package format compatibility is enforced by `format_version` with a current maximum of `5`.

## Related documents

- [LPK format](lpk-format.md)
- [Security model](security.md)
- [Dependencies and transactions](dependencies-transactions.md)
- [Development](development.md)
