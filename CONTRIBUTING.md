# Contributing to ULPM

Thanks for helping! ULPM is a Bash project; the guidelines below keep it boring, predictable, and reliable.

## Setup
```bash
git clone https://github.com/Ruraam/ulpm && cd ulpm
make check      # syntax + whitespace guard + shellcheck
make test       # bats suites in tests/ (requires bats)
```

## Layout
| Path | Role |
|------|------|
| `bin/ulpm` | CLI entry point, versioning, and top-level command dispatch |
|`lib/utils.sh` | Logging, locking, path validation, declarative overrides engine, doctor |
| `lib/crypto.sh` | Ed25519 streaming keys, package signing, verification, trust management |
| `lib/pack.sh`, `lib/deb.sh` | `.lpk` v5 bundle builder (directories, archives, offset-safe AppImage, `.deb`) |
| `lib/sandbox.sh`, `lib/run.sh`, `lib/stream.sh` | Bubblewrap sandbox engine (App & RootFS), execution profiles (`--gaming`, `--strict`, `--desktop`), ephemeral RAM streaming |
| `lib/manage.sh` | Lifecycle (`install`, `remove`, `list`, `search`, `upgrade`, `inspect`), declarative permissions,overrides management, shared runtimes |
| `install.sh` | Universal dependency-aware installer, desktop/MIME integrator, and uninstaller |

## Rules
1. **Do not break public surface**: command names, flags, on-disk paths
(`~/.local/share/ulpm`, `~/.var/app/<id>`, `~/.config/ulpm`, `~/.config/ulpm/overrides`, `~/.local/share/ulpm/runtimes`), and backward compatibility with `.lpk` v4 and v5 format manifests.
2. **Treat package contents as hostile.** Anything read from a manifest or archive (id,name,
paths, exec, D-Bus namespaces) must be validated (`is_safe_app_id`, `is_safe_app_name`, `_ulpm_valid_bind_dest`) before it reaches a path,
the install database, or a command line. Never build shell code or `sed` scripts dynamically from it.
3. **Bashrobustness**: Scripts run under `set -euo pipefail`. Beware of `(( i++ ))` (fails when `i` is 0; use `(( i += 1 ))` or `i=$(( i + 1 ))`) and unguarded `shift`.
4. **Code style**: Quote everything; keep functions small and single-purpose; prefer `local`. Indent with 4 spaces (see `.editorconfig`).
5. **Traceability**: Security-relevant behavior changes, permission updates, or schema adjustments require anentry in `SECURITY.md` or `CHANGELOG.md`.
6. **Testing**: Add or update abats test in `tests/` for every bug fix or new feature.

## Pull requests
Keep them focused,adhere to the POSIX/Bash core utils without adding heavy external dependencies, and ensure `make check` is completely green before submitting.
