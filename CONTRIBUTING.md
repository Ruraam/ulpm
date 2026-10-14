# Contributing to ULPM

Thanks for helping! ULPM is a Bash project; the guidelines below keep it boring and reliable.

## Setup
```bash
git clone https://github.com/Ruraam/ulpm && cd ulpm
make check      # syntax + whitespace guard + shellcheck
make test       # bats suites in tests/ (requires bats)
```

## Layout
| Path | Role |
|------|------|
| `bin/ulpm` | CLI entry point and command dispatch |
| `lib/utils.sh` | Logging, locking, validation helpers, config, self-update |
| `lib/crypto.sh` | Ed25519 keys, signing, verification, trust policy |
| `lib/pack.sh`, `lib/deb.sh` | `.lpk` building (directories, archives, AppImage, `.deb`) |
| `lib/sandbox.sh`, `lib/run.sh`, `lib/stream.sh` | Bubblewrap launch (app and RootFS modes), `run`/`stream` |
| `lib/manage.sh` | install, remove, list, search, upgrade, inspect |
| `install.sh` | Dependency-aware installer |

## Rules
1. **Do not break public surface**: command names, flags, on-disk paths
   (`~/.local/share/ulpm`, `~/.var/app/<id>`, `~/.config/ulpm`) and the `.lpk` v4 format.
2. **Treat package contents as hostile.** Anything read from a manifest or archive (id, name,
   paths, exec) must be validated (`is_safe_app_id`, `is_safe_app_name`) before it reaches a path,
   the install database or a command line. Never build shell code or `sed` scripts from it.
3. Scripts run under `set -euo pipefail`: beware of `((i++))` (fails when `i` is 0) and unguarded
   `shift`.
4. Quote everything; keep functions small; prefer `local`. Indent with 4 spaces (see `.editorconfig`).
5. Security-relevant behaviour changes need a line in `SECURITY.md` or `CHANGELOG.md`.
6. Add or update a bats test for every bug fix.

## Pull requests
Keep them focused, fill in the template, and make sure `make check` is green.
