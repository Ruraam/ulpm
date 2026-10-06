#!/usr/bin/env bash
# sandbox.sh - Bubblewrap isolation, D-Bus proxy, runtime execution

session_bus_socket() {
  local run_user_dir="$1"
  local addr="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$run_user_dir/bus}"
  if [[ "$addr" =~ ^unix:path=([^,]+) ]] && [[ -S "${BASH_REMATCH[1]}" ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

start_dbus_proxy() {
  local run_user_dir="$1" app_id="$2"
  local real_sock i

  command -v xdg-dbus-proxy &>/dev/null || return 1
  real_sock=$(session_bus_socket "$run_user_dir") || return 1

  RUN_DBUS_DIR=$(mktemp -d "$run_user_dir/ulpm-dbus.XXXXXX" 2>/dev/null) || { RUN_DBUS_DIR=""; return 1; }

  local extra=()
  if [[ -n "${ULPM_DBUS_EXTRA:-}" ]]; then
    # shellcheck disable=SC2206
    extra=($ULPM_DBUS_EXTRA)
  fi

  xdg-dbus-proxy "unix:path=$real_sock" "$RUN_DBUS_DIR/bus" --filter \
    --own="${app_id}.*" \
    --own='org.mpris.MediaPlayer2.*' \
    --talk=org.freedesktop.Notifications \
    --talk=org.freedesktop.ScreenSaver \
    --talk=org.freedesktop.PowerManagement.Inhibit \
    --talk=org.freedesktop.portal.Desktop \
    --talk=org.freedesktop.portal.Documents \
    --talk=org.kde.StatusNotifierWatcher \
    ${extra[@]+"${extra[@]}"} &
  RUN_DBUS_PID=$!

  for i in {1..30}; do
    [[ -S "$RUN_DBUS_DIR/bus" ]] && break
    kill -0 "$RUN_DBUS_PID" 2>/dev/null || break
    sleep 0.1
  done

  if [[ ! -S "$RUN_DBUS_DIR/bus" ]]; then
    cleanup_instance_dbus_only
    return 1
  fi
  return 0
}

ENV_WHITELIST=(
  HOME USER LOGNAME LANG LANGUAGE TZ TERM COLORTERM
  DISPLAY XAUTHORITY WAYLAND_DISPLAY
  XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION
  GDK_BACKEND GDK_SCALE GDK_DPI_SCALE GTK_THEME
  QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME QT_SCALE_FACTOR QT_AUTO_SCREEN_SCALE_FACTOR
  XCURSOR_THEME XCURSOR_SIZE SDL_VIDEODRIVER MOZ_ENABLE_WAYLAND
  __GLX_VENDOR_LIBRARY_NAME __NV_PRIME_RENDER_OFFLOAD __VK_LAYER_NV_optimus
  VK_ICD_FILENAMES LIBVA_DRIVER_NAME MESA_LOADER_DRIVER_OVERRIDE
)

lpk_run_isolated() {
  local force_offline=false
  while [[ "${1:-}" =~ ^-- ]]; do
    case "$1" in
      --offline|--no-net) force_offline=true; shift ;;
      *) break ;;
    esac
  done

  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo -e "${RED}[-] No target specified${NC}" >&2
    return 1
  fi
  shift || true

  if ! target="$(normalize_target "$target")"; then
    echo -e "${RED}[-] Invalid target${NC}" >&2
    return 1
  fi

  local pkg_path=""
  if [[ -f "$target" ]]; then
    pkg_path="$(realpath -- "$target")"
  elif [[ -f "$ULPM_APPS/$target.lpk" ]]; then
    pkg_path="$ULPM_APPS/$target.lpk"
  elif [[ -f "$ULPM_APPS/io.lpk.${target,,}.lpk" ]]; then
    pkg_path="$ULPM_APPS/io.lpk.${target,,}.lpk"
  elif [[ "$target" == *.lpk && ! "$target" =~ ^https?:// ]]; then
    echo -e "${RED}[-] File not found: $target${NC}" >&2
    return 1
  elif [[ "$target" =~ ^https?:// ]] || [[ "$target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    pkg_path=$(resolve_and_fetch_cached "$target") || return 1
  else
    echo -e "${RED}[-] Target '$target' could not be resolved${NC}" >&2
    return 1
  fi

  if ! verify_package_signature "$pkg_path"; then
    echo -e "${RED}[-] Launch aborted: signature check failed${NC}" >&2
    return 1
  fi

  RUN_MNT_DIR=$(mktemp -d "${ULPM_TMPDIR:-${TMPDIR:-/tmp}}/ulpm_run_XXXXXX")
  trap 'cleanup_instance; cleanup_temp' EXIT

  if ! squashfuse "$pkg_path" "$RUN_MNT_DIR" 2>/dev/null; then
    echo -e "${RED}[-] Failed to mount SquashFS${NC}" >&2
    cleanup_instance
    return 1
  fi

  local manifest="$RUN_MNT_DIR/meta/manifest.json"
  if [[ ! -f "$manifest" ]] || ! validate_manifest "$manifest"; then
    cleanup_instance
    return 1
  fi

  local app_id exec_bin is_chromium allow_net
  app_id=$(jq -r '.id' "$manifest")
  exec_bin=$(jq -r '.exec' "$manifest")
  is_chromium=$(jq -r '.chromium // false' "$manifest")
  allow_net=$(jq -r '.network // true' "$manifest")

  # Full-distribution package (Debian, ...): run it on its OWN root filesystem.
  # Regular app packages never match, so they keep the behaviour below untouched.
  if lpk_is_rootfs "$RUN_MNT_DIR" "$manifest"; then
    local rootfs_rc=0
    lpk_run_rootfs "$app_id" "$exec_bin" "$force_offline" "$allow_net" "$@" || rootfs_rc=$?
    return "$rootfs_rc"
  fi

  local app_data_dir="$HOME/.var/app/$app_id"
  mkdir -p "$app_data_dir/config" "$app_data_dir/data" "$app_data_dir/cache"

  local run_uid run_user_dir dl_dir exec_dir app_ld_path host_ca_bundle=""
  run_uid="$(id -u)"
  run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"
  dl_dir="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
  if [[ -z "$dl_dir" || "$dl_dir" == "$HOME" || "$dl_dir" == "$HOME/" ]]; then
    dl_dir="$HOME/Downloads"
  fi
  mkdir -p "$dl_dir"
  exec_dir="$(dirname "/app/$exec_bin")"
  app_ld_path="/app/lib:/app/usr/lib:/app/usr/lib/x86_64-linux-gnu:/app/usr/lib/aarch64-linux-gnu:$exec_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

  local ca
  for ca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem; do
    if [[ -f "$ca" ]]; then
      host_ca_bundle="$ca"
      break
    fi
  done

  local chromium_flags=()
  if [[ "$is_chromium" == "true" ]] || grep -qiE "chromium|electron" "$RUN_MNT_DIR/root/$exec_bin" 2>/dev/null; then
    chromium_flags=(
      --no-sandbox
      --test-type
      --disable-gpu-sandbox
      --disable-setuid-sandbox
      --log-level=3
    )
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
      chromium_flags+=(--ozone-platform-hint=auto)
    fi
  fi

  local bwrap_args=(
    --die-with-parent
    --new-session
    --cap-drop ALL
    --unshare-uts
    --unshare-cgroup-try
    --ro-bind /usr /usr
    --ro-bind-try /lib /lib
    --ro-bind-try /lib64 /lib64
    --ro-bind-try /bin /bin
    --ro-bind-try /sbin /sbin
  )

  if [[ "$ULPM_SHARE_PID" != "true" ]]; then
    bwrap_args+=(--unshare-pid)
  fi
  if [[ -z "${DISPLAY:-}" ]]; then
    bwrap_args+=(--unshare-ipc)
  fi

  local etc_item
  for etc_item in alternatives ld.so.cache ld.so.conf ld.so.conf.d \
    ssl ca-certificates pki crypto-policies fonts X11 xdg gtk-2.0 gtk-3.0 pulse vulkan glvnd \
    localtime timezone os-release machine-id passwd group nsswitch.conf hosts; do
    bwrap_args+=(--ro-bind-try "/etc/$etc_item" "/etc/$etc_item")
  done

  bwrap_args+=(
    --ro-bind /sys /sys
    --proc /proc
    --dev /dev
    --tmpfs /dev/shm
    --tmpfs /tmp
    --dev-bind-try /dev/dri /dev/dri
    --ro-bind-try /run/dbus/system_bus_socket /run/dbus/system_bus_socket
    --ro-bind-try /usr/share/fonts /usr/share/fonts
    --ro-bind-try /usr/share/themes /usr/share/themes
    --ro-bind-try /usr/share/icons /usr/share/icons
    --perms 0700 --dir "$run_user_dir"
    --bind "$dl_dir" "$dl_dir"
    --bind "$app_data_dir/config" "$HOME/.config"
    --bind "$app_data_dir/data" "$HOME/.local/share"
    --bind "$app_data_dir/cache" "$HOME/.cache"
    --ro-bind "$RUN_MNT_DIR/root" /app
  )

  bwrap_args+=(
    --ro-bind-try "$HOME/.icons" "$HOME/.icons"
    --ro-bind-try "$HOME/.themes" "$HOME/.themes"
    --ro-bind-try "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-3.0"
    --ro-bind-try "$HOME/.config/fontconfig" "$HOME/.config/fontconfig"
  )

  local arg
  for arg in "$@"; do
    if [[ -e "$arg" ]]; then
      local real_arg
      real_arg="$(realpath -- "$arg" 2>/dev/null || true)"
      if [[ -n "$real_arg" && -e "$real_arg" ]]; then
        bwrap_args+=(--bind-try "$real_arg" "$real_arg")
      fi
    fi
  done

  if [[ -n "${DISPLAY:-}" ]]; then
    local x_sock
    if [[ "$DISPLAY" =~ ^(unix)?:([0-9]+) ]]; then
      x_sock="/tmp/.X11-unix/X${BASH_REMATCH[2]}"
      bwrap_args+=(--ro-bind-try "$x_sock" "$x_sock")
    else
      bwrap_args+=(--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)
    fi
    local xauth_file="${XAUTHORITY:-$HOME/.Xauthority}"
    if [[ -f "$xauth_file" ]]; then
      bwrap_args+=(--ro-bind "$xauth_file" "$xauth_file")
    fi
  fi

  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    local wayland_sock
    if [[ "$WAYLAND_DISPLAY" == /* ]]; then
      wayland_sock="$WAYLAND_DISPLAY"
    else
      wayland_sock="$run_user_dir/$WAYLAND_DISPLAY"
    fi
    bwrap_args+=(--bind-try "$wayland_sock" "$wayland_sock")
  fi

  local pulse_sock="$run_user_dir/pulse/native"
  if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
    pulse_sock="${BASH_REMATCH[1]}"
  fi
  bwrap_args+=(
    --bind-try "$pulse_sock" "$pulse_sock"
    --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
  )

  case "$ULPM_DBUS_MODE" in
    none) ;;
    full)
      local full_sock
      if full_sock=$(session_bus_socket "$run_user_dir"); then
        bwrap_args+=(--bind "$full_sock" "$run_user_dir/bus")
      else
        echo -e "${YELLOW}[!] No session bus socket found, D-Bus not exposed${NC}" >&2
      fi
      ;;
    *)
      if start_dbus_proxy "$run_user_dir" "$app_id"; then
        bwrap_args+=(--bind "$RUN_DBUS_DIR/bus" "$run_user_dir/bus")
      else
        local fallback_sock
        if fallback_sock=$(session_bus_socket "$run_user_dir"); then
          echo -e "${YELLOW}[!] xdg-dbus-proxy unavailable: falling back to direct D-Bus access.${NC}" >&2
          bwrap_args+=(--bind "$fallback_sock" "$run_user_dir/bus")
        else
          echo -e "${YELLOW}[!] Session D-Bus not exposed (no session bus found).${NC}" >&2
        fi
      fi
      ;;
  esac

  local dev
  for dev in /dev/nvidia*; do
    if [[ -e "$dev" ]]; then
      bwrap_args+=(--dev-bind "$dev" "$dev")
    fi
  done

  if [[ "$force_offline" == "true" || "$allow_net" == "false" ]]; then
    bwrap_args+=(--unshare-net)
  else
    bwrap_args+=(
      --ro-bind-try /etc/resolv.conf /etc/resolv.conf
      --ro-bind-try /run/resolvconf /run/resolvconf
      --ro-bind-try /run/systemd/resolve /run/systemd/resolve
    )
  fi

  local env_args=()
  if [[ "$ULPM_CLEARENV" == "true" ]]; then
    env_args+=(--clearenv)
    local v
    for v in "${ENV_WHITELIST[@]}" ${ULPM_ENV_PASSTHROUGH:-}; do
      [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      if [[ -n "${!v+x}" ]]; then
        env_args+=(--setenv "$v" "${!v}")
      fi
    done
    while IFS= read -r v; do
      if [[ -n "$v" ]]; then
        env_args+=(--setenv "$v" "${!v}")
      fi
    done < <(compgen -e | grep -E '^LC_[A-Z_]+$' || true)
  else
    env_args+=(--unsetenv GITHUB_TOKEN)
  fi
  env_args+=(
    --setenv PATH "$HOME/.local/bin:/app/bin:/app/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    --setenv TMPDIR "/tmp"
    --setenv XDG_RUNTIME_DIR "$run_user_dir"
    --setenv XDG_CONFIG_DIRS "/app/etc/xdg:/etc/xdg"
    --setenv XDG_DATA_DIRS "/app/usr/share:/app/share:/usr/local/share:/usr/share"
    --setenv PULSE_SERVER "${PULSE_SERVER:-unix:$pulse_sock}"
    --setenv PIPEWIRE_RUNTIME_DIR "$run_user_dir"
    --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$run_user_dir/bus"
    --setenv LD_LIBRARY_PATH "$app_ld_path"
  )
  if [[ -n "$host_ca_bundle" ]]; then
    env_args+=(--setenv SSL_CERT_FILE "$host_ca_bundle")
  fi

  local rc=0
  bwrap "${bwrap_args[@]}" "${env_args[@]}" \
    --chdir /app \
    "/app/$exec_bin" ${chromium_flags[@]+"${chromium_flags[@]}"} "$@" || rc=$?

  cleanup_instance
  trap cleanup_temp EXIT
  return "$rc"
}


# ============================================================================
# Full-distribution packages ("rootfs" mode)
# ----------------------------------------------------------------------------
# Regular app packages run on the HOST /usr with their files under /app.
# A package that carries a whole distribution (Debian, ...) must instead run on
# its OWN /usr, loader and libc, otherwise its binaries are started by the
# host's loader against a mix of libraries. In this mode the package's root/
# directory BECOMES the sandbox root, so it works the same on any host distro.
#
# A package is a "distribution" when its manifest has "rootfs": true, or it
# contains /.ulpm-rootfs, or (packages built without the flag) it looks like a
# complete system: /etc/os-release + bash + its own libc.
# ============================================================================

lpk_is_rootfs() {
  local mnt="$1" manifest="$2" flag="" libc
  if command -v jq >/dev/null 2>&1; then
    flag="$(jq -r '.rootfs // false' "$manifest" 2>/dev/null || true)"
  elif grep -qE '"rootfs"[[:space:]]*:[[:space:]]*true' "$manifest" 2>/dev/null; then
    flag="true"
  fi
  [[ "$flag" == "true" ]] && return 0
  [[ -e "$mnt/root/.ulpm-rootfs" ]] && return 0
  if [[ -f "$mnt/root/etc/os-release" || -f "$mnt/root/usr/lib/os-release" ]] \
     && [[ -x "$mnt/root/usr/bin/bash" || -x "$mnt/root/bin/bash" ]]; then
    for libc in "$mnt"/root/usr/lib/*-linux-gnu/libc.so.6 "$mnt"/root/lib/*-linux-gnu/libc.so.6; do
      [[ -e "$libc" ]] && return 0
    done
  fi
  return 1
}

# Appends to the global array _RF_ARGS one bwrap argument group per entry of
# <src>: symlinks are recreated, files and directories are bound read-only.
# Usage: _rf_map_entries <src-dir> <dest-prefix ("" for /)> "<space separated names to skip>"
_rf_map_entries() {
  local src="$1" dst="$2" skip=" $3 " e name
  for e in "$src"/*; do
    [[ -e "$e" || -L "$e" ]] || continue
    name="${e##*/}"
    [[ "$skip" == *" $name "* ]] && continue
    if [[ -L "$e" ]]; then
      _RF_ARGS+=(--symlink "$(readlink -- "$e")" "$dst/$name")
    else
      _RF_ARGS+=(--ro-bind "$e" "$dst/$name")
    fi
  done
  return 0
}

# Generates the few files that must describe THIS host user / network instead
# of the build machine: passwd, group, hosts, hostname, resolv.conf, machine-id.
_rf_gen_files() {
  local root="$1" gen="$2" appdata="$3"
  local uid gid user group hn
  uid="$(id -u)"; gid="$(id -g)"
  user="$(id -un 2>/dev/null || echo user)"
  group="$(id -gn 2>/dev/null || echo "$user")"

  cat "$root/etc/passwd" > "$gen/passwd" 2>/dev/null || : > "$gen/passwd"
  if ! awk -F: -v u="$uid" '$3==u {f=1} END {exit !f}' "$gen/passwd"; then
    if awk -F: -v n="$user" '$1==n {f=1} END {exit !f}' "$gen/passwd"; then user="user$uid"; fi
    printf '%s:x:%s:%s:%s:%s:/bin/bash\n' "$user" "$uid" "$gid" "$user" "$HOME" >> "$gen/passwd"
  fi
  _RF_USER="$(awk -F: -v u="$uid" '$3==u {print $1; exit}' "$gen/passwd")"

  cat "$root/etc/group" > "$gen/group" 2>/dev/null || : > "$gen/group"
  if ! awk -F: -v g="$gid" '$3==g {f=1} END {exit !f}' "$gen/group"; then
    if awk -F: -v n="$group" '$1==n {f=1} END {exit !f}' "$gen/group"; then group="group$gid"; fi
    printf '%s:x:%s:\n' "$group" "$gid" >> "$gen/group"
  fi

  hn="$(uname -n 2>/dev/null || echo localhost)"
  printf '127.0.0.1 localhost %s\n::1 localhost ip6-localhost ip6-loopback\n' "$hn" > "$gen/hosts"
  printf '%s\n' "$hn" > "$gen/hostname"

  if [[ -r /etc/resolv.conf ]]; then
    cat /etc/resolv.conf > "$gen/resolv.conf" 2>/dev/null || : > "$gen/resolv.conf"
  else
    : > "$gen/resolv.conf"
  fi

  # Stable per-app machine-id (dbus needs one); not the host's.
  if [[ ! -s "$appdata/machine-id" ]]; then
    { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; echo; } > "$appdata/machine-id"
  fi
  return 0
}

# Builds _RF_ARGS (bwrap arguments) and _RF_ENV (environment) for rootfs mode.
_rf_build_args() {
  local mnt="$1" app_id="$2" force_offline="$3" allow_net="$4"
  local root="$mnt/root"
  _RF_ARGS=()
  _RF_ENV=()
  _RF_USER=""

  local run_uid run_user_dir app_data_dir gen dl_dir v
  run_uid="$(id -u)"
  run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"
  app_data_dir="$HOME/.var/app/$app_id"
  mkdir -p "$app_data_dir/home"
  gen="$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/rootfs.XXXXXX")"
  _rf_gen_files "$root" "$gen" "$app_data_dir"

  dl_dir="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
  if [[ -z "$dl_dir" || "$dl_dir" == "$HOME" || "$dl_dir" == "$HOME/" ]]; then
    dl_dir="$HOME/Downloads"
  fi
  mkdir -p "$dl_dir"

  _RF_ARGS+=(--die-with-parent --new-session --cap-drop ALL --unshare-uts --unshare-cgroup-try)
  if [[ "$ULPM_SHARE_PID" != "true" ]]; then
    _RF_ARGS+=(--unshare-pid)
  fi
  # X11 clients (and the nested Xephyr) use SysV shm to talk to the X server.
  if [[ -z "${DISPLAY:-}" ]]; then
    _RF_ARGS+=(--unshare-ipc)
  fi

  # --- the distribution's own filesystem ---
  _rf_map_entries "$root" "" "dev proc sys tmp run home root mnt media boot etc var"

  _RF_ARGS+=(--tmpfs /etc)
  _rf_map_entries "$root/etc" "/etc" "passwd group hosts hostname resolv.conf machine-id localtime timezone"
  _RF_ARGS+=(
    --ro-bind "$gen/passwd"   /etc/passwd
    --ro-bind "$gen/group"    /etc/group
    --ro-bind "$gen/hosts"    /etc/hosts
    --ro-bind "$gen/hostname" /etc/hostname
    --ro-bind "$gen/resolv.conf" /etc/resolv.conf
    --ro-bind "$app_data_dir/machine-id" /etc/machine-id
    --ro-bind-try /etc/localtime /etc/localtime
  )

  # /var: writable and empty (nothing from it is needed to run a desktop),
  # except the prebuilt font cache.
  _RF_ARGS+=(
    --tmpfs /var
    --dir /var/tmp --dir /var/log --dir /var/cache --dir /var/lib/xkb --dir /var/lib/dbus
    --symlink ../run /var/run
    --symlink /etc/machine-id /var/lib/dbus/machine-id
    --ro-bind-try "$root/var/cache/fontconfig" /var/cache/fontconfig
  )

  _RF_ARGS+=(
    --proc /proc
    --dev /dev
    --tmpfs /dev/shm
    --ro-bind /sys /sys
    --perms 1777 --tmpfs /tmp
    --tmpfs /run
    --dir /run/lock
    --perms 0700 --dir "$run_user_dir"
    --dev-bind-try /dev/dri /dev/dri
  )

  # --- persistent home of the distribution + shared Downloads ---
  _RF_ARGS+=(
    --bind "$app_data_dir/home" "$HOME"
    --bind "$dl_dir" "$dl_dir"
  )

  # --- read-only host pictures / wallpapers (to choose a desktop background) ---
  _rf_host_media_args

  # --- display: host X11 socket (Xephyr connects to it), never Wayland ---
  local xauth_file="${XAUTHORITY:-$HOME/.Xauthority}" have_xauth=false x_sock
  if [[ "${DISPLAY:-}" =~ ^(unix)?:([0-9]+) ]]; then
    x_sock="/tmp/.X11-unix/X${BASH_REMATCH[2]}"
    _RF_ARGS+=(--ro-bind-try "$x_sock" "$x_sock")
  fi
  if [[ -f "$xauth_file" ]]; then
    _RF_ARGS+=(--ro-bind "$xauth_file" /tmp/.ulpm-xauth)
    have_xauth=true
  fi

  # --- audio: host sockets only (clients inside talk to the host server) ---
  local pulse_sock="$run_user_dir/pulse/native"
  if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
    pulse_sock="${BASH_REMATCH[1]}"
  fi
  _RF_ARGS+=(
    --bind-try "$pulse_sock" "$pulse_sock"
    --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
  )

  if [[ "$force_offline" == "true" || "$allow_net" == "false" ]]; then
    _RF_ARGS+=(--unshare-net)
  fi

  # --- environment: always clean; the distro has its own PATH / libs ---
  _RF_ENV=(
    --clearenv
    --setenv HOME "$HOME"
    --setenv USER "${_RF_USER:-user}"
    --setenv LOGNAME "${_RF_USER:-user}"
    --setenv SHELL /bin/bash
    --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    --setenv TMPDIR /tmp
    --setenv XDG_RUNTIME_DIR "$run_user_dir"
    --setenv PULSE_SERVER "unix:$pulse_sock"
    --setenv PIPEWIRE_RUNTIME_DIR "$run_user_dir"
    --setenv ULPM_ROOTFS 1
  )
  for v in LANG LANGUAGE TZ TERM COLORTERM DISPLAY XCURSOR_THEME XCURSOR_SIZE \
           GDK_SCALE GDK_DPI_SCALE QT_SCALE_FACTOR ${ULPM_ENV_PASSTHROUGH:-}; do
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -n "${!v+x}" ]]; then
      _RF_ENV+=(--setenv "$v" "${!v}")
    fi
  done
  while IFS= read -r v; do
    if [[ -n "$v" ]]; then
      _RF_ENV+=(--setenv "$v" "${!v}")
    fi
  done < <(compgen -e | grep -E '^LC_[A-Z_]+$' || true)
  if [[ "$have_xauth" == "true" ]]; then
    _RF_ENV+=(--setenv XAUTHORITY /tmp/.ulpm-xauth)
  fi
  return 0
}

# ============================================================================
# Host pictures + persistent writable system (apt) for rootfs mode
# ----------------------------------------------------------------------------
# * Wallpapers: the XDG Pictures folder (and the folders listed in
#   ULPM_ROOTFS_RO_DIRS) are mapped READ-ONLY at the same path as on the host,
#   and the host /usr/share/backgrounds at /mnt/host-backgrounds, so the desktop
#   can pick a background from them.
# * apt: ULPM_ROOTFS_ADMIN=1 starts the session as (fake) root on a persistent,
#   writable copy of the system kept in ~/.var/app/<id>/rootfs, where apt can
#   install packages. Later runs WITHOUT the variable keep using that copy as a
#   normal user, until ULPM_ROOTFS_RESET=1 deletes it (back to the pristine
#   read-only package).
# ============================================================================

_rf_host_media_args() {
  local d real pics
  pics="$(xdg-user-dir PICTURES 2>/dev/null || true)"
  for d in "$pics" ${ULPM_ROOTFS_RO_DIRS:-}; do
    [[ -n "$d" && -d "$d" ]] || continue
    real="$(realpath -- "$d" 2>/dev/null || true)"
    [[ -n "$real" && "$real" != "/" && "$real" != "$HOME" ]] || continue
    case "$real" in
      /usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*) continue ;;
      /etc|/etc/*|/var|/var/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/tmp|/tmp/*|/boot|/boot/*) continue ;;
    esac
    _RF_ARGS+=(--ro-bind "$real" "$real")
  done
  if [[ -d /usr/share/backgrounds ]]; then
    _RF_ARGS+=(--ro-bind /usr/share/backgrounds /mnt/host-backgrounds)
  fi
  return 0
}

_rf_rw_dir() {
  printf '%s' "$HOME/.var/app/$1/rootfs"
}

# Like _rf_map_entries, but the entries are bound READ-WRITE.
_rf_map_entries_rw() {
  local src="$1" dst="$2" skip=" $3 " e name
  for e in "$src"/*; do
    [[ -e "$e" || -L "$e" ]] || continue
    name="${e##*/}"
    [[ "$skip" == *" $name "* ]] && continue
    if [[ -L "$e" ]]; then
      _RF_ARGS+=(--symlink "$(readlink -- "$e")" "$dst/$name")
    else
      _RF_ARGS+=(--bind "$e" "$dst/$name")
    fi
  done
  return 0
}

# The real sudo can never work inside this sandbox: bubblewrap sets the kernel
# "no new privileges" flag (not a sudo.conf option), which forbids every setuid
# program. In admin mode the session is already root, so this stand-in simply runs
# the command; otherwise it explains how to get root.
_rf_sudo_shim() {
  cat <<'SHIM'
#!/bin/sh
# Installed by ULPM (see sandbox.sh): stand-in for sudo inside the sandbox.
if [ "$(id -u)" != "0" ]; then
  echo "sudo: not available here: the sandbox sets 'no new privileges', so setuid programs cannot work." >&2
  echo "      Restart the system in admin mode (you are then already root, no sudo needed):" >&2
  echo "        ULPM_ROOTFS_ADMIN=1 ulpm run <package.lpk>" >&2
  exit 1
fi
shell=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -s|--shell) shell=sh; shift ;;
    -i|--login) shell=login; shift ;;
    -u|--user)
      if [ "${2:-root}" != "root" ]; then
        echo "sudo: switching to user '$2' is not possible in this sandbox, running as root" >&2
      fi
      shift 2 ;;
    -g|--group|-p|--prompt|-C|--close-from|-h|--host|-r|--role|-t|--type|-T|--command-timeout|-D|--chdir|-R|--chroot|-U|--other-user) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
