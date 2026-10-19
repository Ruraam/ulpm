# Configuration

ULPM follows the XDG Base Directory specification and keeps all mutable state in user-owned directories.

## Directory layout

| Purpose | Default path | Override |
| :--- | :--- | :--- |
| Data root | `~/.local/share/ulpm` | `ULPM_DATA_HOME` or `XDG_DATA_HOME` |
| Installed apps | `~/.local/share/ulpm/apps` | `ULPM_APPS_DIR` |
| Shared runtimes | `~/.local/share/ulpm/runtimes` | `ULPM_RUNTIMES_DIR` |
| History | `~/.local/share/ulpm/history` | derived from data root |
| Package database | `~/.local/share/ulpm/installed.db` | `ULPM_DB` |
| Config root | `~/.config/ulpm` | `ULPM_CONFIG_HOME` or `XDG_CONFIG_HOME` |
| Private keys | `~/.config/ulpm/keys` | `ULPM_KEYS_DIR` |
| Trusted keys | `~/.config/ulpm/trusted_keys` | — |
| Overrides | `~/.config/ulpm/overrides` | `ULPM_OVERRIDES_DIR` |
| Repositories | `~/.config/ulpm/repos` | — |
| Secrets/config | `~/.config/ulpm/ulpm.conf` | `ULPM_CONFIG_FILE` |
| Cache root | `~/.cache/ulpm` | `ULPM_CACHE_HOME` or `XDG_CACHE_HOME` |
| WAL | `~/.local/state/ulpm/wal` | `ULPM_STATE_HOME` or `XDG_STATE_HOME` |
| Per-app data | `~/.var/app/<app_id>` | — |
| Desktop launchers | `~/.local/share/applications` | `XDG_DATA_HOME` |
| Icons | `~/.local/share/icons/hicolor/{256x256,512x512}/apps` | `XDG_DATA_HOME` |

Standard XDG variables are honored:

- `XDG_DATA_HOME`
- `XDG_CONFIG_HOME`
- `XDG_CACHE_HOME`
- `XDG_STATE_HOME`
- `XDG_RUNTIME_DIR`
- `XDG_DATA_DIRS`

ULPM-specific roots take precedence over the corresponding XDG root.

## Installed application layout

```text
~/.local/share/ulpm/apps/<name>/
  <name>.lpk

~/.local/share/ulpm/history/
  <app_id>__<timestamp>__<version>__<pid>.lpk
  <app_id>__<timestamp>__<version>__<pid>.json

~/.var/app/<app_id>/
  home/
  config/
  data/
  cache/
  tmp/
```

## Package database

Default file:

```text
~/.local/share/ulpm/installed.db
```

It is a pipe-separated text file, mode `0600`:

```text
id|name|version|timestamp|origin|publisher_fingerprint
```

| Field | Meaning |
| :--- | :--- |
| `id` | App ID, for example `io.lpk.firefox` |
| `name` | Install name, for example `firefox` |
| `version` | Installed version |
| `timestamp` | Unix epoch seconds at installation |
| `origin` | `local`, a path, an HTTP(S) URL, `repo:<repo>:<id>`, or `apt:<package>` |
| `publisher_fingerprint` | SHA-256 of the DER Ed25519 public key, or empty if unsigned |

Older five-field rows are still read. New writes always use six fields. The database is updated through a temporary file, `fsync`, and atomic rename under an exclusive `flock` lock:

```text
~/.local/share/ulpm/installed.db.lock
```

The lock path can be overridden with `ULPM_LOCK` or `ULPM_LOCK_FILE`.

Do not edit the database manually while ULPM is running.

## History metadata

Each retained package has a JSON sidecar:

```json
{
  "id": "io.lpk.example",
  "name": "example",
  "version": "1.0.0",
  "origin": "repo:local:io.lpk.example",
  "package": "io.lpk.example__1700000000000000000__1.0.0__12345.lpk"
}
```

`ulpm history` reads these files. `ulpm rollback` selects the newest snapshot for the requested app.

## Repository configuration

```text
~/.config/ulpm/repos/<name>.json
~/.config/ulpm/repos/<name>.pub
~/.cache/ulpm/repos/<name>/index.json
~/.cache/ulpm/repos/<name>/index.json.sig
~/.cache/ulpm/repos/<name>/base-url
```

`<name>.json`:

```json
{
  "schema": 1,
  "name": "myrepo",
  "url": "https://repo.example.com/ulpm",
  "key_fingerprint_sha256": "64 lowercase hex characters",
  "enabled": true
}
```

The configuration is mode `0600`. The public key is mode `0644`. The pinned fingerprint is checked on every update and search.

### Repository index

`index.json` is canonicalized JSON with sorted packages:

```json
{
  "format": "ulpm-repository-v1",
  "generated": "2026-10-19T12:00:00Z",
  "packages": [
    {
      "id": "io.lpk.example",
      "name": "example",
      "version": "1.0.0",
      "arch": "amd64",
      "file": "example_amd64.lpk",
      "sha256": "64 lowercase hex characters",
      "description": "Example application",
      "dependencies": [],
      "runtime": null,
      "runtime_abi": null,
      "abi": null
    }
  ]
}
```

