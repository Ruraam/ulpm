# Permissions and sandbox

ULPM runs applications with Bubblewrap (`bwrap`), unprivileged user namespaces, dropped capabilities and a declarative permission model.

## Isolation model

Every application gets:

- A new UTS, PID and (where possible) cgroup namespace
- `--cap-drop ALL`
- A read-only `/usr`, `/bin`, `/lib`, `/lib64` host base (or a shared runtime)
- A private `/tmp`, `/run` and `/var/tmp`
- A read-only `/sys`
- A filtered session D-Bus connection when `xdg-dbus-proxy` is available
- A dedicated persistent data directory under `~/.var/app/<app_id>`

Host paths are only exposed when the manifest or an override requests them. `/media`, `/run/media`, `/mnt` and the system D-Bus socket are bind-mounted when present.

If Bubblewrap is missing or user namespaces are disabled, ULPM refuses to execute the application. The explicit override is:

```bash
ULPM_UNSAFE_NO_SANDBOX=1 ulpm run <target>
```

This disables isolation and should only be used for trusted software.

## Effective permissions

The effective manifest is:

```text
package manifest
      ↓ deep merge
~/.config/ulpm/overrides/<app_id>.json
      ↓ runtime profile
CLI kill switches
      ↓
effective sandbox
```

Inspect the result:

```bash
ulpm permissions <app>
```

The output shows whether local overrides are active and each permission's effective value.

## Manifest permissions

```json
{
  "permissions": {
    "network": true,
    "audio": true,
    "gui": true,
    "gpu": true,
    "filesystem": {
      "home": "isolated",
      "downloads": "read-write",
      "custom": [
        {"path": "/data/projects", "mode": "read-write"},
        {"path": "/etc/localtime", "mode": "ro"}
      ]
    },
    "devices": {
      "dri": true,
      "input": true,
      "hidraw": false,
      "usb": false,
      "kvm": false
    },
    "dbus": {
      "session": {
        "talk": ["org.freedesktop.Notifications"],
        "own": ["org.example.App.*"]
      }
    }
  }
}
```

### Home directory

| Value | Behavior |
| :--- | :--- |
| `isolated` (default) | `$HOME` is `~/.var/app/<app_id>/home` |
| `read` / `ro` | Host `$HOME` is mounted read-only |
| `read-write` / `rw` | Host `$HOME` is mounted read-write |

Even in isolated mode, these subdirectories are persistent:

```text
~/.var/app/<app_id>/home
~/.var/app/<app_id>/config    -> $HOME/.config
~/.var/app/<app_id>/data      -> $HOME/.local/share
~/.var/app/<app_id>/cache     -> $HOME/.cache
```

### Downloads

ULPM detects the host Downloads directory through `xdg-user-dir DOWNLOAD`, `~/.config/user-dirs.dirs`, then common localized names.

| Value | Behavior |
| :--- | :--- |
| `read-write` / `rw` (default) | Read-write bind of the host Downloads directory |
| `read` / `ro` | Read-only bind |
| `none` or any other value | No Downloads bind |

In isolated home mode, ULPM also creates `Downloads` and `Téléchargements` symlinks inside the guest home pointing to the exposed directory name.

### Custom filesystem binds

Each entry has:

```json
{"path": "/absolute/host/path", "mode": "read-write"}
```

- `mode: "ro"` or `"read"` mounts read-only.
- Any other mode mounts read-write.
- The host path must exist.
- The destination is the same absolute path inside the sandbox.
- `/`, `/proc`, `/sys`, `/dev` and `/run` targets are rejected.
- Paths containing `..` segments are rejected.

### Devices

| Key | Device |
| :--- | :--- |
| `dri` | `/dev/dri` |
| `input` | `/dev/input`, `/dev/uinput`, joystick devices |
| `hidraw` | `/dev/hidraw*` |
| `usb` | `/dev/bus/usb` |
| `kvm` | `/dev/kvm` |

`/dev/fb0` and `/run/udev` are exposed read-only when present. `/dev/shm` is shared.

GPU permission also exposes `/usr/share/vulkan`, `/usr/share/glvnd` and NVIDIA device nodes. Audio permission exposes `/dev/snd` and the PulseAudio/PipeWire sockets.

### D-Bus

Session D-Bus is only wired when GUI access is enabled; `--no-gui` leaves the application without a session bus.

When `xdg-dbus-proxy` is installed and a session bus is available, ULPM starts a filtered proxy and grants:

- The application's own namespace (`<app_id>.*`), except for system namespaces such as `org.freedesktop*`, `org.gnome*`, `org.kde*`, `org.mpris*` and `com.canonical*`
- `org.mpris.MediaPlayer2.*`
- `org.freedesktop.Notifications`
- `org.freedesktop.ScreenSaver`
- `org.freedesktop.PowerManagement.Inhibit`
- `org.freedesktop.portal.Desktop`
- `org.freedesktop.portal.Documents`
- `org.kde.StatusNotifierWatcher`
- Additional `permissions.dbus.session.talk` and `own` rules
- Extra rules from `ULPM_DBUS_EXTRA`

