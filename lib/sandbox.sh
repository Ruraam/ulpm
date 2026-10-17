#!/usr/bin/env bash
# ==============================================================================
# lib/sandbox.sh - Concurrent-Safe Production Sandboxing Engine (App & RootFS)
# ULPM v5.3 Architecture Engine (Manifest v5, Multi-Axis Runtimes & Hardened BPF)
# ==============================================================================

ENV_WHITELIST=(
    HOME USER LOGNAME LANG LANGUAGE LC_ALL TZ TERM COLORTERM
    DISPLAY XAUTHORITY WAYLAND_DISPLAY
    XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION
    XDG_RUNTIME_DIR
    GDK_BACKEND GDK_SCALE GDK_DPI_SCALE GTK_THEME
    QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME QT_SCALE_FACTOR QT_AUTO_SCREEN_SCALE_FACTOR
    XCURSOR_THEME XCURSOR_SIZE SDL_VIDEODRIVER MOZ_ENABLE_WAYLAND
    __GLX_VENDOR_LIBRARY_NAME __NV_PRIME_RENDER_OFFLOAD__ VK_LAYER_NV_optimus
    VK_ICD_FILENAMES VK_DRIVER_FILES LIBVA_DRIVER_NAME MESA_LOADER_DRIVER_OVERRIDE
    RECALBOX_SYSTEM_DIR CONTROLLER_CONFIG SDL_JOYSTICK_DEVICE
)

# ------------------------------------------------------------------------------
# Universal Host Downloads Discovery & Linking (Multi-Language Aware)
# ------------------------------------------------------------------------------

resolve_host_downloads_dir() {
    local candidate=""

    if command -v xdg-user-dir >/dev/null 2>&1; then
        candidate="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    fi

    if [[ -z "$candidate" || "$candidate" == "$HOME" ]] && [[ -f "$HOME/.config/user-dirs.dirs" ]]; then
        local raw
        raw="$(grep -E '^XDG_DOWNLOAD_DIR=' "$HOME/.config/user-dirs.dirs" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        raw="${raw/#\$HOME/$HOME}"
        [[ -n "$raw" && -d "$raw" ]] && candidate="$raw"
    fi

    if [[ -z "$candidate" || "$candidate" == "$HOME" ]]; then
        local name
        for name in "Téléchargements" "Downloads" "Descargas" "Download" "Scaricati"; do
            if [[ -d "$HOME/$name" ]]; then
                candidate="$HOME/$name"
                break
            fi
        done
    fi

    candidate="${candidate:-$HOME/Downloads}"
    mkdir -p "$candidate" 2>/dev/null || candidate="$HOME"
    printf '%s\n' "$candidate"
}

setup_sandbox_downloads_links() {
    local target_home="$1"
    local host_dl="$2"
    local dl_basename
    dl_basename="$(basename -- "$host_dl")"

    mkdir -p "$target_home/$dl_basename" 2>/dev/null || true

    if [[ "$dl_basename" != "Downloads" ]]; then
        ln -snf "$dl_basename" "$target_home/Downloads" 2>/dev/null || true
    fi
    if [[ "$dl_basename" != "Téléchargements" ]]; then
        ln -snf "$dl_basename" "$target_home/Téléchargements" 2>/dev/null || true
    fi
}

session_bus_socket() {
    local run_user_dir="$1"
    local addr="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$run_user_dir/bus}"
    if [[ "$addr" =~ ^unix:path=([^,]+) ]] && [[ -S "${BASH_REMATCH[1]}" ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ -n "$run_user_dir" && -S "$run_user_dir/bus" ]]; then
        printf '%s\n' "$run_user_dir/bus"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Security & Cryptographic Validation Integration
# ------------------------------------------------------------------------------

_ulpm_check_signature() {
    local pkg_path="${1:-}"
    if declare -F check_package_signature >/dev/null 2>&1; then
        check_package_signature "$pkg_path"
    elif declare -F verify_package >/dev/null 2>&1; then
        local rc=0
        verify_package "$pkg_path" || rc=$?
        case "$rc" in
            0) return 0 ;;
            3)
                if [[ "${ULPM_STRICT_SIGNATURES:-0}" != 1 ]]; then
                    warn "Package signature is untrusted; running in compatibility mode."
                    return 0
                fi
                error "Untrusted package signature; rejected by strict mode."
                return 1
                ;;
            2)
                if [[ "${ULPM_ALLOW_UNSIGNED:-0}" == 1 && "${ULPM_STRICT_SIGNATURES:-0}" != 1 ]]; then
                    warn "Executing unsigned package (ULPM_ALLOW_UNSIGNED=1)."
                    return 0
                fi
                error "Package is unsigned; execution refused."
                return 1
                ;;
            *)
                error "Invalid or corrupted package signature."
                return 1
                ;;
        esac
    else
        return 0
    fi
}

# ------------------------------------------------------------------------------
# Shared Runtime Resolution (Four-Axis Matrix)
# ------------------------------------------------------------------------------

resolve_shared_runtime() {
    local runtime_id="$1" runtime_ver="${2:-latest}" runtime_abi="${3:-default}"
    local host_arch
    host_arch="$(detect_arch)"

    local runtimes_dir="${ULPM_RUNTIMES_DIR:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/runtimes}"
    local candidate_dir="$runtimes_dir/$runtime_id/$runtime_ver/$host_arch/$runtime_abi"

    if [[ -d "$candidate_dir" && -d "$candidate_dir/usr" ]]; then
        printf '%s\n' "$candidate_dir"
        return 0
    fi

    # Fallback to any matching runtime version if "latest" requested
    if [[ "$runtime_ver" == "latest" ]] && [[ -d "$runtimes_dir/$runtime_id" ]]; then
        local match
        match="$(find "$runtimes_dir/$runtime_id" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort -V | tail -n 1)"
        if [[ -n "$match" && -d "$match/usr" ]]; then
            printf '%s\n' "$match"
            return 0
        fi
    fi

    return 1
}

