#!/usr/bin/env bash
# ==============================================================================
# lib/sandbox.sh - Concurrent-Safe Production Sandboxing Engine (App & RootFS)
# ULPM v5.0.0 Declarative Architecture (Manifest v5 & Profiles Support)
# ==============================================================================

# Whitelist of environment variables forwarded into the sandbox
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
    # Recalbox/ Gaming specific variables
    RECALBOX_SYSTEM_DIR CONTROLLER_CONFIG SDL_JOYSTICK_DEVICE
)

# ------------------------------------------------------------------------------
# Universal Host Downloads Discovery & Linking (Multi-Language Aware)
# ------------------------------------------------------------------------------

resolve_host_downloads_dir() {
    local candidate=""

    if command -v xdg-user-dir &>/dev/null; then
        candidate="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    fi

    if [[ -z "$candidate" || "$candidate" == "$HOME" ]] && [[ -f "$HOME/.config/user-dirs.dirs" ]]; then
        local raw
        raw="$(grep -E '^XDG_DOWNLOAD_DIR=' "$HOME/.config/user-dirs.dirs" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        raw="${raw/#\$HOME/$HOME}"
        [[ -n "$raw" && -d "$raw" ]] && candidate="$raw"
    fi

    if [[ -z "$candidate" || "$candidate" == "$HOME" ]]; then
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
# Security & Cryptographic Validation
# ------------------------------------------------------------------------------

_ulpm_check_signature() {
    local pkg_path="$1" rc=0
    if declare -F verify_package >/dev/null 2>&1; then
        verify_package "$pkg_path" || rc=$?
    elif declare -F enforce_package_trust >/dev/null 2>&1; then
        enforce_package_trust "$pkg_path" || rc=$?
    else
        return 0
    fi

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

    if [[ -d "$mount_dir/root/etc" && -d "$mount_dir/root/usr" && -d "$mount_dir/root/bin" ]] || \
       [[ -d "$mount_dir/etc" && -d "$mount_dir/usr" && -d "$mount_dir/bin" ]]; then
        return 0
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
        eval "cbinds=(\"\${${custom_binds_ref}[@]}\")"
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
        --tmpfs /home
        --dir "$HOME"
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

    # Network routing
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

    # Hardware & Gamepad bindings
    if [[ "$disable_input" != "true" ]]; then
        bwrap_args+=(
            --dev-bind-try /dev/input /dev/input
            --dev-bind-try /dev/uinput /dev/uinput
        )
        for js in /dev/js[0-9]*; do
            [[ -e "$js" ]] && bwrap_args+=(--dev-bind-try "$js" "$js")
        done
    fi
    bwrap_args+=(
        --dev-bind-try /dev/fb0 /dev/fb0
        --ro-bind-try /run/udev /run/udev
    )

    # GPU
    if [[ "$disable_gpu" != "true" ]]; then
        bwrap_args+=(--dev-bind-try /dev/dri /dev/dri)
        shopt -s nullglob
        for dev in /dev/nvidia*; do
            [[ -e "$dev" ]] && bwrap_args+=(--dev-bind-try "$dev" "$dev")
        done
        shopt -u nullglob
    fi

    # Audio
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

    # Recalbox persistence
    if [[ -d "/recalbox/share" ]]; then
        bwrap_args+=(
            --bind-try /recalbox/share /recalbox/share
            --bind-try /recalbox/share/roms /recalbox/share/roms
            --bind-try /recalbox/share/saves /recalbox/share/saves
            --bind-try /recalbox/share/bios /recalbox/share/bios
            --bind-try /recalbox/share/system /recalbox/share/system
        )
    fi

    # GUI (X11 & Wayland)
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

    # Custom Host-Directory Bindings (--bind host:dest)
    for b in "${cbinds[@]}"; do
        local h_dir="${b%%:*}"
        local d_dir="${b#*:}"
        if [[ -e "$h_dir" ]]; then
            if _ulpm_valid_bind_dest "$d_dir"; then
                bwrap_args+=(--bind "$h_dir" "$d_dir")
            else
                warn "Skipping unsafe bind destination: $d_dir"
            fi
        else
            warn "Host bind source does not exist: $h_dir"
        fi
    done

    for env_var in "${ENV_WHITELIST[@]}"; do
        if [[ "$disable_gui" == "true" ]] && [[ "$env_var" =~ (DISPLAY|WAYLAND) ]]; then
            continue
        fi
        if [[ -n "${!env_var:-}" ]]; then
            bwrap_args+=(--setenv "$env_var" "${!env_var}")
        fi
    done

    # Deterministic entrypoint resolution
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
    for arg in "$@"; do
        case "$arg" in
            ""|"%u"|"%U"|"%f"|"%F") ;;
            *) sanitized_args+=("$arg") ;;
        esac
    done

    log "Starting RootFS session [$app_id] (Entrypoint: $entrypoint)..."
    "${bwrap_args[@]}" "$entrypoint" ${sanitized_args[@]+"${sanitized_args[@]}"}
}