Without a proxy, the session socket is bound directly and filtering is not available.

## Runtime profiles

Profiles are applied after manifest defaults and before individual kill switches.

| Profile | Effect |
| :--- | :--- |
| `--gaming` | Network unchanged; GPU, audio, DRI, input, hidraw, USB enabled |
| `--desktop` | GPU, audio and GUI enabled |
| `--strict` | Network off, GPU/DRI off, input off, home isolated, Downloads off |

Individual flags:

| Flag | Effect |
| :--- | :--- |
| `--offline`, `--no-net` | Network off |
| `--net` | Network on |
| `--no-gpu` | GPU and DRI off |
| `--no-audio` | Audio off |
| `--no-gui` | GUI off; IPC unshared |
| `--no-input` | Input devices off |

CLI flags take precedence over profiles. For example, `--gaming --no-audio` keeps gaming device access but disables audio.

## Seccomp

In `--strict` mode, ULPM loads a seccomp BPF filter when one exists at:

```text
~/.config/ulpm/seccomp/default.bpf
```

Override the path with `ULPM_SECCOMP_FILTER`. If the file is absent, no seccomp filter is applied.

## Environment

ULPM clears the environment and re-exposes a whitelist:

```text
HOME USER LOGNAME LANG LANGUAGE LC_ALL TZ TERM COLORTERM
DISPLAY XAUTHORITY WAYLAND_DISPLAY
XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION
XDG_RUNTIME_DIR PULSE_SERVER PIPEWIRE_RUNTIME_DIR
GDK_BACKEND GDK_SCALE GDK_DPI_SCALE GTK_THEME
QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME QT_SCALE_FACTOR QT_AUTO_SCREEN_SCALE_FACTOR
XCURSOR_THEME XCURSOR_SIZE SDL_VIDEODRIVER MOZ_ENABLE_WAYLAND
ELECTRON_OZONE_PLATFORM_HINT DRI_PRIME
__GLX_VENDOR_LIBRARY_NAME __NV_PRIME_RENDER_OFFLOAD__ VK_LAYER_NV_optimus
VK_ICD_FILENAMES VK_DRIVER_FILES LIBVA_DRIVER_NAME MESA_LOADER_DRIVER_OVERRIDE
RECALBOX_SYSTEM_DIR CONTROLLER_CONFIG SDL_JOYSTICK_DEVICE
```

Additional variables are set explicitly:

```text
PATH=/app/bin:/app/usr/bin:/app:/usr/bin:/bin
LD_LIBRARY_PATH=/app/lib:/app/usr/lib:/app/lib64:/app/usr/lib64:...
XDG_CONFIG_HOME=$HOME/.config
XDG_DATA_HOME=$HOME/.local/share
XDG_CACHE_HOME=$HOME/.cache
XDG_DATA_DIRS=/app/share:/app/usr/share:/usr/share:/usr/local/share
```

## Rootfs packages

A rootfs package (`type: rootfs|distro|os` or a detected `/etc` + `/usr` tree) uses a host-root namespace:

- The rootfs is mounted read-only at `/`
- `~/.var/app/<app_id>/home` is mounted at `$HOME`
- `~/.var/app/<app_id>/tmp` is mounted at `/tmp`
- The host Downloads directory is mounted read-write
- `/media`, `/run/media`, `/mnt` and the system D-Bus socket are exposed when present
- Network, GPU, audio, GUI and input can still be disabled with runtime flags

Rootfs execution is intended for complete desktop or retro-gaming environments and has a broader host integration surface than application mode. Treat rootfs bundles as high-trust software.

## Overrides

Overrides are small JSON fragments owned by the user. They never modify the package.

```bash
ulpm override firefox --no-net
ulpm override blender --share-home
ulpm override retroarch --gaming
ulpm override myapp permissions.devices.kvm=true
ulpm permissions reset myapp
```

The override file is:

```text
~/.config/ulpm/overrides/<app_id>.json
```

Example content:

```json
{
  "permissions": {
    "network": false,
    "filesystem": {
      "downloads": "read"
    }
  }
}
```

Delete the file or run `ulpm permissions reset <app>` to return to package defaults.

## Security caveats

- X11 has no strong per-window isolation; `--no-gui` is the only reliable display boundary.
- GPU access and shared `/dev/shm` increase the attack surface.
- Direct D-Bus fallback without `xdg-dbus-proxy` exposes the unfiltered session bus.
- `read-write` home access, custom binds, USB and KVM access are powerful grants.
- Application data under `~/.var/app/<app_id>` survives removal unless `--purge` is used.
- ULPM is a user-space sandbox, not a virtual machine. A malicious application with granted kernel devices or host filesystem access may escape the intended security boundary.

See [Security model](security.md) for signature and trust details.