case "$shell" in
  sh)
    if [ $# -gt 0 ]; then exec "${SHELL:-/bin/sh}" -c "$*"; fi
    exec "${SHELL:-/bin/sh}" ;;
  login)
    if [ $# -gt 0 ]; then exec "${SHELL:-/bin/sh}" -l -c "$*"; fi
    exec "${SHELL:-/bin/sh}" -l ;;
esac
if [ $# -eq 0 ]; then
  echo "usage: sudo [-s|-i] command [args...]" >&2
  exit 1
fi
exec "$@"
SHIM
}

# Creates (once) the writable copy of the package's system, then re-syncs the few
# files that must describe this host. Returns non-zero on failure.
_rf_rw_prepare() {
  local mnt="$1" app_id="$2" rw part f tz need_kb avail_kb size_txt=""
  rw="$(_rf_rw_dir "$app_id")"
  part="$rw.partial"

  if [[ ! -f "$rw/.ulpm-rw-ready" ]]; then
    rm -rf -- "$rw" "$part"
    mkdir -p -- "$(dirname "$rw")"

    need_kb="$(du -sk -- "$mnt/root" 2>/dev/null | cut -f1 || true)"
    avail_kb="$(df -Pk -- "$(dirname "$rw")" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ "$need_kb" =~ ^[0-9]+$ ]]; then
      size_txt=" (~$((need_kb / 1024)) MB)"
      if [[ "$avail_kb" =~ ^[0-9]+$ ]] && (( avail_kb < need_kb + need_kb / 10 )); then
        echo -e "${RED}[-] Not enough disk space for the writable system copy: need ~$((need_kb / 1024)) MB, $((avail_kb / 1024)) MB free in $(dirname "$rw")${NC}" >&2
        return 1
      fi
    fi

    echo -e "${CYAN}-> Creating the writable copy of the system${size_txt}: one time only, please wait...${NC}" >&2
    mkdir -p -- "$part"
    if ! cp -a --reflink=auto -- "$mnt/root/." "$part/"; then
      rm -rf -- "$part"
      echo -e "${RED}[-] Failed to copy the system to $part${NC}" >&2
      return 1
    fi

    # one-time adjustments of the copy
    mkdir -p -- "$part/etc/apt/apt.conf.d" "$part/var/cache/apt/archives/partial" \
      "$part/var/lib/apt/lists/partial" "$part/var/lib/dpkg" "$part/var/lib/dbus"
    # user namespaces map a single uid: apt cannot drop to its _apt user
    printf 'APT::Sandbox::User "root";\n' > "$part/etc/apt/apt.conf.d/99ulpm-sandbox"
    if [[ ! -e "$part/var/lib/dbus/machine-id" && ! -L "$part/var/lib/dbus/machine-id" ]]; then
      ln -s /etc/machine-id "$part/var/lib/dbus/machine-id"
    fi

    if ! mv -- "$part" "$rw" || ! : > "$rw/.ulpm-rw-ready"; then
      rm -rf -- "$part" "$rw"
      echo -e "${RED}[-] Failed to finalize the writable system copy${NC}" >&2
      return 1
    fi
    echo -e "${GREEN}✔ Writable system copy ready: $rw${NC}" >&2
  fi

  # Files bind-mounted over by generated ones must be regular files, never symlinks.
  for f in resolv.conf hosts hostname machine-id; do
    [[ -L "$rw/etc/$f" ]] && rm -f -- "$rw/etc/$f"
    [[ -e "$rw/etc/$f" ]] || : > "$rw/etc/$f"
  done

  # Same time zone as the host.
  tz="$(readlink -f /etc/localtime 2>/dev/null || true)"
  if [[ "$tz" == /usr/share/zoneinfo/* && -e "$rw$tz" ]]; then
    ln -sfn -- "$tz" "$rw/etc/localtime"
  fi

  # Stand-in for sudo (the real one cannot work here: no_new_privs).
  mkdir -p -- "$rw/usr/local/bin"
  if ! _rf_sudo_shim | cmp -s - "$rw/usr/local/bin/sudo" 2>/dev/null; then
    _rf_sudo_shim > "$rw/usr/local/bin/sudo.new" \
      && chmod 0755 "$rw/usr/local/bin/sudo.new" \
      && mv -f -- "$rw/usr/local/bin/sudo.new" "$rw/usr/local/bin/sudo"
  fi
  return 0
}

# Builds _RF_ARGS / _RF_ENV on the persistent writable copy.
# admin=true: fake root (uid 0 in a user namespace, capabilities kept) so that
# apt/dpkg work; admin=false: normal user, capabilities dropped.
_rf_build_args_persistent() {
  local mnt="$1" app_id="$2" force_offline="$3" allow_net="$4" admin="$5"
  local rw run_uid run_user_dir app_data_dir gen dl_dir v env_user
  rw="$(_rf_rw_dir "$app_id")"
  _RF_ARGS=()
  _RF_ENV=()
  _RF_USER=""

  _rf_rw_prepare "$mnt" "$app_id" || return 1

  run_uid="$(id -u)"
  run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"
  app_data_dir="$HOME/.var/app/$app_id"
  mkdir -p "$app_data_dir/home"
  gen="$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/rootfs.XXXXXX")"
  _rf_gen_files "$rw" "$gen" "$app_data_dir"

  # /etc is persistent here: keep this host user and a machine-id in it.
  cmp -s "$gen/passwd" "$rw/etc/passwd" || cat "$gen/passwd" > "$rw/etc/passwd"
  cmp -s "$gen/group" "$rw/etc/group" || cat "$gen/group" > "$rw/etc/group"
  [[ -s "$rw/etc/machine-id" ]] || cat "$app_data_dir/machine-id" > "$rw/etc/machine-id"

  dl_dir="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
  if [[ -z "$dl_dir" || "$dl_dir" == "$HOME" || "$dl_dir" == "$HOME/" ]]; then
    dl_dir="$HOME/Downloads"
  fi
  mkdir -p "$dl_dir"

  _RF_ARGS+=(--die-with-parent --new-session --unshare-uts --unshare-cgroup-try)
  if [[ "$admin" == "true" ]]; then
    _RF_ARGS+=(--unshare-user --uid 0 --gid 0)
  else
    _RF_ARGS+=(--cap-drop ALL)
  fi
  if [[ "$ULPM_SHARE_PID" != "true" ]]; then
    _RF_ARGS+=(--unshare-pid)
  fi
  if [[ -z "${DISPLAY:-}" ]]; then
    _RF_ARGS+=(--unshare-ipc)
  fi

  # --- the persistent writable system (usr, etc, var, opt, ... all read-write) ---
  _rf_map_entries_rw "$rw" "" "dev proc sys tmp run home root mnt media boot"
  _RF_ARGS+=(
    --ro-bind "$gen/hosts"    /etc/hosts
    --ro-bind "$gen/hostname" /etc/hostname
    --ro-bind "$gen/resolv.conf" /etc/resolv.conf
  )

  _RF_ARGS+=(
    --proc /proc
    --dev /dev
    --tmpfs /dev/shm
    --ro-bind /sys /sys
    --perms 1777 --tmpfs /tmp
    --tmpfs /run
    --dir /run/lock
    --perms 0700 --dir "$run_user_dir"
    --dev-bind-try /dev/dri /dev/dri
  )

  _RF_ARGS+=(
    --bind "$app_data_dir/home" "$HOME"
    --bind "$dl_dir" "$dl_dir"
  )
  _rf_host_media_args

  local xauth_file="${XAUTHORITY:-$HOME/.Xauthority}" have_xauth=false x_sock
  if [[ "${DISPLAY:-}" =~ ^(unix)?:([0-9]+) ]]; then
    x_sock="/tmp/.X11-unix/X${BASH_REMATCH[2]}"
    _RF_ARGS+=(--ro-bind-try "$x_sock" "$x_sock")
  fi
  if [[ -f "$xauth_file" ]]; then
    _RF_ARGS+=(--ro-bind "$xauth_file" /tmp/.ulpm-xauth)
    have_xauth=true
  fi

  local pulse_sock="$run_user_dir/pulse/native"
  if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
    pulse_sock="${BASH_REMATCH[1]}"
  fi
  _RF_ARGS+=(
    --bind-try "$pulse_sock" "$pulse_sock"
    --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
  )

  if [[ "$force_offline" == "true" || "$allow_net" == "false" ]]; then
    _RF_ARGS+=(--unshare-net)
  fi

  env_user="${_RF_USER:-user}"
  if [[ "$admin" == "true" ]]; then
    env_user="root"
  fi
  _RF_ENV=(
    --clearenv
    --setenv HOME "$HOME"
    --setenv USER "$env_user"
    --setenv LOGNAME "$env_user"
    --setenv SHELL /bin/bash
    --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    --setenv TMPDIR /tmp
    --setenv XDG_RUNTIME_DIR "$run_user_dir"
    --setenv PULSE_SERVER "unix:$pulse_sock"
    --setenv PIPEWIRE_RUNTIME_DIR "$run_user_dir"
    --setenv ULPM_ROOTFS 1
  )
  for v in LANG LANGUAGE TZ TERM COLORTERM DISPLAY XCURSOR_THEME XCURSOR_SIZE \
           GDK_SCALE GDK_DPI_SCALE QT_SCALE_FACTOR ${ULPM_ENV_PASSTHROUGH:-}; do
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -n "${!v+x}" ]]; then
      _RF_ENV+=(--setenv "$v" "${!v}")
    fi
  done
  while IFS= read -r v; do
    if [[ -n "$v" ]]; then
      _RF_ENV+=(--setenv "$v" "${!v}")
    fi
  done < <(compgen -e | grep -E '^LC_[A-Z_]+$' || true)
  if [[ "$have_xauth" == "true" ]]; then
    _RF_ENV+=(--setenv XAUTHORITY /tmp/.ulpm-xauth)
  fi
  return 0
}

# Chooses between the pristine read-only package (default, unchanged behaviour)
# and the persistent writable copy (ULPM_ROOTFS_ADMIN=1, or copy already created).
_rf_build_args_auto() {
  local mnt="$1" app_id="$2" force_offline="$3" allow_net="$4"
  local admin=false rw
  rw="$(_rf_rw_dir "$app_id")"

  case "${ULPM_ROOTFS_ADMIN:-}" in
    1|true|yes|on) admin=true ;;
  esac
  case "${ULPM_ROOTFS_RESET:-}" in
    1|true|yes|on)
      echo -e "${YELLOW}[!] Removing the writable system copy: $rw${NC}" >&2
      rm -rf -- "$rw" "$rw.partial"
      ;;
  esac

  if [[ "$admin" == "true" || -f "$rw/.ulpm-rw-ready" ]]; then
    if [[ "$admin" == "true" ]]; then
      echo -e "${CYAN}-> Admin mode: you are already root (no sudo needed): run apt directly. System changes are kept in $rw${NC}" >&2
    else
      echo -e "${CYAN}-> Using the writable system copy: $rw${NC}" >&2
    fi
    _rf_build_args_persistent "$mnt" "$app_id" "$force_offline" "$allow_net" "$admin"
    return $?
  fi

  _rf_build_args "$mnt" "$app_id" "$force_offline" "$allow_net"
}

lpk_run_rootfs() {
  local app_id="$1" exec_bin="$2" force_offline="$3" allow_net="$4"
  shift 4

  echo -e "${CYAN}-> Distribution package: running on its own root filesystem${NC}" >&2
  _rf_build_args_auto "$RUN_MNT_DIR" "$app_id" "$force_offline" "$allow_net" || {
    cleanup_instance
    trap cleanup_temp EXIT
    return 1
  }

  local rc=0
  if [[ -n "${ULPM_DEBUG_BWRAP:-}" ]]; then
    # Debug: print the exact command instead of running it.
    printf '%q ' bwrap "${_RF_ARGS[@]}" "${_RF_ENV[@]}" --chdir "$HOME" "/$exec_bin" "$@"
    echo
  else
    bwrap "${_RF_ARGS[@]}" "${_RF_ENV[@]}" \
      --chdir "$HOME" \
      "/$exec_bin" "$@" || rc=$?
  fi

  cleanup_instance
  trap cleanup_temp EXIT
  return "$rc"
}
