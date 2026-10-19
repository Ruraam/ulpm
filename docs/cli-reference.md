# CLI reference

```text
ulpm <command> [options] [arguments]
```

- `ulpm --help` prints the built-in summary.
- `ulpm --version` prints the engine and LPK format versions.
- `ulpm <file>.lpk` is shorthand for `ulpm run <file>.lpk`.
- Aliases are listed with each command.

## Exit status

| Code | Meaning |
| :---: | :--- |
| `0` | Success |
| `1` | Runtime, verification, network, dependency or state error |
| `2` | Usage error or invalid argument (where the command distinguishes it) |
| other | `run` and `stream` propagate the application's exit code |

## Target resolution

Most commands accept an installed **name** or **app ID**. `run` also accepts a local `.lpk`, and `install` accepts a local `.lpk`, an HTTP(S) URL, a `file://` URL, a repository package ID or a repository package name.

Names are matched case-insensitively as a fallback in `run` and `remove`.

## Application management

### `install`

```bash
ulpm install [--repo <name>] [--reinstall] [--dry-run] <target>
```

| Option | Description |
| :--- | :--- |
| `--repo`, `-r <name>` | Resolve the package only from the named repository |
| `--reinstall` | Reinstall even if the same version is already installed |
| `--dry-run` | Resolve and report without downloading or changing state |

Targets:

- A repository package ID or name (for example `io.lpk.firefox` or `firefox`)
- A local `.lpk` path
- An `https://`, `http://` or `file://` URL

Repository installs are resolved to the highest matching version, downloaded to the cache, checked against the index SHA-256, and then installed. Before any state change, ULPM verifies the signature, manifest, declared dependencies and publisher fingerprint.

Aliases: `-i`, `add`, `-a`.

### `remove`

```bash
ulpm remove [--purge] <name|app_id>
```

| Option | Description |
| :--- | :--- |
| `--purge` | Also delete `~/.var/app/<name>`, `~/.var/app/<app_id>` and local overrides |

Removes the package directory, installed LPK, desktop launcher, icons and database entry.

Aliases: `-r`, `rm`, `uninstall`.

### `upgrade`

```bash
ulpm upgrade [app_id]
```

With no argument:

- Refreshes repository indexes.
- Upgrades repository-tracked packages whose cached index advertises a higher version.
- Reinstalls packages whose recorded origin is an HTTP(S) URL by downloading that URL again.

All repository upgrades are committed as one atomic transaction.

With an argument, performs an atomic transaction install for that package ID.

Alias: `-u`.

### `update` / `refresh`

```bash
ulpm update [repository]
ulpm refresh [repository]
```

Downloads and verifies repository indexes only. This does not upgrade installed applications.

### `search`

```bash
ulpm search [--repo <name>] [--exact] <query>
```

| Option | Description |
| :--- | :--- |
| `--repo`, `-r <name>` | Restrict repository results to one repository |
| `--exact`, `-e` | Match the ID or name exactly instead of a substring |

Searches configured repositories, GitHub releases compatible with the host architecture, and, on Debian-like systems, `apt-cache`. If matching assets are found, ULPM offers an interactive numbered selection and can install selected LPK, AppImage, Debian or APT candidates. Interactive selection requires a terminal.

Alias: `-s`.

### `list`

```bash
ulpm list
```

Lists installed applications with name, version, package size and app ID.

Aliases: `-l`, `ls`.

### `info`

```bash
ulpm info <name|app_id>
```

Prints the installed package manifest as formatted JSON, plus the package path and size.

### `inspect`

```bash
ulpm inspect <package.lpk>
```

Reports the signature status:

- `valid and trusted`
- `unsigned package`
- `signature valid, publisher key not trusted`
- invalid or unreadable

Then prints the embedded manifest.

## Execution and sandbox

### `run`

```bash
ulpm run [flags] <name|app_id|package.lpk> [-- app_args...]
```

The target is resolved and signature-checked before execution. Without a working Bubblewrap sandbox, execution is refused unless `ULPM_UNSAFE_NO_SANDBOX=1` is set.

| Flag | Effect |
| :--- | :--- |
| `--gaming` | Enable GPU, DRI, audio, input, hidraw and USB access |
| `--strict` | Disable network, GPU/DRI and input, isolate `$HOME`, disable Downloads, and use the seccomp filter if configured |
| `--desktop` | Enable GUI, GPU and audio |
| `--offline`, `--no-net` | Disable network access |
| `--net` | Re-enable network access (overrides a manifest default within the current run) |
| `--no-gpu` | Disable GPU and `/dev/dri` access |
| `--no-audio` | Disable audio devices and sockets |
| `--no-gui` | Disable X11/Wayland; also isolates IPC |
| `--no-input` | Disable `/dev/input` and gamepad access |
| `--bind <host>:<dest>` | Bind an existing host path read-write into the sandbox |