# ------------------------------------------------------------------------------
# RootFS Detection & Container Execution Mode
# ------------------------------------------------------------------------------

lpk_is_rootfs() {
    local mount_dir="$1"
    local manifest="${2:-}"

    if [[ -f "$manifest" ]]; then
        local is_rootfs
        is_rootfs=$(jq -r '.type // .kind // empty' "$manifest" 2>/dev/null || true)
        if [[ "$is_rootfs" =~ ^(rootfs|distro|os)$ ]]; then
            return 0
        fi
    fi

    if [[ -d "$mount_dir/root/etc" && -d "$mount_dir/root/usr" ]]; then
        if [[ -d "$mount_dir/root/bin" || -L "$mount_dir/root/bin" ]]; then
            return 0
        fi
    fi

    if [[ -d "$mount_dir/etc" && -d "$mount_dir/usr" ]]; then
        if [[ -d "$mount_dir/bin" || -L "$mount_dir/bin" ]]; then
            return 0
        fi
    fi

    return 1
}

lpk_run_rootfs() {
    local mnt_dir="$1"
    local app_id="$2"
    local exec_bin="$3"
    local force_offline="$4"
    local allow_net="$5"
    local disable_gpu="$6"
    local disable_audio="$7"
    local disable_gui="$8"
    local disable_input="${9:-false}"
    local custom_binds_ref="${10:-}"
    shift 10 2>/dev/null || shift $#

    local -a cbinds=()
    if [[ -n "$custom_binds_ref" ]]; then
        local -n _bind_source="$custom_binds_ref"
        cbinds=("${_bind_source[@]}")
    fi

    local rootfs_dir="$mnt_dir"
    if [[ -d "$mnt_dir/root" && -d "$mnt_dir/root/etc" ]]; then
        rootfs_dir="$mnt_dir/root"
    fi

    local app_data_dir="$HOME/.var/app/$app_id"
    mkdir -p "$app_data_dir/home" "$app_data_dir/cache" "$app_data_dir/tmp"

    local run_uid run_user_dir
    run_uid="$(id -u)"
    run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"

    local dl_host_dir
    dl_host_dir="$(resolve_host_downloads_dir)"
    setup_sandbox_downloads_links "$app_data_dir/home" "$dl_host_dir"

    local entrypoint="${exec_bin:-/bin/sh}"
    if [[ -z "$exec_bin" || "$exec_bin" == "/bin/main" || "$exec_bin" == "bin/main" ]]; then
        if [[ -x "$rootfs_dir/usr/bin/startxfce4" ]]; then
            entrypoint="/usr/bin/startxfce4"
        elif [[ -x "$rootfs_dir/usr/bin/x-session-manager" ]]; then
            entrypoint="/usr/bin/x-session-manager"
        elif [[ -x "$rootfs_dir/bin/bash" ]]; then
            entrypoint="/bin/bash"
        fi
    fi

    local sanitized_args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            ""|"%u"|"%U"|"%f"|"%F") ;;
            *) sanitized_args+=("$arg") ;;
        esac
    done

    if ! command -v bwrap >/dev/null 2>&1 || is_proot || ! bwrap --ro-bind / / true >/dev/null 2>&1; then
        warn "Bubblewrap sandbox unavailable; executing rootfs entrypoint directly under host..."
        export PATH="$rootfs_dir/bin:$rootfs_dir/usr/bin:$PATH"
        export LD_LIBRARY_PATH="$rootfs_dir/lib:$rootfs_dir/usr/lib:$rootfs_dir/lib64:$rootfs_dir/usr/lib64:${LD_LIBRARY_PATH:-}"
        exec "$rootfs_dir/$entrypoint" ${sanitized_args[@]+"${sanitized_args[@]}"}
    fi

    local bwrap_args=(
        bwrap
        --die-with-parent
        --new-session
        --clearenv
        --cap-drop ALL
        --unshare-uts
        --unshare-pid
        --unshare-cgroup-try
        --chdir "$HOME"
        --proc /proc
        --dev /dev
        --dev-bind /dev/shm /dev/shm
        --ro-bind /sys /sys
        --tmpfs /tmp
        --tmpfs /run
        --tmpfs /var/tmp
        --ro-bind "$rootfs_dir" /
        --bind "$app_data_dir/home" "$HOME"
        --bind "$app_data_dir/tmp" /tmp
        --bind "$dl_host_dir" "$dl_host_dir"
    )

    if [[ "$disable_gui" == "true" || -z "${DISPLAY:-}" ]]; then
        bwrap_args+=(--unshare-ipc)
    fi

    if [[ -f "$HOME/.config/user-dirs.dirs" ]]; then
        bwrap_args+=(--ro-bind-try "$HOME/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs")
    fi

    if [[ "$force_offline" == "true" || "$allow_net" == "false" ]]; then
        bwrap_args+=(--unshare-net)
    else
        bwrap_args+=(--share-net)
        local real_resolv
        real_resolv="$(realpath /etc/resolv.conf 2>/dev/null || echo "/etc/resolv.conf")"
        [[ -f "$real_resolv" ]] && bwrap_args+=(--ro-bind-try "$real_resolv" "$real_resolv")
        bwrap_args+=(
            --ro-bind-try /etc/resolv.conf /etc/resolv.conf
            --ro-bind-try /etc/hosts /etc/hosts
            --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
            --ro-bind-try /etc/gai.conf /etc/gai.conf
            --ro-bind-try /run/systemd/resolve /run/systemd/resolve
            --ro-bind-try /etc/ssl /etc/ssl
            --ro-bind-try /etc/pki /etc/pki
            --ro-bind-try /etc/ca-certificates /etc/ca-certificates
            --ro-bind-try /usr/share/ca-certificates /usr/share/ca-certificates
        )
    fi

    if [[ "$disable_input" != "true" ]]; then
        bwrap_args+=(
            --dev-bind-try /dev/input /dev/input
            --dev-bind-try /dev/uinput /dev/uinput
        )
        local js
        for js in /dev/js[0-9]*; do
            [[ -e "$js" ]] && bwrap_args+=(--dev-bind-try "$js" "$js")
        done
    fi

    bwrap_args+=(
        --dev-bind-try /dev/fb0 /dev/fb0
        --ro-bind-try /run/udev /run/udev
    )

    if [[ "$disable_gpu" != "true" ]]; then
        bwrap_args+=(--dev-bind-try /dev/dri /dev/dri)
        shopt -s nullglob
        local dev
        for dev in /dev/nvidia* /dev/nvidia-uvm* /dev/nvidia-modeset*; do
            [[ -e "$dev" ]] && bwrap_args+=(--dev-bind-try "$dev" "$dev")
        done
        shopt -u nullglob
    fi

    if [[ "$disable_audio" != "true" ]]; then
        bwrap_args+=(--dev-bind-try /dev/snd /dev/snd)
        local pulse_sock="$run_user_dir/pulse/native"
        if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
            pulse_sock="${BASH_REMATCH[1]}"
        fi
        bwrap_args+=(
            --bind-try "$pulse_sock" "$pulse_sock"
            --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
        )
    fi

    if [[ -d "/recalbox/share" ]]; then
        bwrap_args+=(
            --bind-try /recalbox/share /recalbox/share
            --bind-try /recalbox/share/roms /recalbox/share/roms
            --bind-try /recalbox/share/saves /recalbox/share/saves
            --bind-try /recalbox/share/bios /recalbox/share/bios
            --bind-try /recalbox/share/system /recalbox/share/system
        )
    fi

    if [[ "$disable_gui" != "true" ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then
            local x_sock
            if [[ "$DISPLAY" =~ ^(unix)?:([0-9]+) ]]; then
                x_sock="/tmp/.X11-unix/X${BASH_REMATCH[2]}"
                bwrap_args+=(--ro-bind-try "$x_sock" "$x_sock")
            else
                bwrap_args+=(--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)
            fi
            local xauth_file="${XAUTHORITY:-$HOME/.Xauthority}"
            [[ -f "$xauth_file" ]] && bwrap_args+=(--ro-bind "$xauth_file" "$xauth_file")
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
    fi

    local b
    for b in "${cbinds[@]}"; do
        local h_dir="${b%%:*}"
        local d_dir="${b#*:}"
        if [[ -e "$h_dir" ]]; then
            local real_h
            real_h="$(realpath -e -- "$h_dir" 2>/dev/null || true)"
            if [[ -n "$real_h" ]] && _ulpm_valid_bind_dest "$d_dir"; then
                bwrap_args+=(--bind "$real_h" "$d_dir")
            else
                warn "Skipping unsafe bind mapping: $h_dir -> $d_dir"
            fi
        else
            warn "Host bind source does not exist: $h_dir"
        fi
    done

    local env_var
    for env_var in "${ENV_WHITELIST[@]}"; do
        if [[ "$disable_gui" == "true" ]] && [[ "$env_var" =~ (DISPLAY|WAYLAND) ]]; then
            continue
        fi
        if [[ -n "${!env_var:-}" ]]; then
            bwrap_args+=(--setenv "$env_var" "${!env_var}")
        fi
    done

    log "Starting RootFS session [$app_id] (Entrypoint: $entrypoint)..."
    "${bwrap_args[@]}" "$entrypoint" ${sanitized_args[@]+"${sanitized_args[@]}"}
}

# --------------------------------------------------------------
# App Mode Execution (Shared Host Base + Isolated Sandbox)
# --------------------------------------------------------------

lpk_run_isolated() {
    local cli_force_offline=false
    local cli_no_gpu=false
    local cli_no_audio=false
    local cli_no_gui=false
    local cli_no_input=false
    local cli_profile=""
    local custom_binds=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gaming)
                cli_profile="gaming"
                shift
                ;;
            --strict)
                cli_profile="strict"
                shift
                ;;
            --desktop)
                cli_profile="desktop"
                shift
                ;;
            --offline|--no-net)
                cli_force_offline=true
                shift
                ;;
            --net)
                cli_force_offline=false
                shift
                ;;
            --no-gpu)
                cli_no_gpu=true
                shift
                ;;
            --no-audio)
                cli_no_audio=true
                shift
                ;;
            --no-gui)
                cli_no_gui=true
                shift
                ;;
            --no-input)
                cli_no_input=true
                shift
                ;;
            --bind)
                if [[ -n "${2:-}" && "$2" == *:* ]]; then
                    custom_binds+=("$2")
                    shift 2
                else
                    error "--bind requires argument formatted as <host_path>:<dest_path>"
                    return 1
                fi
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "Unknown sandbox flag: $1"
                return 1
                ;;
            *)
                break
                ;;
        esac
    done

    local target="${1:-}"
    if [[ -z "$target" ]]; then
        error "No target specified"
        return 1
    fi
    shift || true

    target="$(normalize_target "$target")"

    local pkg_path=""
    if [[ -f "$target" ]]; then
        pkg_path="$(realpath -- "$target")"
    elif [[ -f "${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}/$target.lpk" ]]; then
        pkg_path="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}/$target.lpk"
    elif [[ -f "${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}/$target/$target.lpk" ]]; then
        pkg_path="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}/$target/$target.lpk"
    elif [[ -f "${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}/io.lpk.${target,,}.lpk" ]]; then
        pkg_path="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}/io.lpk.${target,,}.lpk"
    else
        error "Target package '$target' could not be resolved"
        return 1
    fi

    _ulpm_check_signature "$pkg_path" || return 1

    local instance_id="$$_${RANDOM}"
    local cache_dir="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
    mkdir -p -- "$cache_dir"
    local mnt_dir dbus_proxy_dir dbus_pid=""
    mnt_dir="$(mktemp -d "${cache_dir}/mnt_${instance_id}.XXXXXX")"
    local is_extracted=0

    # Variable protégée pour le mode nounset (set -u)
    local cleanup_done=0
    # shellcheck disable=SC2329
    _cleanup_sandbox_instance() {
        (( ${cleanup_done:-0} )) && return 0
        cleanup_done=1
        exec 9<&- 2>/dev/null || true
        if [[ -n "${dbus_pid:-}" ]] && kill -0 "$dbus_pid" 2>/dev/null; then
            kill "$dbus_pid" 2>/dev/null || true
            sleep 0.05
            kill -9 "$dbus_pid" 2>/dev/null || true
            wait "$dbus_pid" 2>/dev/null || true
        fi
        [[ -n "${dbus_proxy_dir:-}" && -d "$dbus_proxy_dir" ]] && rm -rf "$dbus_proxy_dir"
        if (( ${is_extracted:-0} == 0 )); then
            safe_unmount "$mnt_dir"
        fi
        [[ -n "${mnt_dir:-}" && -d "$mnt_dir" ]] && rm -rf "$mnt_dir"
    }

    trap '_cleanup_sandbox_instance; exit 130' INT
    trap '_cleanup_sandbox_instance; exit 143' TERM
    trap '_cleanup_sandbox_instance; exit 129' HUP
    trap '_cleanup_sandbox_instance' EXIT

    local mount_ok=0
    if can_use_fuse && command -v squashfuse >/dev/null 2>&1; then
        if squashfuse "$pkg_path" "$mnt_dir" 2>/dev/null; then
            mount_ok=1
        fi
    fi

    if (( mount_ok == 0 )); then
        check_dependencies unsquashfs || {
            error "Neither FUSE mounting nor unsquashfs is available to access $pkg_path"
            return 1
        }
        log "Mount unavailable (FUSE restricted); unpacking payload temporarily via unsquashfs..."
        if ! unsquashfs -f -d "$mnt_dir" "$pkg_path" >/dev/null 2>&1; then
            error "Failed to unpack SquashFS payload ($pkg_path)"
            return 1
        fi
        is_extracted=1
    fi

    local manifest_file="$mnt_dir/meta/manifest.json"
    [[ ! -f "$manifest_file" ]] && manifest_file="$mnt_dir/lpk.json"

    local app_id
    app_id="app_$(basename -- "$target" .lpk)"

    if [[ -f "$manifest_file" ]]; then
        local raw_id
        raw_id=$(jq -r '.id // .name // empty' "$manifest_file" 2>/dev/null || true)
        if [[ -n "$raw_id" ]]; then
            if ! is_safe_app_id "$raw_id"; then
                error "Refusing to run: unsafe application id in manifest: '$raw_id'"
                return 1
            fi
            app_id="$raw_id"
        fi
    fi

    local package_arch
    package_arch="$(jq -r '.arch // "all"' "$manifest_file" 2>/dev/null || printf 'all')"
    if ! is_arch_compatible "$package_arch"; then
        error "Package architecture '$package_arch' is incompatible with host '$(detect_arch)'."
        return 1
    fi

    if lpk_is_rootfs "$mnt_dir" "$manifest_file"; then
        local exec_bin="bin/main"
        [[ -f "$manifest_file" ]] && exec_bin="$(jq -r '.exec // "bin/main"' "$manifest_file" 2>/dev/null || echo "bin/main")"
        local rootfs_rc=0
        lpk_run_rootfs "$mnt_dir" "$app_id" "$exec_bin" "$cli_force_offline" "true" \
            "$cli_no_gpu" "$cli_no_audio" "$cli_no_gui" "$cli_no_input" custom_binds "$@" || rootfs_rc=$?
        _cleanup_sandbox_instance
        trap - EXIT
        return "$rootfs_rc"
    fi

    local effective_json="{}"
    if declare -F manifest_resolve_effective >/dev/null 2>&1; then
        effective_json="$(manifest_resolve_effective "$manifest_file" "$app_id")"
    elif [[ -f "$manifest_file" ]]; then
        effective_json="$(cat "$manifest_file")"
    fi

    local exec_bin is_chromium allow_net allow_gpu allow_audio allow_gui
    local dev_dri dev_input dev_hidraw dev_usb dev_kvm home_mode dl_mode
    local req_runtime req_abi

    exec_bin="$(manifest_get "$effective_json" '.exec' "bin/main")"
    is_chromium="$(manifest_get "$effective_json" '.chromium' "false")"
    req_runtime="$(manifest_get "$effective_json" '.runtime' "")"
    req_abi="$(manifest_get "$effective_json" '.runtime_abi' "default")"

    allow_net="$(jq -r 'if has("permissions") then (.permissions.network // false) else (if has("network") then .network else true end) end' <<< "$effective_json")"
    allow_gpu="$(jq -r 'if has("permissions") then (.permissions.gpu // true) else true end' <<< "$effective_json")"
    allow_audio="$(jq -r 'if has("permissions") then (.permissions.audio // true) else true end' <<< "$effective_json")"
    allow_gui="$(jq -r 'if has("permissions") then (.permissions.gui // true) else true end' <<< "$effective_json")"

    home_mode="$(manifest_get "$effective_json" '.permissions.filesystem.home' "isolated")"
    dl_mode="$(manifest_get "$effective_json" '.permissions.filesystem.downloads' "read-write")"

    dev_dri="$(jq -r '.permissions.devices.dri // true' <<< "$effective_json")"
    dev_input="$(jq -r '.permissions.devices.input // true' <<< "$effective_json")"
    dev_hidraw="$(jq -r '.permissions.devices.hidraw // false' <<< "$effective_json")"
    dev_usb="$(jq -r '.permissions.devices.usb // false' <<< "$effective_json")"
    dev_kvm="$(jq -r '.permissions.devices.kvm // false' <<< "$effective_json")"

    case "$cli_profile" in
        gaming)
            allow_gpu=true; allow_audio=true; dev_dri=true; dev_input=true; dev_hidraw=true; dev_usb=true
            ;;
        strict)
            allow_net=false; allow_gpu=false; dev_dri=false; dev_input=false; home_mode="isolated"; dl_mode="none"
            ;;
        desktop)
            allow_gpu=true; allow_audio=true; allow_gui=true
            ;;
    esac

    [[ "$cli_force_offline" == "true" ]] && allow_net=false
    [[ "$cli_no_gpu" == "true" ]] && { allow_gpu=false; dev_dri=false; }
    [[ "$cli_no_audio" == "true" ]] && allow_audio=false
    [[ "$cli_no_gui" == "true" ]] && allow_gui=false
    [[ "$cli_no_input" == "true" ]] && dev_input=false

    local app_data_dir="$HOME/.var/app/$app_id"
    mkdir -p "$app_data_dir/home" "$app_data_dir/config" "$app_data_dir/data" "$app_data_dir/cache"

    local run_uid run_user_dir dl_host_dir
    run_uid="$(id -u)"
    run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"

    dl_host_dir="$(resolve_host_downloads_dir)"
    setup_sandbox_downloads_links "$app_data_dir/home" "$dl_host_dir"

    local clean_exec="${exec_bin#/}"
    if [[ "$clean_exec" =~ (^|/)\.\.(/|$) ]]; then
        error "Unsafe executable path detected in manifest: $clean_exec"
        return 1
    fi

    local app_payload_dir="$mnt_dir"
    [[ -d "$mnt_dir/root" ]] && app_payload_dir="$mnt_dir/root"

    # Chromium / Electron specific flags
    local extra_app_flags=()
    local is_electron_app=false
    if [[ "$is_chromium" == "true" ]] || [[ -f "$app_payload_dir/resources/app.asar" ]] || [[ -f "$app_payload_dir/electron" ]] || [[ "$(basename -- "$clean_exec")" =~ ^(chrome|chromium|brave|edge)$ ]]; then
        is_electron_app=true
    fi

    if [[ "$is_electron_app" == "true" ]]; then
        extra_app_flags=(
            --no-sandbox
            --test-type
            --disable-gpu-sandbox
            --disable-setuid-sandbox
            --disable-dev-shm-usage
            --log-level=3
        )
        if [[ -n "${WAYLAND_DISPLAY:-}" && "$allow_gui" == "true" ]]; then
            extra_app_flags+=(--ozone-platform-hint=auto)
        fi
    fi

    # Specific profile provisioning for Firefox
    if [[ "$app_id" =~ (firefox|Firefox) ]] || [[ "$clean_exec" =~ firefox ]]; then
        find "$app_data_dir/home/.mozilla" -name ".parentlock" -delete 2>/dev/null || true
        local ff_profile_dir="$app_data_dir/home/.mozilla/firefox/ulpm.default-release"
        mkdir -p "$ff_profile_dir"
        if [[ ! -f "$ff_profile_dir/user.js" ]]; then
            cat << 'EOF' > "$ff_profile_dir/user.js"
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "https://start.duckduckgo.com");
user_pref("browser.newtabpage.enabled", true);
user_pref("datareporting.policy.firstRunURL", "");
EOF
        fi
        if [[ ! -f "$app_data_dir/home/.mozilla/firefox/profiles.ini" ]]; then
            cat << EOF > "$app_data_dir/home/.mozilla/firefox/profiles.ini"
