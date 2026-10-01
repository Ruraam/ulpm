<div align="center">
<img src="assets/ulpm-logo.svg" width="180" alt="ulpm logo" />
<h1>ULPM & `.lpk`</h1>
 
### **Universal Linux Package Manager & Autonomous Containerized Bundle Engine**


<p><strong><em>Lightweight, rootless, zero-daemon, sandboxed application runtime for any Linux system.</em></strong></p>

[![License: MIT](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Format](https://img.shields.io/badge/Format-.lpk%20v2-orange.svg)](#the-lpk-format)
[![Sandbox](https://img.shields.io/badge/Sandbox-Bubblewrap-green.svg)](#security-model)
[![Crypto](https://img.shields.io/badge/Signatures-Ed25519-purple.svg)](#cryptographic-verification)
[![Tested Hardware](https://img.shields.io/badge/Validated%20On-Celeron%20N4000%20(%2450%20Box)-brightgreen.svg)](#performance-philosophy)

</div>

---

>[!WARNING]
> ### ⚠️ Project Status: Experimental / Proof of Concept
>
> **ULPM** is currently in an active development and evaluation phase (**v0.2.0-beta**).
>
> - **Sandbox Scope:** While Bubblewrap provides strong filesystem and namespace isolation, session D-Bus is currently bridged to the host for desktop integration. Do not use this tool as a bullet proof sandbox to execute untrusted malware.
> - **Breaking Changes:** The `.lpk` container structure and CLI syntax may evolve before reaching version `1.0.0`.
> - **Testing:** Built and validated on Debian minimal environments (including low-power hardware). Bug reports, feature requests, and PRs are welcome!

---

## ⚡ Overview

**ULPM** is a minimalist, modern package manager designed to bridge the gap between traditional system packages (`.deb`, `.rpm`) and massive monolithic runtimes (Flatpak, Snap).

It packages applications into **`.lpk`** (*Linux Package Kit*) files—autonomous, read-only SquashFS images compressed with modern **Zstandard (zstd)** and runs them via native Linux user namespaces (**Bubblewrap**) with **zero systemoverhead**.

### Why ULPM ?

- 🚫 **Zero Daemon:** No background services consuming memory or disk I/O.
- 👤 **100% Rootless:** Install, build, update, and run applications entirely in user-space (`~/.local/share/ulpm`). No `sudo` required.
- 🛡️ **Hardened Sandbox:** Isolated filesystem, restricted network capability, separate XDG directories (`~/.var/app/<app_id>`), and strict permission gates.
- 🔑 **Cryptographically Signed:** Mandatory Ed25519 payload signatures verified before every execution or installation.
- 🎮 **Hardware Native:** Direct zero-friction access to host GPU drivers (Mesa, DRI/VA-API, proprietary Nvidia), Wayland, X11, PipeWire, and PulseAudio.
- 🔄 **Universal Conversion:** Automatically turn raw `.tar.gz`, `.deb`, `.rpm`, or direct GitHub repositories into self-contained `.lpk` fat-bundles on the fly.

---

## 📊 Comparison

| Feature | Snap | Flatpak | AppImage | **ULPM (.lpk)** |
| :--- | :---: | :---: | :---: | :---: |
| **Daemonless** | ❌ (snapd required) | ✔️ | ✔️ | ✔️ **Yes** |
| **Rootless Install** | ❌ (requires root) | ⚠️ (partial) | ✔️ | ✔️ **Full user-space** |
| **Runtime Overhead** | ⚠️ Heavy startup | ⚠️ Runtimes required | ✔️ Low | 🚀 **Near-zero** |
| **Sandbox Built-in** | AppArmor (Host root) | Bubblewrap | ❌ None by default | 🛡️ **Bubblewrap Native** |
| **Mandatory Signatures**| Snap Store only | Flathub GPG | ❌ Rare | 🔑 **Ed25519 Built-in** |
| **Multi-format Builder**| Complex recipe | Complex JSON/YAML | Manual recipes | 🪄**Auto from .deb/.rpm/tar** |

## 🚀 Installation & Requirements

### Dependencies
ULPM leverages battle-tested, standard Linux utilities:
(coming soon)


## 📖 Usage Guide

### 1. Running Applications
Launch any `.lpk` directly, or launch an installed package by its ID:

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

### 2. Installing Packages
Install directly from local files, archives, or remote GitHub releases:

**Install a pre-built .lpk bundle**
```bash
ulpm install ./app_amd64.lpk
```
**Convert and install a .deb or archive on the fly**
```bash
ulpm install ./discord.deb
ulpm install ./app.tar.gz my-custom-app
```
**Install directly from a GitHub repository's latest release**
```bash
ulpm install owner/repo
```
### 3. Packaging & Fat-Bundling (`pack` & `deb-pack`)
ULPM can automatically resolve dependencies using `ldd` and fat-bundle required shared libraries:

**Package a folder or archive into an autonomous .lpk**
```bash
ulpm pack ./extracted_folder myapp
```
**Build a standalone .lpk bundle fetching all recursive APT dependencies**
```bash
ulpm deb-pack vlc
```
### 4. Updating & Managing Packages
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

## 🔐 Cryptography & Trust (Ed25519)

Security is not an afterthought. **ULPM enforces strict signature verification** before installing or running any package:

1. **Automatic Keypair Generation:** On first pack, ULPM transparently initializes a personal 256-bit Ed25519 keypair in `~/.config/ulpm/` and trusts it locally.
2. **Manual Key Management:**
```bash
ulpm keygen release_key
```
**Sign an existing package**
```bash
ulpm sign myapp_amd64.lpk ~/.config/ulpm/release_key.key
```
**Trust a developer's public key**
```bash
ulpm trust developer.pub
```
Packages lacking a valid `.sig` file signed by a trusted key inside `~/.config/ulpm/trusted_keys/` are immediately rejected.

---

## 🏗️ Architecture & Sandbox Model

Every application runs within an ephemeral Bubblewrap namespace configured for maximum performance and user privacy:

- **Isolated User Storage:** Instead of cluttering `$HOME`, application data is sandboxed into:
- `~/.var/app/<app_id>/config` $\rightarrow$ Mounted as `$HOME/.config`
- `~/.var/app/<app_id>/data` $\rightarrow$ Mounted as `$HOME/.local/share`
- `~/.var/app/<app_id>/cache` $\rightarrow$ Mounted as `$HOME/.cache`
- **Host Integration:**
- Access to `$HOME/Downloads` for standard file exchanges.
- Native displaypass-through: Wayland socket & X11 (`~/.Xauthority`).
- Native audio: PipeWire and PulseAudio runtime sockets.
- Native themes and fonts: `/usr/share/fonts`, `/usr/share/themes`, and`~/.icons` are mounted read-only.
- Hardware acceleration: Direct pass-through of `/dev/dri` and proprietary `/dev/nvidia*` devices.

---

---

## 🗺️ Roadmap

- [x] Autonomous`.lpk` packaging format (v2).
- [x] Ed25519 cryptographic signing &keyring.
- [x] Bubblewrap isolation with dynamic XDG remapping.
- [x] Automatic recursive`.deb` dependency resolution.
- [ ] Nested namespace permission helper (for Steam / Proton `pressure-vessel`).
- [ ] Fine-grained D-Bus proxy filtering via `xdg-dbus-proxy`.
-[ ] Dedicated multilib 32-bit library containment for standalone Wine runners.

---

## 📄 License

This project is licensed under the[MIT License](LICENSE).

