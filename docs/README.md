# ULPM Documentation

**ULPM (Universal Linux Package Manager)** is a rootless, daemonless package manager and sandboxed application runtime for Linux. It builds, signs, distributes, installs and runs `.lpk` bundles with Bubblewrap isolation.

- **Engine version:** 6.0.0
- **Package format:** LPK v5 (`format_version: 5`)
- **License:** GPL-3.0
- **Platform:** Linux only, Bash 4+

## Start here

| Document | What it covers |
| :--- | :--- |
| [Installation](installation.md) | Requirements, installer options, install layout, updates and removal |
| [Quick start](quickstart.md) | Build, run, install and remove your first package in a few minutes |
| [CLI reference](cli-reference.md) | Every command, option and alias |
| [Troubleshooting](troubleshooting.md) | Diagnostics, common errors and safe workarounds |

## Guides

| Document | What it covers |
| :--- | :--- |
| [Packaging](packaging.md) | `pack`, `deb-pack`, AppImage/Deb/Tar/Zip conversion, signing and publishing |
| [Repositories](repositories.md) | Signed repository indexes, `ulpm repo`, `ulrm`, local and HTTPS hosting |
| [Dependencies and transactions](dependencies-transactions.md) | Dependency specs, DAG resolution, WAL transactions, history and rollback |
| [Permissions and sandbox](permissions.md) | Manifest permissions, runtime profiles, overrides and data isolation |
| [Configuration](configuration.md) | XDG paths, environment variables, database and file formats |
| [Security model](security.md) | Ed25519 signatures, trust store, publisher pinning and threat model |

## Reference

| Document | What it covers |
| :--- | :--- |
| [LPK format](lpk-format.md) | SquashFS layout, manifest schema, signature trailer and reproducibility |
| [Architecture](architecture.md) | Modules, execution flows and design constraints |
| [Development](development.md) | Repository layout, tests, CI, debugging and release checklist |

## Core concepts

| Concept | Definition |
| :--- | :--- |
| **LPK** | A compressed SquashFS image with a manifest and an optional 104-byte Ed25519 trailer. |
| **App ID** | A stable identifier such as `io.lpk.firefox`. Used for storage, overrides and D-Bus isolation. |
| **App name** | The install directory and launcher name, for example `firefox`. |
| **Repository** | A directory or HTTPS endpoint containing `index.json`, `index.json.sig` and package files. |
| **Publisher** | The Ed25519 key embedded in a package trailer. Its SHA-256 fingerprint is pinned per application. |
| **Runtime** | An optional shared base layer (`shared: true`) bound into a sandbox at `/usr`, `/lib`, `/bin`. |
| **Transaction** | An atomic multi-package operation protected by a write-ahead log (WAL) and LIFO rollback. |
| **Override** | A user-owned JSON fragment merged over a package manifest at runtime. |

## Documentation conventions

- Commands are shown without `sudo`; normal ULPM operation is rootless.
- `<angle-brackets>` are placeholders. Do not type the brackets.
- `$HOME` refers to the invoking user's home directory.
- `~/.local/share/ulpm` is the default data root and follows `XDG_DATA_HOME`.
- Examples use `io.lpk.example`; replace it with the real package ID.
- Security-sensitive variables are documented with their exact spelling and accepted values.

## Project links

- [Project README](../README.md)
- [Contributing](../CONTRIBUTING.md)
- [Security policy](../SECURITY.md)
- [License](../LICENSE)