# ------------------------------------------------------------------------------
# App Mode Execution (Shared Host Base + Isolated Sandbox)
# ------------------------------------------------------------------------------

lpk_run_isolated() {
    # Sandbox Runtime Overrides / Flags
    local cli_force_offline=false
    local cli_no_gpu=false
    local cli_no_audio=false
    local cli_no_gui=false
    local cli_no_input=false
    local cli_profile=""
    local custom_binds=()

    # Parse Sandbox Runtime Flags & Profiles
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
    elif [[ -f "$ULPM_APPS_DIR/$target.lpk" ]]; then
        pkg_path="$ULPM_APPS_DIR/$target.lpk"
    elif [[ -f "$ULPM_APPS_DIR/$target/$target.lpk" ]]; then
        pkg_path="$ULPM_APPS_DIR/$target/$target.lpk"
    elif [[ -f "$ULPM_APPS_DIR/io.lpk.${target,,}.lpk" ]]; then
        pkg_path="$ULPM_APPS_DIR/io.lpk.${target,,}.lpk"
    else
        error "Target package '$target' could not be resolved"
        return 1
    fi

    # Cryptographic signature validation
    _ulpm_check_signature "$pkg_path" || return 1

    local instance_id="$$_${RANDOM}"
    local mnt_dir dbus_proxy_dir="" dbus_pid=""
    mnt_dir="$(mktemp -d "${ULPM_CACHE_HOME}/mnt_${instance_id}.XXXXXX")"

    # Encapsulated instance cleanup with trap restoration
    local cleanup_done=0
    _cleanup_sandbox_instance() {
        (( cleanup_done )) && return 0
        cleanup_done=1
        if [[ -n "${dbus_pid:-}" ]] && kill -0 "$dbus_pid" 2>/dev/null; then
            kill "$dbus_pid" 2>/dev/null || true
            wait "$dbus_pid" 2>/dev/null || true
        fi
        [[ -n "${dbus_proxy_dir:-}" && -d "${dbus_proxy_dir:-}" ]] && rm -rf "$dbus_proxy_dir"
        safe_unmount "$mnt_dir"
        rm -rf "$mnt_dir"

        eval "$old_int" 2>/dev/null || trap - INT
        eval "$old_term" 2>/dev/null || trap - TERM
        eval "$old_hup" 2>/dev/null || trap - HUP
    }

    local old_int old_term old_hup
    old_int="$(trap -p INT || true)"
    old_term="$(trap -p TERM || true)"
    old_hup="$(trap -p HUP || true)"

    trap '_cleanup_sandbox_instance; exit 130' INT
    trap '_cleanup_sandbox_instance; exit 143' TERM
    trap '_cleanup_sandbox_instance; exit 129' HUP

    if ! squashfuse "$pkg_path" "$mnt_dir" 2>/dev/null; then
        error "Failed to mount SquashFS image ($pkg_path)"
        _cleanup_sandbox_instance
        return 1
    fi

    local manifest_file="$mnt_dir/meta/manifest.json"
    [[ ! -f "$manifest_file" ]] && manifest_file="$mnt_dir/lpk.json"

    local app_id
    app_id="app_$(basename -- "$target" .lpk)"

    # Identify preliminary ID to resolve user overrides
    if [[ -f "$manifest_file" ]]; then
        local raw_id
        raw_id=$(jq -r '.id // .name // empty' "$manifest_file" 2>/dev/null || true)
        if [[ -n "$raw_id" ]]; then
            if ! is_safe_app_id "$raw_id"; then
                error "Refusing to run: unsafe application id in manifest: '$raw_id'"
                _cleanup_sandbox_instance
                return 1
            fi
            app_id="$raw_id"
        fi
    fi

    # ROOTFS ROUTING CHECK
    if lpk_is_rootfs "$mnt_dir" "$manifest_file"; then
        local exec_bin="bin/main"
        [[ -f "$manifest_file" ]] && exec_bin="$(jq -r '.exec // "bin/main"' "$manifest_file" 2>/dev/null || echo "bin/main")"
        local rootfs_rc=0
        lpk_run_rootfs "$mnt_dir" "$app_id" "$exec_bin" "$cli_force_offline" "true" \
            "$cli_no_gpu" "$cli_no_audio" "$cli_no_gui" "$cli_no_input" custom_binds "$@" || rootfs_rc=$?
        _cleanup_sandbox_instance
        return "$rootfs_rc"
    fi

    # -------------------------------------------------------------------------
    # Manifest v5 Resolution & User Overrides Merge
    # -------------------------------------------------------------------------
    local effective_json="{}"
    if declare -F manifest_resolve_effective >/dev/null 2>&1; then
        effective_json="$(manifest_resolve_effective "$manifest_file" "$app_id")"
    elif [[ -f "$manifest_file" ]]; then
        effective_json="$(cat "$manifest_file")"
    fi

    local exec_bin is_chromium allow_net allow_gpu allow_audio allow_gui
    local dev_dri dev_input dev_hidraw dev_usb dev_kvm home_mode dl_mode

    exec_bin="$(manifest_get "$effective_json" '.exec' "bin/main")"
    is_chromium="$(manifest_get "$effective_json" '.chromium' "false")"

    # Meta-permissions (Backward compatible with v4 root-level flags)
    allow_net="$(jq -r 'if has("permissions") then (.permissions.network // false) else (if has("network") then .network else true end) end' <<< "$effective_json")"
    allow_gpu="$(jq -r 'if has("permissions") then (.permissions.gpu // true) else true end' <<< "$effective_json")"
    allow_audio="$(jq -r 'if has("permissions") then (.permissions.audio // true) else true end' <<< "$effective_json")"
    allow_gui="$(jq -r 'if has("permissions") then (.permissions.gui // true) else true end' <<< "$effective_json")"

    # Filesystem policy
    home_mode="$(manifest_get "$effective_json" '.permissions.filesystem.home' "isolated")"
    dl_mode="$(manifest_get "$effective_json" '.permissions.filesystem.downloads' "read-write")"

    # Devices
    dev_dri="$(jq -r '.permissions.devices.dri // true' <<< "$effective_json")"
    dev_input="$(jq -r '.permissions.devices.input // true' <<< "$effective_json")"
    dev_hidraw="$(jq -r '.permissions.devices.hidraw // false' <<< "$effective_json")"
    dev_usb="$(jq -r '.permissions.devices.usb // false' <<< "$effective_json")"
    dev_kvm="$(jq -r '.permissions.devices.kvm // false' <<< "$effective_json")"

    # Apply Built-in Execution Profiles
    case "$cli_profile" in
        gaming)
            allow_gpu=true
            allow_audio=true
            dev_dri=true
            dev_input=true
            dev_hidraw=true
            dev_usb=true
            ;;
        strict)
            allow_net=false
            allow_gpu=false
            dev_dri=false
            home_mode="isolated"
            dl_mode="none"
            ;;
        desktop)
            allow_gpu=true
            allow_audio=true
            allow_gui=true
            ;;
    esac

    # Runtime CLI flags take ultimate precedence
    [[ "$cli_force_offline" == "true" ]] && allow_net=false
    [[ "$cli_no_gpu" == "true" ]]        && { allow_gpu=false; dev_dri=false; }
    [[ "$cli_no_audio" == "true" ]]      && allow_audio=false
    [[ "$cli_no_gui" == "true" ]]        && allow_gui=false
    [[ "$cli_no_input" == "true" ]]      && dev_input=false

    # STANDARD APP SANDBOX SETUP
    local app_data_dir="$HOME/.var/app/$app_id"
    mkdir -p "$app_data_dir/home" "$app_data_dir/config" "$app_data_dir/data" "$app_data_dir/cache"

    local run_uid run_user_dir dl_host_dir
    run_uid="$(id -u)"
    run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"

    dl_host_dir="$(resolve_host_downloads_dir)"
    setup_sandbox_downloads_links "$app_data_dir/home" "$dl_host_dir"

    local clean_exec="${exec_bin#/}"
    local app_payload_dir="$mnt_dir"
    [[ -d "$mnt_dir/root" ]] && app_payload_dir="$mnt_dir/root"

    # Chromium / Electron specific flags (Strict structure-based detection)
    local extra_app_flags=()
    local is_electron_app=false

    if [[ "$is_chromium" == "true" ]]; then
        is_electron_app=true
    elif [[ -f "$app_payload_dir/resources/app.asar" ]] || [[ -f "$app_payload_dir/electron" ]] || [[ -f "$app_payload_dir/chrome_crashpad_handler" ]]; then
        is_electron_app=true
    elif [[ "$(basename -- "$clean_exec")" =~ ^(chrome|chromium|brave|edge)$ ]]; then
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
        --ro-bind /usr /usr
        --proc /proc
        --dev /dev
        --dev-bind /dev/shm /dev/shm
        --ro-bind /sys /sys
        --tmpfs /tmp
        --tmpfs /run
        --tmpfs /var/tmp
    )

    # Multiarch library symlinks support
    for dir in /lib /lib64 /lib32 /bin /sbin; do
        [[ -d "$dir" ]] && bwrap_args+=(--ro-bind "$dir" "$dir")
    done

    # Filesystem: $HOME strategy
    case "$home_mode" in
        isolated)
            bwrap_args+=(--bind "$app_data_dir/home" "$HOME")
            ;;
        read|ro)
            bwrap_args+=(--ro-bind "$HOME" "$HOME")
            ;;
        read-write|rw)
            bwrap_args+=(--bind "$HOME" "$HOME")
            ;;
        *)
            bwrap_args+=(--bind "$app_data_dir/home" "$HOME")
            ;;
    esac

    # Filesystem: Downloads folder
    case "$dl_mode" in
        read-write|rw)
            bwrap_args+=(--bind "$dl_host_dir" "$dl_host_dir")
            ;;
        read|ro)
            bwrap_args+=(--ro-bind "$dl_host_dir" "$dl_host_dir")
            ;;
    esac

    # Filesystem: Custom paths defined in Manifest v5
    while IFS=$'\t' read -r c_path c_mode; do
        if [[ -n "$c_path" && -e "$c_path" ]] && _ulpm_valid_bind_dest "$c_path"; then
            if [[ "$c_mode" == "ro" || "$c_mode" == "read" ]]; then
                bwrap_args+=(--ro-bind "$c_path" "$c_path")
            else
                bwrap_args+=(--bind "$c_path" "$c_path")
            fi
        fi
    done < <(jq -r '.permissions.filesystem.custom[]? | "\(.path)\t\(.mode)"' <<< "$effective_json" 2>/dev/null || true)

    if [[ "$allow_gui" != "true" || -z "${DISPLAY:-}" ]]; then
        bwrap_args+=(--unshare-ipc)
    fi

    # Network & Certificates
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

    # System configurations & themes
    local etc_item
    for etc_item in alternatives ld.so.cache ld.so.conf ld.so.conf.d \
        fonts X11 xdg gtk-2.0 gtk-3.0 gtk-4.0 pulse vulkan glvnd \
        localtime timezone os-release machine-id passwd group; do
        bwrap_args+=(--ro-bind-try "/etc/$etc_item" "/etc/$etc_item")
    done

    # Input & Gamepads
    if [[ "$dev_input" == "true" ]]; then
        bwrap_args+=(
            --dev-bind-try /dev/input /dev/input
            --dev-bind-try /dev/uinput /dev/uinput
        )
        for js in /dev/js[0-9]*; do
            [[ -e "$js" ]] && bwrap_args+=(--dev-bind-try "$js" "$js")
        done
    fi

    # Raw HID & Steering wheels / Pro controllers
    if [[ "$dev_hidraw" == "true" ]]; then
        shopt -s nullglob
        for hr in /dev/hidraw*; do
            [[ -e "$hr" ]] && bwrap_args+=(--dev-bind-try "$hr" "$hr")
        done
        shopt -u nullglob
    fi

    # Direct USB controller access
    if [[ "$dev_usb" == "true" ]]; then
        bwrap_args+=(--dev-bind-try /dev/bus/usb /dev/bus/usb)
    fi

    # Hardware KVM Passthrough
    if [[ "$dev_kvm" == "true" ]]; then
        bwrap_args+=(--dev-bind-try /dev/kvm /dev/kvm)
    fi

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

    # GPU & 3D Acceleration
    if [[ "$allow_gpu" == "true" && "$dev_dri" == "true" ]]; then
        bwrap_args+=(
            --dev-bind-try /dev/dri /dev/dri
            --ro-bind-try /usr/share/vulkan /usr/share/vulkan
            --ro-bind-try /usr/share/glvnd /usr/share/glvnd
        )
        shopt -s nullglob
        for dev in /dev/nvidia*; do
            [[ -e "$dev" ]] && bwrap_args+=(--dev-bind-try "$dev" "$dev")
        done
        shopt -u nullglob
    fi

    # Audio
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
    [[ -d "/recalbox/share" ]] && bwrap_args+=(--bind-try /recalbox/share /recalbox/share)

    # GUI (X11 & Wayland)
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

    # D-Bus Isolation Proxy
    if [[ "$allow_gui" == "true" ]]; then
        if command -v xdg-dbus-proxy &>/dev/null; then
            local real_sock
            if real_sock=$(session_bus_socket "$run_user_dir"); then
                dbus_proxy_dir="$(mktemp -d "$run_user_dir/ulpm_dbus_${instance_id}.XXXXXX" 2>/dev/null || true)"
                if [[ -n "$dbus_proxy_dir" && -d "$dbus_proxy_dir" ]]; then
                    local -a dbus_filter_args=()

                    # System namespace collision guard
                    case "$app_id" in
                        org.freedesktop*|org.gnome*|org.kde*|org.mpris*|com.canonical*)
                            warn "App id '$app_id' collides with system D-Bus namespace: automatic --own omitted."
                            ;;
                        *) dbus_filter_args+=(--own="${app_id}.*") ;;
                    esac

                    # Declarative session talk rules from manifest v5
                    while IFS= read -r rule; do
                        [[ -n "$rule" ]] && dbus_filter_args+=(--talk="$rule")
                    done < <(jq -r '.permissions.dbus.session.talk[]?' <<< "$effective_json" 2>/dev/null || true)

                    # Declarative session own rules from manifest v5
                    while IFS= read -r rule; do
                        [[ -n "$rule" ]] && dbus_filter_args+=(--own="$rule")
                    done < <(jq -r '.permissions.dbus.session.own[]?' <<< "$effective_json" 2>/dev/null || true)

                    # Standard Freedesktop & XDG Portals baseline
                    dbus_filter_args+=(
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
                        dbus_filter_args+=($ULPM_DBUS_EXTRA)
                    fi

                    xdg-dbus-proxy "unix:path=$real_sock" "$dbus_proxy_dir/bus" --filter \
                        "${dbus_filter_args[@]}" &
                    dbus_pid=$!

                    for _ in {1..30}; do
                        [[ -S "$dbus_proxy_dir/bus" ]] && break
                        kill -0 "$dbus_pid" 2>/dev/null || break
                        sleep 0.05
                    done

                    if [[ -S "$dbus_proxy_dir/bus" ]]; then
                        bwrap_args+=(--bind "$dbus_proxy_dir/bus" "$run_user_dir/bus")
                    fi
                fi
            fi
        else
            warn "xdg-dbus-proxy not installed. Sandboxed app won't have session D-Bus access."
        fi
    fi

    # Custom Host-Directory Bindings (--bind host:dest)
    for b in "${custom_binds[@]}"; do
        local h_dir="${b%%:*}"
        local d_dir="${b#*:}"
        if [[ -e "$h_dir" ]]; then
            if _ulpm_valid_bind_dest "$d_dir"; then
                bwrap_args+=(--bind "$h_dir" "$d_dir")
            else
                warn "Skipping unsafe bind destination: $d_dir"
            fi
        else
            warn "Host bind source does not exist: $h_dir"
        fi
    done

    for env_var in "${ENV_WHITELIST[@]}"; do
        if [[ "$disable_gui" == "true" ]] && [[ "$env_var" =~ (DISPLAY|WAYLAND) ]]; then
            continue
        fi
        if [[ -n "${!env_var:-}" ]]; then
            bwrap_args+=(--setenv "$env_var" "${!env_var}")
        fi
    done

    # Deterministic entrypoint resolution
    local real_exec="/app/$clean_exec"
    if [[ ! -x "$app_payload_dir/$clean_exec" ]]; then
        for cand in /app/AppRun /app/bin/main /app/main; do
            if [[ -x "$app_payload_dir/${cand#/app/}" ]]; then
                real_exec="$cand"
                break
            fi
        done
    fi

    # Multiarch Host Libraries Support
    local host_multiarch
    case "$(detect_arch)" in
        amd64)   host_multiarch="/usr/lib/x86_64-linux-gnu" ;;
        arm64)   host_multiarch="/usr/lib/aarch64-linux-gnu" ;;
        armhf)   host_multiarch="/usr/lib/arm-linux-gnueabihf" ;;
        i386)    host_multiarch="/usr/lib/i386-linux-gnu" ;;
        riscv64) host_multiarch="/usr/lib/riscv64-linux-gnu" ;;
        *)       host_multiarch="" ;;
    esac

    local ld_paths="/app/lib:/app/usr/lib:/app/lib64:/app/usr/lib64"
    [[ -n "$host_multiarch" ]] && ld_paths="${ld_paths}:${host_multiarch}"
    ld_paths="${ld_paths}:/usr/lib64:/usr/lib"

    bwrap_args+=(
        --setenv PATH "/app/bin:/app/usr/bin:/app:$PATH"
        --setenv LD_LIBRARY_PATH "$ld_paths"
        --setenv XDG_CONFIG_HOME "$HOME/.config"
        --setenv XDG_DATA_HOME "$HOME/.local/share"
        --setenv XDG_CACHE_HOME "$HOME/.cache"
        --setenv XDG_DATA_DIRS "/app/share:/app/usr/share:/usr/share:/usr/local/share"
    )

    # Sanitize CLI arguments
    local sanitized_args=()
    for arg in "$@"; do
        case "$arg" in
            ""|"%u"|"%U"|"%f"|"%F") ;;
            *) sanitized_args+=("$arg") ;;
        esac
    done

    # Prevent Firefox from opening raw sandboxed directory if launched empty
    if [[ "$app_id" =~ (firefox|Firefox) ]] || [[ "$clean_exec" =~ firefox ]]; then
        if [ ${#sanitized_args[@]} -eq 0 ]; then
            sanitized_args=("about:home")
        fi
    fi

    log "Launching application [$app_id] via Bubblewrap sandbox (Instance: $instance_id)..."
    local app_exit_code=0
    "${bwrap_args[@]}" "$real_exec" ${extra_app_flags[@]+"${extra_app_flags[@]}"} ${sanitized_args[@]+"${sanitized_args[@]}"} || app_exit_code=$?

    _cleanup_sandbox_instance
    return "$app_exit_code"
}
