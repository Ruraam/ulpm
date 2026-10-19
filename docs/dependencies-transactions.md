# Dependencies and transactions

ULPM resolves dependency graphs before installation and commits multi-package operations atomically.

## Declaring dependencies

Dependencies are declared in the manifest:

```json
{
  "dependencies": [
    "io.lpk.sdk",
    {"id": "io.lpk.runtime", "version": ">=2.0.0"},
    {"id": "io.lpk.locale", "version": "1.4.2"}
  ]
}
```

Three forms are accepted:

| Form | Meaning |
| :--- | :--- |
| `"io.lpk.sdk"` | Any installed version |
| `"io.lpk.sdk>=2.0.0"` | String constraint |
| `{"id": "...", "version": ">=2.0.0"}` | Object constraint |

For object constraints:

- `>=`, `<=`, `==`, `=`, `>`, `<` are supported.
- `==` is normalized to `=`.
- A version without an operator means equality (`1.4.2` becomes `=1.4.2`).
- An empty version means any version.

When packaging:

```bash
ulpm pack ./app app app_amd64.lpk 1.0.0 \
  --dependency io.lpk.sdk \
  --depends 'io.lpk.runtime>=2.0.0'
```

## Version comparison

If `dpkg` is available, ULPM uses `dpkg --compare-versions` for Debian-compatible ordering. Otherwise it uses an internal numeric/alphanumeric comparison that understands epoch prefixes and segments separated by `.`, `-` or `+`.

For reproducible behavior across hosts, prefer simple versions such as `1.2.3`.

## Check installed dependencies

```bash
ulpm deps check <manifest.json|name|app_id>
```

Checks that every declared dependency is installed and version-compatible. Returns non-zero if anything is missing or mismatched.

Examples:

```bash
ulpm deps check ./meta/manifest.json
ulpm deps check io.lpk.firefox
```

`ulpm install` performs this check automatically for a package that declares dependencies. A missing dependency aborts the installation before any state change.

## Resolve an installation plan

```bash
ulpm deps resolve <app_id>
```

Reads verified repository indexes and prints a dependencies-first plan:

```text
Dependency installation plan (dependencies first):
  io.lpk.sdk
  io.lpk.runtime
  io.lpk.app
```

Resolution behavior:

- Installed packages that satisfy the requirement are skipped.
- The newest compatible version is selected from enabled repositories.
- Architecture must match the host or be `all`/`any`.
- A dependency cycle is reported and aborts resolution.
- Dependencies are ordered before their dependents.

`deps resolve` is a planning command. Use `transaction install` or `repo install` to apply it.

## Atomic transactions

```bash
ulpm transaction install [--repo <name>] <app_id> [app_id ...]
```

Example:

```bash
ulpm transaction install io.lpk.firefox io.lpk.vlc io.lpk.codecs
```

### Phases

1. **Refresh**: update repository indexes unless `ULPM_SKIP_REPO_REFRESH=1`.
2. **Resolve**: build the complete dependencies-first plan and detect cycles.
3. **Download**: fetch every package into a transaction workspace.
4. **Verify**: check SHA-256, signature/trust, manifest ID and version against the index, and installation-name collisions.
5. **Snapshot**: copy the current database, affected app directories, icons, launchers and history state.
6. **Journal**: write a durable WAL entry.
7. **Commit**: install each package in order with `ULPM_TRANSACTION_ACTIVE=1`.
8. **Finalize**: `fsync` state and remove the WAL entry.

If any step fails, the snapshot is restored in reverse order. `SIGINT`, `SIGTERM` and `SIGHUP` trigger the same rollback.

### `--repo`

`--repo <name>` constrains resolution of the first requested package and its dependency chain to the named repository. It requires a valid repository name.

### After a crash

```bash
ulpm transaction recover
```

Recovery reads pending WAL entries and restores the recorded snapshot. Transactions also call recovery automatically before starting a new one.

WAL location:

```text
~/.local/state/ulpm/wal/
```

Transaction workspaces:

```text
~/.cache/ulpm/transactions/
```

A rollback failure retains the snapshot and prints its path for manual recovery.

## Upgrade transactions

`ulpm upgrade` builds a transaction containing every repository-tracked application with a newer version. If the transaction fails, all upgrades are rolled back.

Standalone applications recorded with an HTTP(S) origin are re-fetched from their origin URL and installed individually.

## History and rollback

Before replacing an installed package, ULPM moves the old package into:

```text
~/.local/share/ulpm/history/
```

### List history

```bash
ulpm history
ulpm history io.lpk.firefox
```

History includes app ID, version, snapshot token and artifact name.

### Roll back

```bash
ulpm rollback <name|app_id>
```

Rollback:

1. Acquires the database lock.
2. Finds the newest snapshot for the app.
3. Verifies the historical package signature.
4. Enforces the publisher fingerprint pin.
5. Saves the current package as a new history entry.
6. Atomically replaces the installed LPK.
7. Updates `installed.db` and recreates the desktop launcher.

Because the current package is saved first, a rollback can itself be rolled back.

Rollback uses the most recent snapshot; there is no version selector. Repeated rollbacks walk backwards through retained history.

## Dependency troubleshooting

| Error | Meaning |
| :--- | :--- |
| `Missing dependency: <id>` | Dependency is not installed |
| `Dependency version mismatch` | Installed version does not satisfy the constraint |
| `Dependency '<id>' is neither installed nor available...` | No verified compatible repository provides it |
| `Dependency cycle detected at '<id>'` | Manifest graph is cyclic |
| `Resolve declared dependencies before installing...` | Use `deps resolve`/`transaction install` for the full chain |

## Related documents

- [CLI reference](cli-reference.md)
- [Repositories](repositories.md)
- [Configuration](configuration.md)
- [Troubleshooting](troubleshooting.md)
