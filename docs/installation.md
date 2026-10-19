# Installation

ULPM runs on Linux and installs entirely in user space by default. A system-wide installation is optional.

## Requirements

### Runtime

| Component | Required | Purpose |
| :--- | :---: | :--- |
| Linux kernel with unprivileged user namespaces | Yes | Bubblewrap sandboxing |
| Bash >= 4 | Yes | Engine and installer |
| `bubblewrap` (`bwrap`) | Yes | Application/rootfs isolation |
| `squashfuse` + `fuse3` | Yes | Mounting LPK images without extraction |
| `squashfs-tools` (`unsquashfs`, `mksquashfs`) | Yes | Reading and building LPK images |
| `jq` | Yes | Manifest, index and database handling |
| `curl` | Yes | Downloads, GitHub API and repository sync |
| `openssl` with Ed25519 support | Yes | Package signing and verification |
| `flock`, `sync` (`util-linux`) | Yes | Database locking and durable writes |
| `tar`, `coreutils`, `findutils`, `gawk` | Yes | Safe extraction and file operations |
| `xdg-dbus-proxy` | Recommended | Filtered session D-Bus access |
| `file`, `readelf` (`binutils`) | Packaging | Entrypoint detection and ELF inspection |
| `dpkg-deb` or `ar` | `deb-pack` | Debian archive extraction |
| `apt-get`, `apt-cache` | `deb-pack`/APT search | Downloading Debian packages |
| `python3` | Optional | Faster archive extraction and `fsync` helpers |
| `shred` | Optional | Secure deletion of streamed packages |

ULPM does not require root to install, build, sign or run applications.

### Supported architectures

The engine normalizes and recognizes:

`amd64`/`x86_64`, `arm64`/`aarch64`, `armhf`/`armv7`, `i386`/`i686`, `riscv64`, `ppc64le`, `s390x`, `loongarch64`, `mips64`, `mips`, `sparc64`, plus `all`/`any`.

Packages must match the host architecture or declare `arch: "all"`.

## Install with the official installer

```bash
curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | bash
```

The installer provides an interactive menu:

1. **Rootless installation** in `~/.local/bin/ulpm`
2. **System-wide installation** in `/usr/local/bin/ulpm` (via `sudo`/`doas`)
3. **APT installation** on Debian/Ubuntu from the signed ULPM repository

When run from a source checkout, it copies the local `bin/` and `lib/` tree. When run remotely, it downloads the files and verifies them against `SHA256SUMS` when available.

### Installer options

```bash
./install.sh [OPTIONS]
```

| Option | Description |
| :--- | :--- |
| `--user` | Rootless install in `~/.local/bin` and `~/.local/lib/ulpm` |
| `--system` | System-wide install in `/usr/local/bin` and `/usr/local/lib/ulpm` |
| `--bin-dir <dir>` | Custom absolute binary directory |
| `--apt` | Install from the signed APT repository (Debian/Ubuntu) |
| `--ref <ref>` | Git branch or tag used by the remote installer (default: `main`) |
| `-y`, `--yes` | Assume yes for prompts |
| `--no-deps` | Do not install missing host packages automatically |
| `--with-ulrm` | Install the `ulrm` repository manager |
| `--without-ulrm`, `--no-ulrm` | Do not install `ulrm` |
| `--integrate` | Register MIME/desktop integration |
| `--no-integrate` | Skip desktop integration |
| `--uninstall` | Remove ULPM from the selected scope |
| `-h`, `--help` | Show installer help |

Examples:

```bash
./install.sh --user --with-ulrm --yes
./install.sh --system --no-integrate
ULPM_REF=v6.0.0 ./install.sh --user
```

### Manual installation

From a checkout:

```bash
./install.sh --user
```

Or copy the files manually:

```bash
install -Dm755 bin/ulpm ~/.local/bin/ulpm
install -Dm644 lib/*.sh ~/.local/lib/ulpm/
install -Dm755 bin/ulrm ~/.local/bin/ulrm   # optional
```

Make sure `~/.local/bin` is in `PATH`. The engine discovers modules in `../lib/ulpm`, `../lib`, `~/.local/lib/ulpm`, `/usr/local/lib/ulpm` and `/usr/lib/ulpm`.

## APT installation (Debian/Ubuntu)

```bash
./install.sh --apt
```

This imports the repository signing key, adds `https://ruraam.github.io/ulpm` to APT, and installs the `ulpm` package. Use this method if you prefer distro-managed updates.

## Post-install checks

```bash
ulpm --version
ulpm doctor
```

`ulpm doctor` checks:

- Bubblewrap and unprivileged namespaces
- Squashfuse and FUSE availability
- `xdg-dbus-proxy` and the desktop portal
- GPU/DRI devices
- Required command-line tools
- Keypair and trust store
- GitHub API authentication

Enable shell completion:

```bash
ulpm completion
```

The installer writes a Bash completion file to `~/.local/share/bash-completion/completions/ulpm` (rootless) or `/usr/local/share/bash-completion/completions/ulpm` (system). Add `ulpm completion` to your shell startup if you prefer runtime completion.

Register `.lpk` double-click handling:

```bash
ulpm integrate
```

## Installation layout

### Rootless

| Path | Content |
| :--- | :--- |
| `~/.local/bin/ulpm` | Main executable |
| `~/.local/bin/ulrm` | Repository manager (optional) |
| `~/.local/lib/ulpm/` | Engine modules |
| `~/.local/share/ulpm/` | Data root (`ULPM_DATA_HOME`) |
| `~/.config/ulpm/` | Keys, trust store, overrides, repositories |
| `~/.cache/ulpm/` | Downloads, mounts, API cache, transactions |
| `~/.local/state/ulpm/` | WAL journal |

### System-wide

| Path | Content |
| :--- | :--- |
| `/usr/local/bin/ulpm` | Main executable |
| `/usr/local/bin/ulrm` | Repository manager (optional) |
| `/usr/local/lib/ulpm/` | Engine modules |

System-wide installations still use each user's XDG directories for data, keys and applications.

## Update ULPM

From GitHub releases:

```bash
ulpm self-update Ruraam/ulpm
```

You can define a default repository with `ULPM_GITHUB_REPO=owner/repo`.

> [!WARNING]
> `ulpm self-update` validates archive paths and blocks device nodes, but it does **not** verify a publisher signature for the engine update. Only update from a repository you trust.

For installer-managed installations, re-run the installer or use your package manager. The `--ref` option can pin a tag:

```bash
ULPM_REF=v6.0.0 ./install.sh --user
```

## Uninstall

```bash
./install.sh --uninstall
```

The uninstaller removes the binary, modules, completion, MIME/desktop entries and ULPM data for the selected scope. It can back up your configuration and keys first. Application persistent data under `~/.var/app/<app_id>` is not removed automatically.

To remove individual applications and their sandbox data:

```bash
ulpm remove --purge <app>
```

## Next steps

- [Quick start](quickstart.md)
- [CLI reference](cli-reference.md)
- [Configuration](configuration.md)
