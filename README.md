<div align="center">
<img src="assets/ulpm-logo.svg" width="225" alt="ulpm logo" />
<h1>ULPM - Universal Linux Package Manager & Autonomous Containerized Bundle Engine</h1>


<p><strong><b><em>Lightweight, rootless, zero-daemon, sandboxed application runtime for any Linux system.</b></em></strong></p>

[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Format](https://img.shields.io/badge/Format-.lpk%20v4-orange.svg)](#the-lpk-format)
[![Sandbox](https://img.shields.io/badge/Sandbox-Bubblewrap-green.svg)](#security-model)
[![Crypto](https://img.shields.io/badge/Signatures-Ed25519-purple.svg)](#cryptographic-verification)
[![Tested Hardware](https://img.shields.io/badge/Validated%20On-Celeron%20N4000%20(%2450%20Box)-red.svg)](#performance-philosophy)

</div>

---

>[!NOTE]
> ### 🚀 Release Status: v4.0.0 Production Engine
>
> **ULPM Engine v4.0.0** powers the autonomous **`.lpk` Format v4** specification with a hardened, modular architecture.
>
> * **Security:** Hardened Bubblewrap namespaces with isolated session D-Bus proxy (`xdg-dbus-proxy`), granular runtime kill-switches (`--no-gpu`, `--no-audio`, `--no-gui`), and Ed25519 TOFU cryptographic key pinning.
> * **Zero-Daemon Architecture:** 100% rootless runtime, instant RAM streaming execution, andzero background resource footprint.
> * **RootFS & Distro Engine:** Run entire unprivileged Linux distributions (Debian XFCE, Arch, Alpine, Recalbox) directly inside unshared namespaces without KVM or Docker.
> * **Compatibility:** Validated on standard Linux distributions across minimal and enterprise hardware (amd64, arm64, armhf, i386, riscv64).

---

## ⚡ Overview

**ULPM** is a minimalist, modern package manager designed to bridge the gap between traditional system packages (`.deb`, `.rpm`, `.AppImage`) and massive monolithic runtimes (Flatpak, Snap).

It packages applications into **`.lpk`** (*Linux Package Kit*) files—autonomous, read-only SquashFS images compressed with modern **Zstandard (zstd)** and runs them via native Linux user namespaces (**Bubblewrap**) with **zero system overhead**.

### Why ULPM ?

- 🚫 **Zero Daemon:** No background services consuming memory or disk I/O.

- 👤 **100% Rootless:**Install, build, update, and run applications entirely in user-space (`~/.local/share/ulpm`).No `sudo` required.

- 🛡️ **Hardened Sandbox:** Isolated filesystem, restricted `/etc` view, filtered session D-Bus (`xdg-dbus-proxy`), MIT-SHM support for X11, separate XDG directories (`~/.var/app/<app_id>`), and strict permission gates (`--cap-drop ALL`).

- 🎛️ **Granular Kill-Switches:** Dynamically sever network, GPU access, audio servers, or graphical display at launch via runtime CLI flags.

- 🔑 **Cryptographically Signed & Pinned:** Embedded Ed25519payload signatures verified autonomously before every execution or installation. Cryptographic key pinning prevents supply-chain attacks on upgrade.

- 🎮 **Hardware & Gaming Native:** Direct zero-friction pass-through for host GPU drivers (Mesa, DRI/VA-API, proprietary Nvidia), joysticks/gamepads (`/dev/input`, `/dev/js*`), Wayland, X11, PipeWire, and PulseAudio.

- ⚡ **Instant Streaming & Demo:** Stream apps directly into volatile RAM/tmpfs to test software on the fly with zero footprint upon exit.

- 🧠 **Smart Cache:** Intelligent HTTP header(`ETag` / `If-Modified-Since`) validation preventing duplicate downloads when running remote URLs.

- 🔄 **Universal Conversion:** Automatically turn raw `.AppImage` (via safe ELF/SquashFS parsing), `.tar.gz`, `.deb`, `.rpm`, or direct GitHub repositories into self-contained `.lpk` fat-bundleson the fly.

- 🧬 **Seamless Host Graphics Bridge:** Prevents ABI divergence and crashes on proprietary drivers (NVIDIA / Mesa) inside containers by dynamically mounting and binding host display stacks, DRI, and GLVND loaders straight into guest runtimes.

- 🕹️ **Compositor & Micro-Compositor Ready:** Built-in low-latency pipeline ready to host Valve's Gamescope,Xephyr, or nested Wayland compositors directly inside isolated containers for dedicated portable gaming sessions.

- 🐙 **Native GitHub CI/CD & OTA Updates:** Install and seamlessly track software straightfrom `owner/repo` releases with embedded cryptographic key pinning on upgrades.

---

## 📊 Comparison

| Feature | Snap | Flatpak | AppImage | **ULPM (.lpk)** |
| :--- | :---: | :---: | :---: |:---: |
| **Daemonless** | ❌ (snapd required) | ✔️ | ✔️| ✔️ **Yes** |
| **Rootless Install** | ❌ (requires root) | ⚠️(partial) | ✔️ | ✔️ **Full user-space** |
| **Runtime Overhead** |⚠️ Heavy startup | ⚠️ Runtimes required | ✔️ Low | 🚀 **Near-zero** |
| **Sandbox Built-in**| AppArmor (Host root) | Bubblewrap | ❌ None by default | 🛡️ **Bubblewrap + D-Bus proxy** |
| **Dynamic Kill-Switches** | ❌ None | ⚠️ Manual overrides | ❌ None |🎛️ **`--no-gpu`, `--offline`, etc.** |
| **Distro/RootFS Execution** |❌ No | ❌ No | ❌ No | 🐧 **Full RootFS support** |
| **RAM Stream Apps (Zero-Disk)** | ❌ No | ❌ No | ❌ No | ⚡ **Direct volatile stream**|
| **Instant Distro Preview** | ❌ No | ❌ No | ❌ No | 🪟 **Live RootFS test without install** |
| **Mandatory Signatures** |Snap Store only | Flathub GPG | ❌ Rare | 🔑 **Ed25519 Built-in + Pinning**|
| **Multi-format Builder** | Complex recipe | Complex JSON/YAML | Manual recipes | 🪄 **Auto from .appimage/.deb/.rpm/tar** |
| **Zero-Mismatch NVIDIA Bridge** | ❌ Complex (nvidia-container-toolkit) | ⚠️ Flatpak runtime dependent | ❌ Host ABI breaks common | ⚡ **Nativehost passthrough** |
| **Micro-Compositor (Gamescope)** | ❌ Difficult | ⚠️ Heavy tweaking| ❌ Fragile | 🎮 **Native nested session** |
| **Zero-Config GitHub OTA** | ❌ Complex (Action + Store) | ⚠️ Flathub PR pipeline | ❌ Manual re-download | 🐙 **Native `owner/repo` tracking** |

---

## 🚀 Installation & Requirements

### Dependencies

ULPM is designed with a **zero-daemon, minimal-overhead** philosophy. Instead of bundling redundant background runtimes, it leverages battle-tested, standard Linux utilities:

| Component | Utility | Description |
| :--- | :--- | :--- |
| **Sandboxing** | `bubblewrap` (`bwrap`) |Lightweight unprivileged user-namespace isolation |
| **D-Bus Filtering** | `xdg-dbus-proxy` | *(Optional but recommended)* Restricts and filters session D-Bus access |
| **Filesystem**| `squashfuse` & `fuse3` | High-performance user-space mounting for compressed images |
| **Bundle Creation** | `squashfs-tools` (`mksquashfs`, `unsquashfs`)| Generates and safely extracts optimized $zstd$-compressed `.lpk` images |
| **Cryptography** |`openssl` (>= 3.0) & `coreutils` | Autonomous Ed25519 trailer signature verification & raw I/O |
| **Binary Inspection** | `od`, `cmp`, `file` | Secure non-executing ELF header parsing and binary key matching |
| **Metadata Parsing** | `jq` | Fast JSON manifest validation |
| **Transport** | `curl` | Smart conditional caching and remote repository sync|
| **Process Locking** | `util-linux` (`flock`) | Safe multi-process concurrency and database locking |

---

### Quick Install (Automated)

The official installer auto-detects your environment, resolves dependencies across major package managers (`apt`, `pacman`, `dnf`, `zypper`, `apk`, `xbps`), and sets up either a **rootless** or **system-wide** installation.

#### Run Installation Dashboard
```bash
curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | bash
```
>[!NOTE]
> Choice in Dashboard:
>
>* **1) Rootless Installation:**
> Installs cleanly to `~/.local/bin/ulpm` without requiring root permissions.
>
> * **2) System-Wide Install:**
> Installs globally to`/usr/local/bin/ulpm` for all users on the host.
>
> * **3) Debian/Ubuntu-based:**
> Installs via ulpm official APT repo signed with gpg key

### Installation and upgrade via [Debup](https://github.com/Ruraam/debup)

**Search &Install:**
```bash
dbp -s ulpm
```
*Select option `1` and press Enter to install the latest `.deb` packagedirectly from GitHub Releases.*

**Upgrade:**
```bash
dbp -u
```

---

#### Manual Dependency Installation

If you prefer installing dependencies manually before running the script:

**Debian / Ubuntu / Linux Mint:**
```bash
sudo apt update && sudo apt install -y bubblewrap xdg-dbus-proxy squashfuse fuse3 squashfs-tools openssl jq file curl diffutils coreutils util-linux
```
**Arch Linux / Manjaro:**
```bash
sudo pacman -Syu --needed bubblewrap xdg-dbus-proxy squashfuse fuse3 squashfs-tools openssl jq file curl diffutils coreutils util-linux
```
**Fedora / RHEL / CentOS Stream:**
```bash
sudo dnf install -y bubblewrap xdg-dbus-proxy squashfuse fuse3 squashfs-tools openssl jq file curl diffutils coreutils util-linux
```
**Alpine Linux:**
```bash
sudo apk add bubblewrap xdg-dbus-proxy squashfuse fuse3 squashfs-tools openssl jq file curl diffutils coreutils util-linux
```

---

## 📖 Usage Guide

### 1. Ephemeral Streaming & Demos (`stream`)
Stream remote applications directly into volatile RAM/tmpfs. Perfect for instant trials, demo software, or running single-use tools without writing them to disk:

**Stream directly from a URL or GitHub repository**
```bash
ulpm stream https://example.com/app_amd64.lpk
```
or
```bash
ulpm stream owner/repo
```
*When the application exits, the ephemeral runtime and all cached binaries are automatically destroyed.*

### 2. Running Applications & Sandboxing Flags(`run`)
Launch any local `.lpk`, an installed package ID, or an entire containerized RootFS with fine-grained security controls:

**Run a local bundle or installed package**
```bash
ulpm run ./brave_amd64.lpk
```
```bash
ulpm run io.lpk.brave
```
**Runtime Kill-Switches (Workswith both Apps & RootFS distros):**

Disable all networking
```bash
ulpm run --offline io.lpk.brave
```
Disable hardware GPU acceleration (/dev/dri, Vulkan, NVIDIA)
```bash
ulpm run --no-gpu io.lpk.app
```
Disable audio servers (PulseAudio, PipeWire, ALSA)
```bash
ulpm run --no-audio io.lpk.game
```
Run in pure CLI / headless mode (severs X11 and Wayland sockets)
```bash
ulpm run --no-gui io.lpk.distro-rootfs
```
Mount a custom host directory into the sandbox
```bash
ulpm run --bind /data/projects:/workspace io.lpk.ide
```
### 3. Installing Packages
Install directly from local files, archives, or remote GitHub releases:

**Install a pre-built .lpk bundle**
```bash
ulpm install ./app_amd64.lpk
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
```
```bash
ulpm pack ./extracted_folder myapp
```
```bash
ulpm pack ./app.tar.gz my-custom-app
```
**Build a standalone .lpk bundle fetching all recursive APT dependencies**
```bash
ulpm deb-pack firefox-esr
```
### 5. Updating & Managing Packages
**List all installed packages**
```bash
ulpm list
```
**Upgrade allinstalled packages (automatically tracking upstream GitHub releases with key verification)**
```bash
ulpm upgrade
```
**Upgrade a specific package fromits GitHub source**
```bash
ulpm upgrade owner/repo
```
**Completely remove an application and its desktop integration**
```bash
ulpm remove io.lpk.brave
```
**Purge downloaded package and API caches**
```bash
ulpm clean
```

---

## 🔐 Cryptography & Trust (Autonomous Ed25519)

Security is not an afterthought. **ULPM enforces autonomous signature verification** before installing or running any package without relying on detached `.sig` files:

- **Self-Contained Footer:** Every signed `.lpk` embeds a fixed 104-byte cryptographic trailer (`[8B magic ULPM_SIG | 32B public key | 64B signature]`) at the end of the file.

- **Key Pinning (TOFU):** On first installation, the SHA-256 fingerprint of the developer's public key is stored. Upgrades require matching keys, preventing supply-chain takeover.

- **Payload Integrity:** The SquashFS payload size is computed dynamically without tampering with the compressed data stream.

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
Packages lacking a valid cryptographic signature or signed by an untrusted key are rejected by default (configurable via `ULPM_STRICT_SIGNATURES=false`).

---

## 🏗️ Architecture & Sandbox Model

Every application or RootFS runs within an ephemeral Bubblewrap namespace configured for maximum performance and user privacy:

- **Isolated User Storage:** Instead of cluttering `$HOME`, application data is sandboxed into:
  - `~/.var/app/<app_id>/config` ➔ Mounted as `$HOME/.config`
  - `~/.var/app/<app_id>/data` ➔ Mounted as `$HOME/.local/share`
  - `~/.var/app/<app_id>/cache` ➔ Mounted as `$HOME/.cache`

- **D-Bus Hardening:** Session D-Bus access is guarded via `xdg-dbus-proxy`, exposing only strictly necessary interfaces (Portals, Notifications, Media Player, ScreenSaver) and isolating the rest of the host.

- **Strict Host Views:** Only vital configuration directories under `/etc` are shared. Host `$HOME` is shielded except for a controlled multilingual download gate (`$HOME/Downloads` / `$HOME/Téléchargements`).

- **Dynamic Security Gates:** Unshare network (`--offline`), disable IPC (`--no-gui`), strip graphic devices (`--no-gpu`), or mute sound servers (`--no-audio`) via CLI overrides or manifest declarations.

- **Host Integration:**
  - Native display pass-through: Wayland socket & X11 (with MIT-SHM IPC compatibility).
  - Native audio: Direct individual sockets for PipeWire and PulseAudio.
  - Native themes and fonts: `/usr/share/fonts`, `/usr/share/themes`, and `~/.icons` are mounted read-only.
  - Hardware acceleration: Direct pass-through of `/dev/dri`, `/usr/share/glvnd`, `/usr/share/vulkan`, and seamless host     proprietary `/dev/nvidia*` nodes to completely eradicate kernel-driver version mismatch in RootFS containers.
  - Dedicated gaming rootfs paths: Automatic discovery and persistence bridges for retro-gaming suites (e.g.  `/recalbox/share` mounts for saves, BIOS, and ROMs).

---

## 🗺️ Roadmap & 🤝 Contributing
Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](../../issues).

### Core Engine Status
- [x] Autonomous `.lpk` packaging format (v4 with embedded 104-byte `ULPM_SIG` footer).
- [x] Autonomous Ed25519 cryptographic signing & keyring.
- [x] Cryptographic key pinning on upgrades (TOFU).
- [x] Bubblewrap isolation with dynamic XDG remapping & runtime flags (`--offline`, `--no-gpu`, `--no-audio`, `--no-gui`).
- [x] Session D-Bus proxy filtering via `xdg-dbus-proxy`.
- [x] Safe non-executing AppImage ELF/SquashFS parser.
- [x] Ephemeral RAM streaming execution (`ulpm stream`).
- [x] Smart Cache with conditional HTTP verification (`ETag` / `If-Modified-Since`).
- [x] Automatic recursive `.deb` dependency resolution.
- [x] Containerized unprivileged RootFS execution (Debian XFCE, Arch, Recalbox without KVM or Docker).
- [x] Host graphic stack zero-mismatch bridge for proprietary NVIDIA drivers.
- [x] Dedicated persistent bindings for guest retrogaming systems (`/recalbox/share`).
- [x] Gamescope and unprivileged nested Wayland/Xwayland compositor execution support.
- [x] Autonomous GitHub repository release tracking & OTA updates (`ulpm upgrade`).

### Upcoming & Help Wanted
- [ ] Add support for [your favorite distro] (PRs welcome!)
- [ ] Dedicated multilib 32-bit library containment for standalone Wine runners.
- [ ] Nested namespace permission helper (for Steam / Proton `pressure-vessel`).
- [ ] Fix [open issue]

---

## 📄 License
This project is licensed under the [GPLv3 License](LICENSE).





