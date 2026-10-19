# Development

ULPM is implemented in Bash with no build step. Sources run directly from a checkout.

## Prerequisites

Required to run the engine:

- Bash 4.4+
- `jq`, `openssl`, `curl`, `flock`, `tar`, `sha256sum`, `find`, `awk`

Required for packaging:

- `mksquashfs`, `unsquashfs`, `file`, `readelf`, `zstd`

Required for execution:

- `bubblewrap`
- `squashfuse` (preferred) or `unsquashfs`

Required for tests and lint:

- `shellcheck`
- `bats` is not needed; the suite is self-contained

Recommended:

- `xdg-dbus-proxy`, `fuse-overlayfs`, `python3` (safer archive extraction)

## Run from source

```bash
git clone <repository>
cd ulpm
./bin/ulpm --help
./bin/ulpm doctor
./bin/ulpm run ./some.lpk
```

`bin/ulpm` locates `lib/` relative to itself, so a checkout works without installation. To use a specific module directory:

```bash
ULPM_LIB_DIR=/path/to/lib ./bin/ulpm version
```

### Debugging

```bash
bash -x ./bin/ulpm pack ./app
NO_COLOR=1 ./bin/ulpm list
```

## Test suite

```bash
bash tests/run.sh
```

The suite creates a private temporary `HOME` and XDG tree, sources the modules and exercises:

- App ID/name validation and path safety
- Signature creation, verification, tampering detection and trust
- Manifest validation and override merging
- Packing, repositories, indexes and dependency parsing
- Atomic install/rollback behavior
- Sandbox argument generation and fail-closed policy
- Transaction and utility behavior

It prints TAP-like output and a summary:

```text
34 tests, 0 failure(s)
```

Exit code is non-zero when any test fails. Network is not required.

### Adding a test

Use the helpers at the top of `tests/run.sh`:

```bash
assert_true "label" command args...
assert_false "label" command args...
assert_eq "label" "expected" "actual"
```

Keep tests hermetic: never touch the real `$HOME`, always use `$TEST_TMP` and the exported test paths.

## ShellCheck

CI enforces:

```bash
bash -n bin/ulpm bin/ulrm lib/*.sh install.sh tests/*.sh
shellcheck -x bin/ulpm bin/ulrm lib/*.sh install.sh tests/*.sh
```

Notes:

- ShellCheck resolves `# shellcheck source=` paths relative to the working directory, so tests use `# shellcheck source=lib/utils.sh`.
- `set -Eeuo pipefail` is used throughout; `set -u` safe expansions are expected.
- Intentional patterns such as unused signal-handler functions carry documented `disable` directives.

Format a change with all checks before pushing:

```bash
shellcheck -x bin/ulpm bin/ulrm lib/*.sh install.sh tests/*.sh && bash tests/run.sh
```

## Code conventions

- One responsibility per module under `lib/`.
- Commands are `cmd_<name>` functions; internals are prefixed with `_` (for example `_repo_verify_index`).
- Always quote expansions and use `--` before paths.
- Prefer `mktemp`, `durable_write`, `sync_file` and atomic `mv` for state changes.
- Never trust manifest, archive or repository data: validate types, characters and paths.
- Fail closed: refuse unsafe operations instead of degrading silently. Warnings are for conditions the user explicitly allowed.
- Use `log`, `info`, `warn`, `error` from `lib/utils.sh`; `NO_COLOR` is honored.
- Do not add a command without updating `show_help` in `bin/ulpm` and the completion word list in `cmd_completion`.
- Keep package format changes behind `ULPM_FORMAT_VERSION`.

### Adding a command

1. Implement `cmd_<name>` in the appropriate module.
2. Add the dispatch entry in `bin/ulpm`.
3. Document it in `docs/cli-reference.md` and `show_help`.
4. Add the command to the completion list in `cmd_completion`.
5. Add tests to `tests/run.sh`.
6. Run ShellCheck and the suite.

### Adding a manifest field

1. Extend the schema validation in `lib/pack.sh` (`_pack_validate_manifest`).
2. Decide whether the format version must increase.
3. Handle the fallback for older packages.
4. Document it in `docs/lpk-format.md`.
5. Add positive and negative tests.

## Environment isolation in tests

`tests/run.sh` exports:

```text
HOME
XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME, XDG_STATE_HOME
ULPM_DATA_HOME, ULPM_CONFIG_HOME, ULPM_CACHE_HOME, ULPM_STATE_HOME
ULPM_APPS_DIR, ULPM_KEYS_DIR, ULPM_DB
```

Any new test must respect these paths. See [Configuration](configuration.md).

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

| Job | Steps |
| :--- | :--- |
| lint | `bash -n` on all shell files, then ShellCheck |
| tests | Install `openssl jq squashfs-tools`, run `bash tests/run.sh` |

Add tools to the CI install step if a new feature requires them.

## Repository manager (`ulrm`)

`bin/ulrm` is standalone but uses `ulpm repo index` semantics. Test it with a temporary `HOME` and `REPO_DIR`, then verify:

```bash
R=0 ulrm rebuild
ulpm repo verify myrepo
```

## Release checklist

- [ ] `ULPM_VERSION` updated in `bin/ulpm`
- [ ] `ULPM_FORMAT_VERSION` updated only if the manifest schema changed
- [ ] `README.md` and `docs/` updated
- [ ] `shellcheck` clean
- [ ] `bash tests/run.sh` green
- [ ] `install.sh` smoke-tested for user and system installs
- [ ] Changelog or release notes written
- [ ] Tag created and release assets published
- [ ] Example repository index rebuilt and re-signed
- [ ] Publisher key fingerprint published out of band

## Related documents

- [Architecture](architecture.md)
- [Contributing](../CONTRIBUTING.md)
- [Security model](security.md)
- [Packaging](packaging.md)
