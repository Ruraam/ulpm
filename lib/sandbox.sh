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