[Profile0]
Name=default-release
IsRelative=1
Path=ulpm.default-release
Default=1

[General]
StartWithLastProfile=1
Version=2
EOF
        fi
    fi

    local real_exec=""
    local cand
    for cand in "$app_payload_dir/$clean_exec" "$app_payload_dir/AppRun" "$app_payload_dir/bin/main" "$app_payload_dir/main"; do
        if [[ -x "$cand" && ! -d "$cand" ]]; then
            real_exec="$cand"
            break
        fi
    done

    [[ -n "$real_exec" ]] || {
        error "No executable entrypoint found in package payload: $clean_exec"
        return 1
    }

    local sanitized_args=()
    for arg in "$@"; do
        case "$arg" in
            ""|"%u"|"%U"|"%f"|"%F") ;;
            *) sanitized_args+=("$arg") ;;
        esac
    done

    if [[ "$app_id" =~ (firefox|Firefox) ]] || [[ "$clean_exec" =~ firefox ]]; then
        if [ ${#sanitized_args[@]} -eq 0 ]; then
            sanitized_args=("about:home")
        fi
    fi

    local can_use_bwrap=1
    if ! command -v bwrap >/dev/null 2>&1 || is_proot; then
        can_use_bwrap=0
    elif ! bwrap --ro-bind / / true >/dev/null 2>&1; then
        can_use_bwrap=0
    fi

    if (( can_use_bwrap == 0 )); then
        warn "Bubblewrap unprivileged sandbox unavailable. Executing in direct compatibility mode..."
        export PATH="$app_payload_dir/bin:$app_payload_dir/usr/bin:$app_payload_dir:/usr/bin:/bin"
        export LD_LIBRARY_PATH="$app_payload_dir/lib:$app_payload_dir/usr/lib:$app_payload_dir/lib64:$app_payload_dir/usr/lib64:${LD_LIBRARY_PATH:-}"
        export XDG_CONFIG_HOME="$app_data_dir/config"
        export XDG_DATA_HOME="$app_data_dir/data"
        export XDG_CACHE_HOME="$app_data_dir/cache"
        export XDG_DATA_DIRS="$app_payload_dir/share:$app_payload_dir/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

        log "Launching application [$app_id] (Direct execution)..."
        local app_exit_code=0
        "$real_exec" ${extra_app_flags[@]+"${extra_app_flags[@]}"} ${sanitized_args[@]+"${sanitized_args[@]}"} || app_exit_code=$?
        _cleanup_sandbox_instance
        trap - EXIT
        return "$app_exit_code"
    fi

    # Shared Runtime check
    local runtime_root=""
    if [[ -n "$req_runtime" ]]; then
        if runtime_root="$(resolve_shared_runtime "$req_runtime" "latest" "$req_abi")"; then
            info "Binding shared runtime: $req_runtime ($runtime_root)"
        else
            warn "Requested runtime '$req_runtime' not installed. Falling back to host base."
        fi
    fi

    local bwrap_args=(
        bwrap
        --die-with-parent
        --new-session
        --clearenv
        --cap-drop ALL
        --unshare-uts
        --unshare-pid
        --unshare-cgroup-try
        --chdir "$HOME"
        --proc /proc
        --dev /dev
        --dev-bind /dev/shm /dev/shm
        --ro-bind /sys /sys
        --tmpfs /tmp
        --tmpfs /run
        --tmpfs /var/tmp
    )

    if [[ -n "$runtime_root" && -d "$runtime_root/usr" ]]; then
        bwrap_args+=(--ro-bind "$runtime_root/usr" /usr)
        [[ -d "$runtime_root/lib" ]]   && bwrap_args+=(--ro-bind-try "$runtime_root/lib" /lib)
        [[ -d "$runtime_root/lib64" ]] && bwrap_args+=(--ro-bind-try "$runtime_root/lib64" /lib64)
        [[ -d "$runtime_root/bin" ]]   && bwrap_args+=(--ro-bind-try "$runtime_root/bin" /bin)
    else
        bwrap_args+=(--ro-bind /usr /usr)
        local dir target_link
        for dir in /lib /lib64 /lib32 /bin /sbin; do
            if [[ -L "$dir" ]]; then
                target_link="$(readlink "$dir" 2>/dev/null || true)"
                [[ -n "$target_link" ]] && bwrap_args+=(--symlink "$target_link" "$dir")
            elif [[ -d "$dir" ]]; then
                bwrap_args+=(--ro-bind "$dir" "$dir")
            fi
        done
    fi

    case "$home_mode" in
        isolated)       bwrap_args+=(--bind "$app_data_dir/home" "$HOME") ;;
        read|ro)        bwrap_args+=(--ro-bind "$HOME" "$HOME") ;;
        read-write|rw)  bwrap_args+=(--bind "$HOME" "$HOME") ;;
        *)              bwrap_args+=(--bind "$app_data_dir/home" "$HOME") ;;
    esac

    case "$dl_mode" in
        read-write|rw)  bwrap_args+=(--bind "$dl_host_dir" "$dl_host_dir") ;;
        read|ro)        bwrap_args+=(--ro-bind "$dl_host_dir" "$dl_host_dir") ;;
    esac

    local custom_fs_entries
    custom_fs_entries="$(jq -r '.permissions.filesystem.custom[]? | "\(.path)\t\(.mode)"' <<< "$effective_json" 2>/dev/null || true)"
    if [[ -n "$custom_fs_entries" ]]; then
        local c_path c_mode
        while IFS=$'\t' read -r c_path c_mode; do
            if [[ -n "$c_path" && -e "$c_path" ]] && _ulpm_valid_bind_dest "$c_path"; then
                local real_c
                real_c="$(realpath -e -- "$c_path" 2>/dev/null || true)"
                if [[ -n "$real_c" ]]; then
                    if [[ "$c_mode" == "ro" || "$c_mode" == "read" ]]; then
                        bwrap_args+=(--ro-bind "$real_c" "$c_path")
                    else
                        bwrap_args+=(--bind "$real_c" "$c_path")
                    fi
                fi
            fi
        done <<< "$custom_fs_entries"
    fi

    if [[ "$allow_gui" != "true" || -z "${DISPLAY:-}" ]]; then
        bwrap_args+=(--unshare-ipc)
    fi

    if [[ "$allow_net" != "true" ]]; then
        bwrap_args+=(--unshare-net)
    else
        bwrap_args+=(--share-net)
        local real_resolv
        real_resolv="$(realpath /etc/resolv.conf 2>/dev/null || echo "/etc/resolv.conf")"
        [[ -f "$real_resolv" ]] && bwrap_args+=(--ro-bind-try "$real_resolv" "$real_resolv")
        bwrap_args+=(
            --ro-bind-try /etc/resolv.conf /etc/resolv.conf
            --ro-bind-try /etc/hosts /etc/hosts
            --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
            --ro-bind-try /etc/gai.conf /etc/gai.conf
            --ro-bind-try /run/systemd/resolve /run/systemd/resolve
            --ro-bind-try /etc/ssl /etc/ssl
            --ro-bind-try /etc/pki /etc/pki
            --ro-bind-try /etc/ca-certificates /etc/ca-certificates
            --ro-bind-try /usr/share/ca-certificates /usr/share/ca-certificates
        )
    fi

    local etc_item
    for etc_item in alternatives ld.so.cache ld.so.conf ld.so.conf.d \
        fonts X11 xdg gtk-2.0 gtk-3.0 gtk-4.0 pulse vulkan glvnd \
        time timezone os-release machine-id passwd group; do
        bwrap_args+=(--ro-bind-try "/etc/$etc_item" "/etc/$etc_item")
    done

    if [[ "$dev_input" == "true" ]]; then
        bwrap_args+=(
            --dev-bind-try /dev/input /dev/input
            --dev-bind-try /dev/uinput /dev/uinput
        )
        local js
        for js in /dev/js[0-9]*; do
            [[ -e "$js" ]] && bwrap_args+=(--dev-bind-try "$js" "$js")
        done
    fi

    if [[ "$dev_hidraw" == "true" ]]; then
        shopt -s nullglob
        local hr
        for hr in /dev/hidraw*; do
            [[ -e "$hr" ]] && bwrap_args+=(--dev-bind-try "$hr" "$hr")
        done
        shopt -u nullglob
    fi

    [[ "$dev_usb" == "true" ]] && bwrap_args+=(--dev-bind-try /dev/bus/usb /dev/bus/usb)
    [[ "$dev_kvm" == "true" ]] && bwrap_args+=(--dev-bind-try /dev/kvm /dev/kvm)

    bwrap_args+=(
        --dev-bind-try /dev/fb0 /dev/fb0
        --ro-bind-try /run/udev /run/udev
        --ro-bind-try /usr/share/fonts /usr/share/fonts
        --ro-bind-try /usr/share/themes /usr/share/themes
        --ro-bind-try /usr/share/icons /usr/share/icons
        --perms 0700 --dir "$run_user_dir"
        --bind "$app_data_dir/config" "$HOME/.config"
        --bind "$app_data_dir/data" "$HOME/.local/share"
        --bind "$app_data_dir/cache" "$HOME/.cache"
        --ro-bind "$app_payload_dir" /app
    )

    if [[ "$allow_gpu" == "true" && "$dev_dri" == "true" ]]; then
        bwrap_args+=(
            --dev-bind-try /dev/dri /dev/dri
            --ro-bind-try /usr/share/vulkan /usr/share/vulkan
            --ro-bind-try /usr/share/glvnd /usr/share/glvnd
        )
        shopt -s nullglob
        local dev
        for dev in /dev/nvidia* /dev/nvidia-uvm* /dev/nvidia-modeset*; do
            [[ -e "$dev" ]] && bwrap_args+=(--dev-bind-try "$dev" "$dev")
        done
        shopt -u nullglob
    fi

    if [[ "$allow_audio" == "true" ]]; then
        bwrap_args+=(--dev-bind-try /dev/snd /dev/snd)
        local pulse_sock="$run_user_dir/pulse/native"
        if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
            pulse_sock="${BASH_REMATCH[1]}"
        fi
        bwrap_args+=(
            --bind-try "$pulse_sock" "$pulse_sock"
            --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
        )
    fi

    [[ -f "$HOME/.config/user-dirs.dirs" ]] && bwrap_args+=(--ro-bind-try "$HOME/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs")
    [[ -d "/recalbox/share" ]]              && bwrap_args+=(--bind-try /recalbox/share /recalbox/share)

    if [[ "$allow_gui" == "true" ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then
            local x_sock
            if [[ "$DISPLAY" =~ ^(unix)?:([0-9]+) ]]; then
                x_sock="/tmp/.X11-unix/X${BASH_REMATCH[2]}"
                bwrap_args+=(--ro-bind-try "$x_sock" "$x_sock")
            else
                bwrap_args+=(--ro-bind-try /tmp/.X11-unix /tmp/.X11-unix)
            fi
            local xauth_file="${XAUTHORITY:-$HOME/.Xauthority}"
            [[ -f "$xauth_file" ]] && bwrap_args+=(--ro-bind "$xauth_file" "$xauth_file")
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
    fi

    # D-Bus Filtering Proxy with Full Desktop Portals Baseline
    local session_bus
    if [[ "$allow_gui" == "true" ]] && session_bus="$(session_bus_socket "$run_user_dir")" && command -v xdg-dbus-proxy >/dev/null 2>&1; then
        dbus_proxy_dir="$(mktemp -d "$cache_dir/dbus_proxy_${instance_id}.XXXXXX")"
        local proxy_socket="$dbus_proxy_dir/bus"
        local proxy_args=(xdg-dbus-proxy "$session_bus" "$proxy_socket" --filter)

        case "$app_id" in
            org.freedesktop*|org.gnome*|org.kde*|org.mpris*|com.canonical*)
                warn "App id '$app_id' collides with system D-Bus namespace: automatic --own omitted."
                ;;
            *) proxy_args+=(--own="${app_id}.*") ;;
        esac

        local talk_rules own_rules rule
        talk_rules="$(jq -r '.permissions.dbus.session.talk[]?' <<< "$effective_json" 2>/dev/null || true)"
        if [[ -n "$talk_rules" ]]; then
            while IFS= read -r rule; do
                [[ -n "$rule" ]] && proxy_args+=(--talk="$rule")
            done <<< "$talk_rules"
        fi

        own_rules="$(jq -r '.permissions.dbus.session.own[]?' <<< "$effective_json" 2>/dev/null || true)"
        if [[ -n "$own_rules" ]]; then
            while IFS= read -r rule; do
                [[ -n "$rule" ]] && proxy_args+=(--own="$rule")
            done <<< "$own_rules"
        fi

        # Standard Freedesktop & XDG Portals baseline
        proxy_args+=(
            --own='org.mpris.MediaPlayer2.*'
            --talk=org.freedesktop.Notifications
            --talk=org.freedesktop.ScreenSaver
            --talk=org.freedesktop.PowerManagement.Inhibit
            --talk=org.freedesktop.portal.Desktop
            --talk=org.freedesktop.portal.Documents
            --talk=org.kde.StatusNotifierWatcher
        )

        if [[ -n "${ULPM_DBUS_EXTRA:-}" ]]; then
            # shellcheck disable=SC2206
            proxy_args+=($ULPM_DBUS_EXTRA)
        fi

        "${proxy_args[@]}" &
        dbus_pid=$!

        local proxy_wait=0
        while [[ ! -S "$proxy_socket" ]] && (( proxy_wait < 20)); do
            if ! kill -0 "$dbus_pid" 2>/dev/null; then
                break
            fi
            sleep 0.05
            proxy_wait=$((proxy_wait + 1))
        done

        if [[ -S "$proxy_socket" ]]; then
            bwrap_args+=(
                --bind "$proxy_socket" "$run_user_dir/bus"
                --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$run_user_dir/bus"
            )
        else
            warn "Failed to initialize filtered D-Bus proxy; proceeding without session bus."
            kill "$dbus_pid" 2>/dev/null || true
            wait "$dbus_pid" 2>/dev/null || true
            dbus_pid=""
        fi
    fi

    for b in "${custom_binds[@]}"; do
        local h_dir="${b%%:*}"
        local d_dir="${b#*:}"
        if [[ -e "$h_dir" ]]; then
            local real_custom_h
            real_custom_h="$(realpath -e -- "$h_dir" 2>/dev/null || true)"
            if [[ -n "$real_custom_h" ]] && _ulpm_valid_bind_dest "$d_dir"; then
                bwrap_args+=(--bind "$real_custom_h" "$d_dir")
            fi
        fi
    done

    for env_var in "${ENV_WHITELIST[@]}"; do
        if [[ "$allow_gui" != "true" ]] && [[ "$env_var" =~ (DISPLAY|WAYLAND) ]]; then
            continue
        fi
        if [[ -n "${!env_var:-}" ]]; then
            bwrap_args+=(--setenv "$env_var" "${!env_var}")
        fi
    done

    # Hardened Seccomp BPF injection
    local seccomp_bpf="${ULPM_SECCOMP_FILTER:-${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/seccomp/default.bpf}"
    local seccomp_fd_arg=()
    if [[ "$cli_profile" == "strict" ]] && [[ -f "$seccomp_bpf" && -r "$seccomp_bpf" ]]; then
        exec 9<"$seccomp_bpf"
        seccomp_fd_arg=(--seccomp 9)
    fi

    local sandbox_exec="/app/${real_exec#"$app_payload_dir/"}"

    local host_multiarch=""
    case "$(detect_arch)" in
        amd64)     host_multiarch="/usr/lib/x86_64-linux-gnu" ;;
        arm64)     host_multiarch="/usr/lib/aarch64-linux-gnu" ;;
        armhf)     host_multiarch="/usr/lib/arm-linux-gnueabihf" ;;
        i386)      host_multiarch="/usr/lib/i386-linux-gnu" ;;
        riscv64)   host_multiarch="/usr/lib/riscv64-linux-gnu" ;;
    esac

    local ld_paths="/app/lib:/app/usr/lib:/app/lib64:/app/usr/lib64"
    [[ -n "$host_multiarch" ]] && ld_paths="${ld_paths}:${host_multiarch}"
    ld_paths="${ld_paths}:/usr/lib64:/usr/lib"

    bwrap_args+=(
        --setenv PATH "/app/bin:/app/usr/bin:/app:/usr/bin:/bin"
        --setenv LD_LIBRARY_PATH "$ld_paths"
        --setenv XDG_CONFIG_HOME "$HOME/.config"
        --setenv XDG_DATA_HOME "$HOME/.local/share"
        --setenv XDG_CACHE_HOME "$HOME/.cache"
        --setenv XDG_DATA_DIRS "/app/share:/app/usr/share:/usr/share:/usr/local/share"
    )

    log "Launching application [$app_id] via Bubblewrap sandbox (Instance: $instance_id)..."
    local app_exit_code=0
    if (( ${#seccomp_fd_arg[@]} > 0 )); then
        "${bwrap_args[@]}" "${seccomp_fd_arg[@]}" "$sandbox_exec" ${extra_app_flags[@]+"${extra_app_flags[@]}"} ${sanitized_args[@]+"${sanitized_args[@]}"} || app_exit_code=$?
        exec 9<&- 2>/dev/null || true
    else
        "${bwrap_args[@]}" "$sandbox_exec" ${extra_app_flags[@]+"${extra_app_flags[@]}"} ${sanitized_args[@]+"${sanitized_args[@]}"} || app_exit_code=$?
    fi

    _cleanup_sandbox_instance
    trap - EXIT
    return "$app_exit_code"
}