Rules enforced by `ulpm repo index` and `ulpm repo update`:

- `format` must be `ulpm-repository-v1`.
- Packages are unique by `id|arch`.
- Only one version per app ID and architecture may be published.
- `file` must end in `.lpk` and must not contain `..`.
- `sha256` must be 64 lowercase hex characters.
- The index signature is a detached Ed25519 signature over the exact bytes of `index.json`.

`index.json.sig` is created with the repository private key:

```bash
ulpm repo index <directory> <private-key>
```

## Secrets file

`~/.config/ulpm/ulpm.conf` is mode `0600`:

```bash
GITHUB_TOKEN="github_pat_..."
```

Set it with:

```bash
ulpm token <PAT>
```

`GITHUB_TOKEN` in the environment takes precedence.

## Overrides

```text
~/.config/ulpm/overrides/<app_id>.json
```

The file is merged over the package manifest with a recursive JSON merge. Only override fields you intend to change:

```json
{
  "permissions": {
    "network": false,
    "devices": {
      "kvm": true
    }
  }
}
```

## Environment variables

### Paths and state

| Variable | Effect |
| :--- | :--- |
| `ULPM_DATA_HOME` | Data root |
| `ULPM_CONFIG_HOME` | Config root |
| `ULPM_CACHE_HOME` | Cache root |
| `ULPM_STATE_HOME` | State root (WAL) |
| `ULPM_APPS_DIR` | Installed application directory |
| `ULPM_RUNTIMES_DIR` | Shared runtime directory |
| `ULPM_KEYS_DIR` | Private/public key directory |
| `ULPM_OVERRIDES_DIR` | Override directory |
| `ULPM_DB` | Installed package database |
| `ULPM_LOCK`, `ULPM_LOCK_FILE` | Database lock file |
| `ULPM_CONFIG_FILE` | Secrets/config file |
| `ULPM_BIN`, `ULPM_LIB_DIR`, `ULPM_ROOT_DIR` | Engine location overrides (advanced) |

### Security and execution

| Variable | Default | Effect |
| :--- | :--- | :--- |
| `ULPM_STRICT_SIGNATURES` | `true` | Reject signatures from untrusted keys |
| `ULPM_ALLOW_UNSIGNED` | unset | `1` allows unsigned packages only when strict signatures are disabled |
| `ULPM_ALLOW_KEY_ROTATION` | unset | `1` accepts a publisher fingerprint change |
| `ULPM_UNSAFE_NO_SANDBOX` | unset | `1` allows execution without Bubblewrap |
| `ULPM_SECCOMP_FILTER` | `~/.config/ulpm/seccomp/default.bpf` | Seccomp filter used by `--strict` |
| `ULPM_DBUS_EXTRA` | unset | Extra `xdg-dbus-proxy` arguments |

### Build and packaging

| Variable | Default | Effect |
| :--- | :--- | :--- |
| `ULPM_FORMAT_VERSION` | `5` | Manifest format written by `pack` and maximum accepted version |
| `ULPM_ZSTD_LEVEL` | `15` | SquashFS zstd level, `1`-`22` |
| `ULPM_NO_SCAN` | unset | `1` skips ELF library bundling |
| `SOURCE_DATE_EPOCH` | `0` | Reproducible timestamps for payload and index |
| `ULPM_ALLOW_APPIMAGE_EXEC` | unset | `1` allows executing an AppImage as an extraction fallback |

### Network and updates

| Variable | Effect |
| :--- | :--- |
| `GITHUB_TOKEN` | GitHub API token |
| `ULPM_GITHUB_REPO` | Default `owner/repo` for `ulpm self-update` |
| `ULPM_SKIP_REPO_REFRESH` | Internal: skip index refresh during a transaction |
| `ULPM_REF` | Installer: branch or tag to download |

### UI

| Variable | Effect |
| :--- | :--- |
| `NO_COLOR` | Disable colored output |
| `TERM` | Used for terminal capability detection |

## Stream and cache locations

Streamed packages use, in order:

1. `/dev/shm`, when writable and at least 256 MiB free
2. `$XDG_RUNTIME_DIR`
3. `~/.cache/ulpm/tmp`
4. `/tmp`

They are deleted on exit, with `shred -u` when available.

The cache also contains:

```text
~/.cache/ulpm/api/          GitHub API responses (TTL-based)
~/.cache/ulpm/repos/        Verified repository indexes
~/.cache/ulpm/tmp/          Downloads and temporary files
~/.cache/ulpm/transactions/ Transaction workspaces
~/.cache/ulpm/mnt_*         Mount points
```

`ulpm clean` removes orphaned mount points and temporary build/mount directories. Repository indexes and installed state are not removed.

## File permissions

| Path | Mode |
| :--- | :--- |
| `keys/`, `trusted_keys/`, `wal/` | `0700` |
| `*.priv`, `installed.db`, repo config, `ulpm.conf` | `0600` |
| Installed LPK, public keys, index/signature | `0644` |

ULPM refuses symlinked database files, installed package files, app directories and key paths in security-sensitive operations.

## Related documents

- [CLI reference](cli-reference.md)
- [Security model](security.md)
- [Troubleshooting](troubleshooting.md)
