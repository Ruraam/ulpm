<div align="center">
<img src="assets/ulpm-logo.svg" width="180" alt="ulpm logo" />
<h1>ULPM & `.lpk`</h1>
 
### **Universal Linux Package Manager & Autonomous Containerized Bundle Engine**


<p><strong><em>Lightweight, rootless, zero-daemon, sandboxed application runtime for any Linux system.</em></strong></p>

[![License: MIT](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Format](https://img.shields.io/badge/Format-.lpk%20v3-orange.svg)](#the-lpk-format)
[![Sandbox](https://img.shields.io/badge/Sandbox-Bubblewrap-green.svg)](#security-model)
[![Crypto](https://img.shields.io/badge/Signatures-Ed25519-purple.svg)](#cryptographic-verification)
[![Tested Hardware](https://img.shields.io/badge/Validated%20On-Celeron%20N4000%20(%2450%20Box)-brightgreen.svg)](#performance-philosophy)

</div>

---

>[!WARNING]
> ### ⚠️ Project Status: Experimental / Proof of Concept
>
> **ULPM** is currently in an active development and evaluation phase (**v0.3.2-beta**).
>
> - **Sandbox Scope:** While Bubblewrap provides strong filesystem and namespace isolation, session D-Bus is currently bridged to the host for desktop integration. Do not use this tool as a bullet proof sandbox to execute untrusted malware.
> - **Breaking Changes:** The `.lpk` container structure and CLI syntax may evolve before reaching version `1.0.0`.
> - **Testing:** Built and validated on Debian minimal environments (including low-power hardware). Bug reports, feature requests, and PRs are welcome!

---

## ⚡ Overview

**ULPM** is a minimalist, modern package manager designed to bridge the gap between traditional system packages (`.deb`, `.rpm`, `.AppImage`) and massive monolithic runtimes (Flatpak, Snap).

It packages applications into **`.lpk`** (*Linux Package Kit*) files—autonomous, read-only SquashFS images compressed with modern **Zstandard (zstd)** and runs them via native Linux user namespaces (**Bubblewrap**) with **zero systemoverhead**.

### Why ULPM ?

- 🚫 **Zero Daemon:** No background services consuming memory or disk I/O.
- 👤 **100% Rootless:** Install, build, update, and run applications entirely in user-space (`~/.local/share/ulpm`). No `sudo` required.
- 🛡️ **Hardened Sandbox:** Isolated filesystem, restricted network capability, separate XDG directories (`~/.var/app/<app_id>`), and strict permission gates.
- 🔑 **Cryptographically Signed:** Embedded Ed25519 payload signatures verified autonomously before every execution or installation (zero detached files).
- 🎮 **Hardware Native:** Direct zero-friction access to host GPU drivers (Mesa, DRI/VA-API, proprietary Nvidia), Wayland, X11, PipeWire, and PulseAudio.
- ⚡ **Instant Streaming &Demo:** Stream apps directly into volatile RAM/tmpfs to test software on the fly with zero footprint upon exit.
- 🧠**Smart Cache:** Intelligent HTTP header (`ETag` / `If-Modified-Since`) validation preventing duplicate downloads when running remote URLs.
- 🔄 **Universal Conversion:** Automatically turn raw `.AppImage`, `.tar.gz`, `.deb`, `.rpm`, or direct GitHub repositories into self-contained `.lpk` fat-bundles on the fly.

---

## 📊 Comparison

| Feature | Snap | Flatpak | AppImage | **ULPM (.lpk)** |
| :--- | :---: | :---: | :---: | :---: |
| **Daemonless** | ❌ (snapd required) | ✔️ | ✔️ | ✔️ **Yes** |
| **Rootless Install** | ❌ (requires root) | ⚠️ (partial) | ✔️ | ✔️ **Full user-space** |
| **Runtime Overhead** | ⚠️ Heavy startup | ⚠️ Runtimes required | ✔️ Low | 🚀 **Near-zero** |
| **Sandbox Built-in** | AppArmor (Host root) | Bubblewrap | ❌ None by default | 🛡️ **Bubblewrap Native** |
| **Mandatory Signatures**| Snap Store only | Flathub GPG | ❌ Rare | 🔑 **Ed25519 Built-in** |
| **Multi-format Builder**| Complex recipe | Complex JSON/YAML | Manual recipes | 🪄**Auto from .appimage/.deb/.rpm/tar** |

## 🚀 Installation & Requirements

### Dependencies

ULPM is designed with a **zero-daemon, minimal-overhead** philosophy. Instead of bundling redundant background runtimes, it leverages battle-tested, standard Linux utilities:

| Component| Utility | Description |
| :--- | :--- | :--- |
| **Sandboxing** |`bubblewrap` (`bwrap`) | Lightweight unprivileged user-namespace isolation |
| **Filesystem** |`squashfuse` & `fuse3` | High-performance user-space mounting for compressed images |
| **Bundle Creation** | `squashfs-tools` (`mksquashfs`) | Generates optimized $zstd$-compressed `.lpk` images |
| **Cryptography** | `openssl` & `coreutils` | Autonomous Ed25519 trailer signature verification & raw I/O |
| **Metadata Parsing** | `jq` & `file` | Fast JSON inspection and ELF binary architecture detection |
| **Transport** | `curl` | Smart conditional caching and remote repository sync |

---

### Quick Install (Automated)

The official installer auto-detects your environment, resolves dependencies across major package managers (`apt`, `pacman`, `dnf`, `zypper`, `apk`), and sets up either a **rootless** or **system-wide** installation.

#### Rootless Install (Recommended)
**Installs cleanly to `~/.local/bin/ulpm` without requiring root permissions:**
```bash
curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | bash
```
#### System-Wide Install
Installs globally to `/usr/local/bin/ulpm` for all userson the host:
```bash
curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | sudo bash
```

---

### Manual Dependency Installation

If you prefer installing dependencies manually before running the script:

**Debian / Ubuntu / Linux Mint:**
```bash
sudo apt update && sudo apt install -y bubblewrap squashfuse fuse3 squashfs-tools openssl jq file curl
```
**Arch Linux / Manjaro:**
```bash
sudo pacman -Syu --needed bubblewrap squashfuse fuse3 squashfs-tools openssl jq file curl
```
**Fedora /RHEL / CentOS Stream:**
```bash
sudo dnf install -y bubblewrap squashfuse fuse3 squashfs-tools openssl jq file curl
```
**Alpine Linux:**
```bash
sudo apk add bubblewrap squashfuse fuse3 squashfs-tools openssl jq file curl
```

---

## 📖 Usage Guide (you can use .lpk file in Releases pages for testing)

### 1. Ephemeral Streaming & Demos (`stream`)
Stream remote applications directlyinto volatile RAM/tmpfs. Perfect for instant trials, demo software, or running single-use tools without writing them to disk:

**Stream directly from a URL or GitHub repository**
```bash
ulpm stream https://example.com/app_amd64.lpk
```
or
```bash
ulpm stream owner/repo
```
*When the application exits, the ephemeral runtime and all cached binaries are automatically destroyed.*

### 2. Running Applications (`run`)
Launch any local `.lpk`, an installed package ID, or a remote target backed by Smart Cache (`304 Not Modified`):

**Run a local bundle**
```bash
ulpm run ./brave_amd64.lpk
```
**Run an installed app**
```bash
ulpm run io.lpk.brave
```
**Launch in an isolated offline sandbox (disables networking)**
```bash
ulpm run --offline io.lpk.brave
```

### 3. Installing Packages
Install directly from local files, archives, or remote GitHub releases:

**Install a pre-built .lpk bundle**
```bash
ulpm install ./app_amd64.lpk
```
**Convert and install an AppImage, .deb or archive on the fly**
```bash
ulpm install ./app.AppImage
ulpm install ./discord.deb
ulpm install ./app.tar.gz my-custom-app
```
**Install directly from a GitHub repository's latest release**
```bash
ulpm install owner/repo
```
### 4. Packaging & Fat-Bundling (`pack` & `deb-pack`)
ULPM can automatically resolve dependencies using `ldd` and fat-bundle required shared libraries:

**Package a folder, archive or AppImage into an autonomous .lpk**
```bash
ulpm pack ./app.AppImage
ulpm pack ./extracted_folder myapp
```
**Build a standalone .lpk bundle fetching all recursive APT dependencies**
```bash
ulpm deb-pack vlc
```
### 5. Updating & Managing Packages
**List all installed packages**
```bash
ulpm list
```
**Check and update all GitHub-tracked packages**
```bash
ulpm upgrade
```
**Completely remove an application and its desktop integration**
```bash
ulpm remove io.lpk.brave
```
---

## 🔐 Cryptography & Trust (Autonomous Ed25519)

Security is not an afterthought. **ULPM enforces autonomous signature verification** before installing or running any packagewithout relying on detached `.sig` files:

- **Self-Contained Footer:** Every signed `.lpk` embeds a fixed104-byte cryptographic trailer (`[64B signature | 32B public key | 8B magic LPKSIG01]`) at the end of the file.
- **Payload Integrity:** The SquashFS payload sizeis computed dynamically without tampering with the compressed data stream.

1. **Automatic Keypair Generation:** On first pack, ULPM transparently initializes a personal 256-bit Ed25519 keypair in `~/.config/ulpm/` and trusts it locally.
2. **Manual Key Management:**
```bash
ulpm keygen release_key
```
**Inject an autonomous signature into an existing package**
```bash
ulpm sign myapp_amd64.lpk ~/.config/ulpm/release_key.key
```
**Trust a developer's public key**
```bash
ulpm trust developer.pub
```
Packages lacking a valid cryptographic signature signed by a trusted key inside `~/.config/ulpm/trusted_keys/` are immediately rejected.

---

## 🏗️ Architecture & Sandbox Model

Every application runs within an ephemeral Bubblewrap namespace configured for maximum performance anduser privacy:

- **Isolated User Storage:** Instead of cluttering `$HOME`, application data is sandboxed into:
- `~/.var/app/<app_id>/config` $\rightarrow$ Mounted as `$HOME/.config`
- `~/.var/app/<app_id>/data` $\rightarrow$ Mounted as `$HOME/.local/share`
- `~/.var/app/<app_id>/cache` $\rightarrow$Mounted as `$HOME/.cache`
- **Network Controls:** Manifest gate (`"network": false`) or CLI flag(`--offline`) triggering kernel-level unsharing (`--unshare-net`).
- **Host Integration:**
- Access to `$HOME/Downloads` for standard file exchanges.
- Native display pass-through: Wayland socket & X11 (`~/.Xauthority`).
- Native audio: PipeWire and PulseAudio runtime sockets.
- Native themes and fonts: `/usr/share/fonts`, `/usr/share/themes`, and`~/.icons` are mounted read-only.
- Hardware acceleration: Direct pass-through of `/dev/dri` and proprietary `/dev/nvidia*` devices.

---

## 🗺️ Roadmap & 🤝 Contributing
Contributions, issues,and feature requests are welcome! Feel free to check the [issues page](../../issues).

### Core Engine Status
- [x] Autonomous `.lpk` packaging format (v3 with embedded 104-byte footer).
- [x] AutonomousEd25519 cryptographic signing & keyring.
- [x] Bubblewrap isolation with dynamic XDG remapping& offline mode.
- [x] Ephemeral RAM streaming execution (`ulpm stream`).
- [x] Smart Cache withconditional HTTP verification (`ETag` / `If-Modified-Since`).
- [x] Automatic recursive `.deb` dependency resolution.

### Upcoming & Help Wanted
- [ ] Add support for [your favorite distro] (PRs welcome!)
- [ ] Improve the packaging
- [ ] Fine-grained D-Bus proxy filtering via `xdg-dbus-proxy`.
- [ ] Dedicated multilib 32-bit library containment for standalone Wine runners.
- [ ] Nested namespace permission helper (forSteam / Proton `pressure-vessel`).
- [ ] Fix [open issue]

---

## 📄 License

This project is licensed under the [GPLv3 License](LICENSE).