Arguments after `--` are passed to the application. If the target is followed by non-flag arguments without `--`, they are also treated as application arguments.

A local package can be executed directly:

```bash
ulpm ./hello_amd64.lpk
```

### `stream`

```bash
ulpm stream <source> [run flags] [-- app_args...]
```

Sources:

- `https://` or `http://` URL
- Local `.lpk` path or `file://` URL
- `owner/repo` or `owner/repo@tag` (selects a `.lpk` release asset for the host architecture)

The package is copied to `/dev/shm` when at least 256 MiB is free, otherwise to `$XDG_RUNTIME_DIR` or the ULPM cache. It is removed on exit with `shred` when available. Sandbox flags are the same as `run`.

### `override`

```bash
ulpm override <name|app_id> <option|key=value>...
```

Writes a persistent JSON fragment to `~/.config/ulpm/overrides/<app_id>.json`, merged over the package manifest at runtime.

| Option | Sets |
| :--- | :--- |
| `--no-net`, `--offline` | `permissions.network = false` |
| `--net` | `permissions.network = true` |
| `--no-gpu` | `permissions.gpu = false`, `permissions.devices.dri = false` |
| `--gpu` | `permissions.gpu = true`, `permissions.devices.dri = true` |
| `--isolate-home` | `permissions.filesystem.home = "isolated"` |
| `--share-home`, `--share-home-rw` | `permissions.filesystem.home = "read-write"` |
| `--share-home-ro` | `permissions.filesystem.home = "read"` |
| `--gaming` | GPU, audio, DRI, input, hidraw, USB |
| `--strict` | No network, no GPU/DRI, isolated home, no Downloads |
| `key=value` | Arbitrary jq path; a leading `.` is optional |

Examples:

```bash
ulpm override firefox --no-net
ulpm override blender --share-home
ulpm override myapp permissions.devices.kvm=true
ulpm override myapp '.permissions.filesystem.downloads="read"'
```

### `permissions`

```bash
ulpm permissions <name|app_id>
ulpm permissions reset <name|app_id>
```

Shows the effective merged permissions and whether local overrides are active. `reset` deletes the override file.

Alias: `perms`.

### `runtime`

```bash
ulpm runtime list
ulpm runtime install <shared-runtime.lpk>
```

Shared runtimes are installed under:

```text
~/.local/share/ulpm/runtimes/<id>/<version>/<arch>/<abi>/
```

A runtime package must be signed, architecture-compatible, and have `"shared": true` in its manifest. A sandbox requests one with `runtime` and `runtime_abi` manifest fields. If the requested runtime is absent, ULPM warns and falls back to the host base.

## Packaging and distribution

### `pack`

```bash
ulpm pack [flags] <source> [name] [out.lpk] [version]
```

| Flag | Description |
| :--- | :--- |
| `--no-scan`, `--fast` | Skip ELF library bundling |
| `--shared` | Mark the package as a shared runtime (`shared: true`) |
| `--runtime <id>` | Record a shared runtime dependency |
| `--dependency`, `--depends <id[op version]>` | Add a dependency; repeatable |

`op` is one of `>=`, `<=`, `==`, `=`, `>`, `<`.

Supported sources:

- Directory
- Pre-structured directory containing `meta/manifest.json` (or `manifest.json`)
- AppImage
- Debian `.deb`
- Tar archive (`.tar`, `.tar.gz`, `.tgz`, ...)
- Zip archive

The default output is `<name>_<arch>.lpk`, the default version is `1.0.0`, and the result is always signed. See [Packaging](packaging.md).

### `deb-pack`

```bash
ulpm deb-pack [pack flags] <pkg|file.deb|owner/repo> [name] [out.lpk] [version]
```

Accepts an APT package name, a local `.deb`, a GitHub repository or `owner/repo[@tag]`. Downloads the package and direct library dependencies available through APT, extracts them, strips host-provided core/graphics/audio libraries, creates an `AppRun`, and hands the result to `pack`.

Flags: `--no-scan`, `--fast`, `--shared`, `--runtime <id>`.

### `repo`

```bash
ulpm repo <action> [arguments]
```

| Action | Syntax | Description |
| :--- | :--- | :--- |
| `list` | `ulpm repo list` | List configured repositories and enabled state |
| `add` | `ulpm repo add <name> <url> <public-key.pub>` | Add and verify a repository; pins the key |
| `remove`, `rm` | `ulpm repo remove <name>` | Remove configuration, pinned key and cache |
| `enable` | `ulpm repo enable <name>` | Enable a repository |
| `disable` | `ulpm repo disable <name>` | Disable a repository |
| `update`, `refresh` | `ulpm repo update [name]` | Fetch and verify indexes |
| `verify` | `ulpm repo verify [name]` | Re-verify cached indexes |
| `search` | `ulpm repo search <query>` | Search cached indexes; refreshes first |
| `install` | `ulpm repo install <app-id> [repo]` | Install through the transaction engine |
| `index`, `create-index` | `ulpm repo index <directory> <private-key>` | Create and sign `index.json` |

`add` accepts an HTTPS URL or a local directory. The public key is validated as Ed25519, its fingerprint is stored, the index is downloaded and verified, and the key is added to the LPK trust store.

### `deps`

```bash
ulpm deps check <manifest.json|name|app_id>
ulpm deps resolve <app_id>
```

`check` validates that every declared dependency is installed and version-compatible. `resolve` builds a dependencies-first installation plan from verified repository indexes, detects cycles, and prefers the newest compatible version.

### `transaction`

```bash
ulpm transaction install [--repo <name>] <app_id> [app_id ...]
ulpm transaction recover
```

`install` resolves all requested packages and their dependencies, downloads and verifies everything, snapshots the current state, commits the changes, and restores the snapshot on failure. `recover` applies the WAL of an interrupted transaction.

Alias: `txn`.

## Security and maintenance

### `keygen`

```bash
ulpm keygen [name]
```

Creates an Ed25519 keypair in `~/.config/ulpm/keys/`:

- `<name>.priv` (0600)
- `<name>.pub` (0644)

The public key is added to the trust store. The default name is `default`.

### `sign`

```bash
ulpm sign <package.lpk> [private-key]
```

Strips an existing signature and appends a new 104-byte Ed25519 trailer. Without a key argument, the default keypair is created if needed.

### `trust`

```bash
ulpm trust <public-key.pub>
```

Registers an Ed25519 public key in `~/.config/ulpm/trusted_keys/`. The filename is preserved; a different key cannot overwrite an existing filename.

### `token`

```bash
ulpm token [PAT]
ulpm token
```

Stores a GitHub personal access token in `~/.config/ulpm/ulpm.conf` (0600) for higher API rate limits. Without an argument, prompts on the terminal. The token must contain only alphanumerics, `_`, `.` or `-`.

Alias: `auth`.

### `doctor`

```bash
ulpm doctor
```

Runs environment, sandbox, mount, portal, GPU, dependency, key and GitHub API diagnostics. Exits `0` even when individual checks report warnings or failures; inspect the output.

Aliases: `check`, `-d`, `--doctor`.

### `history`

```bash
ulpm history [app_id]
```

Lists retained previous package snapshots in `~/.local/share/ulpm/history/`.

### `rollback`

```bash
ulpm rollback <name|app_id>
```

Restores the most recent historical snapshot, verifies its signature and publisher pin, saves the current package as a new history entry, updates the database and recreates the launcher.

### `clean`

```bash
ulpm clean
```

Unmounts orphaned FUSE sessions under the ULPM cache and removes temporary mount, build and wrapper leftovers. Active mount points are skipped.

### `integrate`

```bash
ulpm integrate
```

Registers the `application/x-lpk` MIME type and a desktop handler that runs packages with `ulpm run %f`.

### `self-update`

```bash
ulpm self-update [owner/repo]
```

Downloads the latest GitHub release tarball, checks archive paths and entry types, backs up the current engine, and replaces `bin/ulpm` and the library directory. It does not verify a package signature for the update; see [Security](security.md).

### `completion`

```bash
ulpm completion
```

Prints a Bash completion script. The installer normally installs it automatically.

## Environment quick reference

| Variable | Purpose |
| :--- | :--- |
| `ULPM_STRICT_SIGNATURES` | `true` (default) rejects untrusted keys; `false` accepts valid signatures from untrusted keys |
| `ULPM_ALLOW_UNSIGNED` | With strict signatures off, `1` allows unsigned packages |
| `ULPM_ALLOW_KEY_ROTATION` | `1` acknowledges an expected publisher key change |
| `ULPM_UNSAFE_NO_SANDBOX` | `1` allows execution without Bubblewrap (dangerous) |
| `ULPM_DATA_HOME`, `ULPM_CONFIG_HOME`, `ULPM_CACHE_HOME`, `ULPM_STATE_HOME` | Override XDG roots |
| `ULPM_NO_SCAN` | `1` skips ELF library bundling during `pack` |
| `ULPM_ZSTD_LEVEL` | mksquashfs zstd level, `1`-`22` (default `15`) |
| `GITHUB_TOKEN` | GitHub API token (overrides the saved token) |

Full details are in [Configuration](configuration.md).
