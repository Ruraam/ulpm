#!/usr/bin/env bash
# ==============================================================================
# lib/sandbox.sh - ULPM Hardened Bubblewrap Sandbox Runtime
# Public entry points: lpk_is_rootfs, lpk_run_rootfs, lpk_run_isolated.
# ULPM v4.1.0 (with Recalbox & Universal Downloads integrations)
# ==============================================================================

: "${ULPM_SANDBOX_RUNTIME_DIR:=${XDG_RUNTIME_DIR:-/tmp}/ulpm-${UID:-$(id -u)}}"
: "${ULPM_SANDBOX_DOWNLOADS_LINKS:=1}"

ENV_WHITELIST=(
    HOME USER LOGNAME SHELL LANG LANGUAGE TERM COLORTERM DISPLAY WAYLAND_DISPLAY
    XAUTHORITY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_DESKTOP_DIR
    XDG_DOCUMENTS_DIR XDG_DOWNLOAD_DIR XDG_MUSIC_DIR XDG_PICTURES_DIR XDG_PUBLICSHARE_DIR
    XDG_TEMPLATES_DIR XDG_VIDEOS_DIR DBUS_SESSION_BUS_ADDRESS PULSE_SERVER
    PIPEWIRE_REMOTE QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME GTK_THEME GDK_BACKEND
    SDL_VIDEODRIVER MOZ_ENABLE_WAYLAND LIBGL_ALWAYS_SOFTWARE __GLX_VENDOR_LIBRARY_NAME
    # Recalbox / Gaming specific variables
    RECALBOX_SYSTEM_DIR CONTROLLER_CONFIG SDL_JOYSTICK_DEVICE
)

_ulpm_log() {
    local level="$1"; shift
    if declare -F "$level" >/dev/null 2>&1; then
        "$level" "$@"
    else
        printf '[ULPM:%s] %s\n' "$level" "$*" >&2
    fi
}

_ulpm_have() { command -v "$1" >/dev/null 2>&1; }

_ulpm_abs_path() {
    local path="$1"
    if _ulpm_have realpath; then
        realpath -m -- "$path" 2>/dev/null || printf '%s\n' "$path"
    else
        printf '%s\n' "$path"
    fi
}

# ------------------------------------------------------------------------------
# Universal Host Downloads Discovery & Linking (Multi-Language)
# ------------------------------------------------------------------------------

resolve_host_downloads_dir() {
    local candidate=""

    # 1. Use xdg-user-dir if available
    if _ulpm_have xdg-user-dir; then
        candidate="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    fi

    # 2. Read standard XDG config file if not resolved
    if [[ -z "$candidate" || "$candidate" == "$HOME" ]] && [[ -f "$HOME/.config/user-dirs.dirs" ]]; then
        local raw
        raw="$(grep -E '^XDG_DOWNLOAD_DIR=' "$HOME/.config/user-dirs.dirs" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        raw="${raw/#\$HOME/$HOME}"
        [[ -n "$raw" && -d "$raw" ]] && candidate="$raw"
    fi

    # 3. Fallback detection of real multilingual directories
    if [[ -z "$candidate" || "$candidate" == "$HOME" ]]; then
        for name in "Téléchargements" "Downloads" "Descargas" "Download" "Scaricati"; do
            if [[ -d "$HOME/$name" ]]; then
                candidate="$HOME/$name"
                break
            fi
        done
    fi

    # 4. Ultimate fallback
    if [[ -z "$candidate" || "$candidate" == "$HOME" ]]; then
        candidate="$HOME/Downloads"
        mkdir -p -- "$candidate" 2>/dev/null || candidate="$HOME"
    fi

    printf '%s\n' "$candidate"
}

setup_sandbox_downloads_links() {
    local target_home="$1"
    local host_dl="$2"
    local dl_basename
    dl_basename="$(basename "$host_dl")"

    mkdir -p -- "$target_home/$dl_basename" 2>/dev/null || true

    # Make cross-compatibility links inside the isolated HOME
    if [[ "$dl_basename" != "Downloads" ]]; then
        ln -snf "$dl_basename" "$target_home/Downloads" 2>/dev/null || true
    fi
    if [[ "$dl_basename" != "Téléchargements" ]]; then
        ln -snf "$dl_basename" "$target_home/Téléchargements" 2>/dev/null || true
    fi
}

session_bus_socket() {
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        case "$DBUS_SESSION_BUS_ADDRESS" in
            unix:path=*)
                printf '%s\n' "${DBUS_SESSION_BUS_ADDRESS#unix:path=}" | cut -d, -f1
                return 0
                ;;
            unix:abstract=*)
                return 1
                ;;
        esac
    fi
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
        printf '%s\n' "$XDG_RUNTIME_DIR/bus"
        return 0
    fi
    return 1
}

lpk_is_rootfs() {
    local path="${1:-}"
    [[ -n "$path" && -d "$path" ]] || return 1
    [[ -x "$path/bin/sh" || -x "$path/usr/bin/env" || -x "$path/usr/bin/sh" ]] || return 1
    [[ -d "$path/etc" && ( -d "$path/usr" || -d "$path/bin" ) ]]
}

_ulpm_check_bwrap() {
    if ! _ulpm_have bwrap; then
        _ulpm_log error "bubblewrap (bwrap) is required to run isolated packages."
        return 127
    fi
    return 0
}

_ulpm_check_signature() {
    local pkg_path="$1" rc=0
    if ! declare -F verify_package >/dev/null 2>&1; then
        _ulpm_log error "Signature verifier unavailable; refusing to execute package."
        return 1
    fi

    verify_package "$pkg_path" || rc=$?
    case "$rc" in
        0)
            return 0
            ;;
        3)
            if [[ "${ULPM_STRICT_SIGNATURES:-0}" != 1 ]]; then
                _ulpm_log warn "Package signature is untrusted; running in compatibility mode."
                return 0
            fi
            _ulpm_log error "Untrusted package signature; rejected by strict mode."
            return 1
            ;;
        2)
            if [[ "${ULPM_ALLOW_UNSIGNED:-0}" == 1 && "${ULPM_STRICT_SIGNATURES:-0}" != 1 ]]; then
                _ulpm_log warn "Executing unsigned package (ULPM_ALLOW_UNSIGNED=1)."
                return 0
            fi
            _ulpm_log error "Package is unsigned; execution refused."
            return 1
            ;;
        *)
            _ulpm_log error "Invalid or corrupted package signature."
            return 1
            ;;
    esac
}

_ulpm_valid_bind_dest() {
    local dest="$1"
    [[ "$dest" == /* && "$dest" != / ]] || return 1
    case "$dest" in
        /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*)
            return 1
            ;;
    esac
    [[ "$dest" != *$'\n'* && "$dest" != *$'\r'* ]] || return 1
    [[ ! "/$dest/" =~ /\.\.?/ ]] || return 1
    return 0
}

_ulpm_parse_bind() {
    local spec="$1"; local -n host_out="$2"; local -n dest_out="$3"
    [[ "$spec" == *:* ]] || { _ulpm_log error "Invalid bind syntax '$spec' (expected HOST:DEST)."; return 2; }
    host_out="${spec%%:*}"
    dest_out="${spec#*:}"
    [[ -n "$host_out" && -e "$host_out" ]] || { _ulpm_log error "Bind source does not exist: $host_out"; return 2; }
    _ulpm_valid_bind_dest "$dest_out" || { _ulpm_log error "Unsafe bind destination: $dest_out"; return 2; }
}

_ulpm_collect_env() {
    local -n out="$1"; local name
    out=()
    for name in "${ENV_WHITELIST[@]}"; do
        [[ -v "$name" ]] && out+=(--setenv "$name" "${!name}")
    done
    if [[ -n "${ULPM_PRESERVE_LD_LIBRARY_PATH:-}" && -n "${LD_LIBRARY_PATH:-}" ]]; then
        out+=(--setenv LD_LIBRARY_PATH "$LD_LIBRARY_PATH")
    fi
}

_ulpm_add_gui_mounts() {
    # shellcheck disable=SC2178
    local -n target_args="$1"
    local allow_gui="${2:-1}"
    local allow_audio="${3:-1}"

    if (( allow_gui )); then
        if [[ -n "${DISPLAY:-}" && -d /tmp/.X11-unix ]]; then
            target_args+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
            [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]] && target_args+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY")
        fi
        if [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
            local wayland_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
            [[ -S "$wayland_socket" ]] && target_args+=(--bind "$wayland_socket" "$wayland_socket")
        fi
    fi

    if (( allow_audio )); then
        if [[ -z "${PULSE_SERVER:-}" && -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/pulse/native" ]]; then
            target_args+=(--bind "$XDG_RUNTIME_DIR/pulse/native" "$XDG_RUNTIME_DIR/pulse/native")
        fi
        if [[ -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/pipewire-0" ]]; then
            target_args+=(--bind "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0")
        fi
    fi
}

_ulpm_add_dbus() {
    # shellcheck disable=SC2178
    local -n target_args="$1"
    local bus
    if bus="$(session_bus_socket 2>/dev/null)" && [[ -S "$bus" ]]; then
        if _ulpm_have xdg-dbus-proxy && [[ "${ULPM_DISABLE_DBUS_PROXY:-0}" != 1 ]]; then
            local proxy_dir="${ULPM_SANDBOX_RUNTIME_DIR}/dbus-$$"
            mkdir -p -- "$proxy_dir" || return 0
            chmod 700 -- "$proxy_dir" 2>/dev/null || true
            local proxy_socket="$proxy_dir/session-bus"
            local -a extra=()
            if [[ -n "${ULPM_DBUS_EXTRA:-}" ]]; then
                read -r -a extra <<< "$ULPM_DBUS_EXTRA"
            fi
            xdg-dbus-proxy "$bus" "$proxy_socket" --filter --talk=org.freedesktop.DBus --see=org.freedesktop.DBus "${extra[@]}" >/dev/null 2>&1 &
            ULPM_DBUS_PROXY_PID=$!
            ULPM_DBUS_PROXY_DIR="$proxy_dir"
            local attempt
            # shellcheck disable=SC2034
            for attempt in {1..40}; do
                [[ -S "$proxy_socket" ]] && break
                kill -0 "$ULPM_DBUS_PROXY_PID" >/dev/null 2>&1 || break
                sleep 0.05
            done
            if [[ -S "$proxy_socket" ]]; then
                target_args+=(--bind "$proxy_socket" "$bus" --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$bus")
            else
                kill "$ULPM_DBUS_PROXY_PID" >/dev/null 2>&1 || true
                wait "$ULPM_DBUS_PROXY_PID" >/dev/null 2>&1 || true
                unset ULPM_DBUS_PROXY_PID ULPM_DBUS_PROXY_DIR
                rm -rf -- "$proxy_dir"
                _ulpm_log warn "D-Bus proxy failed to start; D-Bus disabled."
            fi
        else
            target_args+=(--ro-bind "$bus" "$bus" --setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$bus")
        fi
    fi
}

_ulpm_add_common_mounts() {
    # shellcheck disable=SC2178
    local -n target_args="$1"
    local allow_gpu="${2:-1}"
    local allow_audio="${3:-1}"

    target_args+=(--ro-bind /usr /usr)
    [[ -d /etc ]] && target_args+=(--ro-bind /etc /etc)
    [[ -d /bin ]] && target_args+=(--ro-bind /bin /bin)
    [[ -d /sbin ]] && target_args+=(--ro-bind /sbin /sbin)
    [[ -d /lib ]] && target_args+=(--ro-bind /lib /lib)
    [[ -d /lib64 ]] && target_args+=(--ro-bind /lib64 /lib64)
    [[ -d /opt ]] && target_args+=(--ro-bind /opt /opt)
    [[ -d /etc/ssl ]] && target_args+=(--ro-bind /etc/ssl /etc/ssl)
    [[ -d /etc/alternatives ]] && target_args+=(--ro-bind /etc/alternatives /etc/alternatives)
    [[ -d /sys ]] && target_args+=(--ro-bind /sys /sys)

    # Hardware & Gamepad bindings
    [[ -d /dev/input ]] && target_args+=(--dev-bind-try /dev/input /dev/input)
    for js in /dev/js[0-9]*; do
        [[ -e "$js" ]] && target_args+=(--dev-bind-try "$js" "$js")
    done
    [[ -e /dev/fb0 ]] && target_args+=(--dev-bind-try /dev/fb0 /dev/fb0)
    [[ -e /dev/uinput ]] && target_args+=(--dev-bind-try /dev/uinput /dev/uinput)
    [[ -d /run/udev ]] && target_args+=(--ro-bind-try /run/udev /run/udev)

    if (( allow_gpu )) && [[ -d /dev/dri ]]; then
        target_args+=(--dev-bind /dev/dri /dev/dri)
    fi
    if (( allow_audio )) && [[ -d /dev/snd ]]; then
        target_args+=(--dev-bind /dev/snd /dev/snd)
    fi

    # Recalbox persistence
    if [[ -d "/recalbox/share" ]]; then
        target_args+=(
            --bind-try /recalbox/share /recalbox/share
            --bind-try /recalbox/share/roms /recalbox/share/roms
            --bind-try /recalbox/share/saves /recalbox/share/saves
            --bind-try /recalbox/share/bios /recalbox/share/bios
            --bind-try /recalbox/share/system /recalbox/share/system
        )
    fi
}

_ulpm_add_custom_binds() {
    # shellcheck disable=SC2178
    local -n target_args="$1"; shift
    local spec host dest
    while (($#)); do
        case "$1" in
            --bind)
                (($# >= 2)) || { _ulpm_log error "--bind requires HOST:DEST"; return 2; }
                spec="$2"; shift 2
                _ulpm_parse_bind "$spec" host dest || return $?
                [[ -d "$host" ]] && target_args+=(--bind "$host" "$dest") || target_args+=(--ro-bind "$host" "$dest")
                ;;
            *)
                _ulpm_log error "Unknown sandbox option: $1"; return 2
                ;;
        esac
    done
}

_ulpm_cleanup_mount() {
    local mountpoint="${1:-}"
    [[ -n "$mountpoint" ]] || return 0
    if _ulpm_have fusermount3; then
        fusermount3 -u -z "$mountpoint" >/dev/null 2>&1 || umount -l "$mountpoint" >/dev/null 2>&1 || true
    elif _ulpm_have fusermount; then
        fusermount -u -z "$mountpoint" >/dev/null 2>&1 || umount -l "$mountpoint" >/dev/null 2>&1 || true
    else
        umount -l "$mountpoint" >/dev/null 2>&1 || true
    fi
    rmdir -- "$mountpoint" >/dev/null 2>&1 || true
}

lpk_run_rootfs() {
    local rootfs_dir="${1:-}"; shift || true
    [[ -n "$rootfs_dir" ]] || { _ulpm_log error "lpk_run_rootfs: missing rootfs directory"; return 2; }
    rootfs_dir="$(_ulpm_abs_path "$rootfs_dir")"
    lpk_is_rootfs "$rootfs_dir" || { _ulpm_log error "Not a valid LPK rootfs: $rootfs_dir"; return 2; }
    _ulpm_check_bwrap || return $?

    local -a custom_binds=() cmd=() args=() env_args=()
    local in_options=1 allow_gpu=1 allow_audio=1 allow_gui=1
    while (($#)); do
        if ((in_options)) && [[ "$1" == --bind ]]; then
            (($# >= 2)) || { _ulpm_log error "--bind requires HOST:DEST"; return 2; }
            custom_binds+=(--bind "$2"); shift 2
        elif ((in_options)) && [[ "$1" == --no-gpu ]]; then
            allow_gpu=0; shift
        elif ((in_options)) && [[ "$1" == --no-audio ]]; then
            allow_audio=0; shift
        elif ((in_options)) && [[ "$1" == --no-gui ]]; then
            allow_gui=0; shift
        elif ((in_options)) && [[ "$1" == -- ]]; then
            in_options=0; shift
        else
            cmd+=("$1"); shift
        fi
    done
    ((${#cmd[@]})) || cmd=(/bin/sh)

    local data_root="${XDG_DATA_HOME:-$HOME/.local/share}/ulpm/apps/_rootfs"
    local sandbox_home="$data_root/home"
    mkdir -p -- "$sandbox_home" || return 1
    chmod 700 -- "$sandbox_home" 2>/dev/null || true

    # Prepare Multilingual Downloads
    local host_downloads
    host_downloads="$(resolve_host_downloads_dir)"
    local dl_base
    dl_base="$(basename "$host_downloads")"
    setup_sandbox_downloads_links "$sandbox_home" "$host_downloads"

    args=(--die-with-parent --new-session --unshare-pid --unshare-ipc --unshare-uts --cap-drop ALL)
    args+=(--ro-bind "$rootfs_dir" / --proc /proc --dev /dev --tmpfs /tmp --dir /run --dir /var/tmp)
    [[ -d /sys ]] && args+=(--ro-bind /sys /sys)
    args+=(--bind "$sandbox_home" "$HOME")

    # Bind the true Downloads folder directly to its realpath and its home path
    args+=(--bind "$host_downloads" "$host_downloads")
    [[ "$host_downloads" != "$HOME/$dl_base" ]] && args+=(--bind "$host_downloads" "$HOME/$dl_base")
    [[ -f "$HOME/.config/user-dirs.dirs" ]] && args+=(--ro-bind-try "$HOME/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs")

    (( allow_gpu )) && [[ -d /dev/dri ]] && args+=(--dev-bind /dev/dri /dev/dri)
    (( allow_audio )) && [[ -d /dev/snd ]] && args+=(--dev-bind /dev/snd /dev/snd)
    [[ "${ULPM_SANDBOX_NETWORK:-0}" == 1 ]] || args+=(--unshare-net)

    # Hardware & Gamepad bindings
    args+=(
        --dev-bind-try /dev/input /dev/input
        --dev-bind-try /dev/fb0 /dev/fb0
        --dev-bind-try /dev/uinput /dev/uinput
        --ro-bind-try /run/udev /run/udev
    )
    for js in /dev/js[0-9]*; do
        [[ -e "$js" ]] && args+=(--dev-bind-try "$js" "$js")
    done

    # Recalbox persistence
    if [[ -d "/recalbox/share" ]]; then
        args+=(
            --bind-try /recalbox/share /recalbox/share
            --bind-try /recalbox/share/roms /recalbox/share/roms
            --bind-try /recalbox/share/saves /recalbox/share/saves
            --bind-try /recalbox/share/bios /recalbox/share/bios
            --bind-try /recalbox/share/system /recalbox/share/system
        )
    fi

    _ulpm_collect_env env_args
    args+=("${env_args[@]}")
    _ulpm_add_gui_mounts args "$allow_gui" "$allow_audio"
    _ulpm_add_dbus args
    _ulpm_add_custom_binds args "${custom_binds[@]}" || return $?
    exec bwrap "${args[@]}" --chdir "$HOME" -- "${cmd[@]}"
}

lpk_run_isolated() {
    local pkg_path="${1:-}"; shift || true
    [[ -n "$pkg_path" && -f "$pkg_path" && ! -L "$pkg_path" ]] || {
        _ulpm_log error "lpk_run_isolated: LPK must be a regular file: $pkg_path"
        return 2
    }
    pkg_path="$(_ulpm_abs_path "$pkg_path")"
    _ulpm_check_bwrap || return $?
    _ulpm_check_signature "$pkg_path" || return 1
    _ulpm_have squashfuse || { _ulpm_log error "squashfuse is required to mount LPK packages."; return 127; }

    local runtime_dir="${ULPM_SANDBOX_RUNTIME_DIR}"
    mkdir -p -- "$runtime_dir" || return 1
    chmod 700 -- "$runtime_dir" 2>/dev/null || true
    local mountpoint
    mountpoint="$(mktemp -d "$runtime_dir/lpk.XXXXXXXX")" || return 1

    local cleanup_done=0
    _ulpm_cleanup_lpk_run() {
        ((cleanup_done)) && return 0
        cleanup_done=1
        _ulpm_cleanup_mount "$mountpoint"
        if [[ -n "${ULPM_DBUS_PROXY_PID:-}" ]]; then
            kill "$ULPM_DBUS_PROXY_PID" >/dev/null 2>&1 || true
            wait "$ULPM_DBUS_PROXY_PID" >/dev/null 2>&1 || true
            unset ULPM_DBUS_PROXY_PID
        fi
        if [[ -n "${ULPM_DBUS_PROXY_DIR:-}" ]]; then
            rm -rf -- "$ULPM_DBUS_PROXY_DIR" 2>/dev/null || true
            unset ULPM_DBUS_PROXY_DIR
        fi
        eval "$old_int" 2>/dev/null || trap - INT
        eval "$old_term" 2>/dev/null || trap - TERM
        eval "$old_hup" 2>/dev/null || trap - HUP
    }

    local old_int old_term old_hup
    old_int="$(trap -p INT || true)"
    old_term="$(trap -p TERM || true)"
    old_hup="$(trap -p HUP || true)"
    trap '_ulpm_cleanup_lpk_run; exit 130' INT
    trap '_ulpm_cleanup_lpk_run; exit 143' TERM
    trap '_ulpm_cleanup_lpk_run; exit 129' HUP

    if ! squashfuse "$pkg_path" "$mountpoint"; then
        _ulpm_cleanup_lpk_run
        _ulpm_log error "Unable to mount LPK package: $pkg_path"
        return 1
    fi

    # Read manifest
    local manifest="" entrypoint="" app_id="" app_name="" app_net=""
    for manifest in "$mountpoint/meta/manifest.json" "$mountpoint/manifest.json" "$mountpoint/lpk.json"; do
        [[ -f "$manifest" ]] && break
        manifest=""
    done

    if [[ -n "$manifest" ]] && _ulpm_have jq; then
        entrypoint="$(jq -r 'if (.exec // .entrypoint // .command) | type == "string" then (.exec // .entrypoint // .command) else empty end' "$manifest" 2>/dev/null || true)"
        app_id="$(jq -r 'if (.id // .app_id) | type == "string" then (.id // .app_id) else empty end' "$manifest" 2>/dev/null || true)"
        app_name="$(jq -r 'if .name | type == "string" then .name else empty end' "$manifest" 2>/dev/null || true)"
        app_net="$(jq -r 'if .network | type == "boolean" then .network else empty end' "$manifest" 2>/dev/null || true)"
    fi

    if [[ -n "$app_id" && ! "$app_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        _ulpm_log warn "Invalid app ID in manifest; falling back to package name."
        app_id=""
    fi

    # Determine app root inside squashfs (support both layout with root/ and flat layout)
    local app_source="$mountpoint"
    if [[ -d "$mountpoint/root" ]]; then
        app_source="$mountpoint/root"
    fi

    if [[ -z "$entrypoint" ]]; then
        for candidate in "$app_source/AppRun" "$app_source/bin/main" "$app_source/run.sh"; do
            if [[ -x "$candidate" ]]; then
                entrypoint="${candidate#"$app_source/"}"
                break
            fi
        done
    fi
    [[ -n "$entrypoint" ]] || entrypoint="bin/sh"

    entrypoint="${entrypoint#/}"
    if [[ "$entrypoint" == *$'\n'* || "$entrypoint" == *$'\r'* || "$entrypoint" =~ (^|/)\.\.(/|$) ]]; then
        _ulpm_log error "Unsafe LPK entrypoint in manifest: $entrypoint"
        _ulpm_cleanup_lpk_run
        return 2
    fi

    if [[ ! -x "$app_source/$entrypoint" ]]; then
        _ulpm_log error "LPK entrypoint missing or not executable: $entrypoint"
        _ulpm_cleanup_lpk_run
        return 1
    fi

    local -a custom_binds=() command_args=() args=() env_args=()
    local parse_options=1 disable_net=0 allow_gpu=1 allow_audio=1 allow_gui=1
    while (($#)); do
        if ((parse_options)) && [[ "$1" == --bind ]]; then
            (($# >= 2)) || { _ulpm_cleanup_lpk_run; _ulpm_log error "--bind requires HOST:DEST"; return 2; }
            custom_binds+=(--bind "$2"); shift 2
        elif ((parse_options)) && [[ "$1" == --offline || "$1" == --no-net ]]; then
            disable_net=1; shift
        elif ((parse_options)) && [[ "$1" == --no-gpu ]]; then
            allow_gpu=0; shift
        elif ((parse_options)) && [[ "$1" == --no-audio ]]; then
            allow_audio=0; shift
        elif ((parse_options)) && [[ "$1" == --no-gui ]]; then
            allow_gui=0; shift
        elif ((parse_options)) && [[ "$1" == -- ]]; then
            parse_options=0; shift
        else
            command_args+=("$1"); shift
        fi
    done

    local data_root="${XDG_DATA_HOME:-$HOME/.local/share}/ulpm/apps"
    local app_data="$data_root/${app_id:-$(basename "$pkg_path" .lpk)}"
    local sandbox_home="$app_data/home"
    mkdir -p -- "$app_data" "$sandbox_home" || { _ulpm_cleanup_lpk_run; return 1; }
    chmod 700 -- "$app_data" "$sandbox_home" 2>/dev/null || true

    # Prepare Multilingual Downloads
    local host_downloads
    host_downloads="$(resolve_host_downloads_dir)"
    local dl_base
    dl_base="$(basename "$host_downloads")"
    setup_sandbox_downloads_links "$sandbox_home" "$host_downloads"

    args=(--die-with-parent --new-session --unshare-pid --unshare-ipc --unshare-uts --cap-drop ALL)
    args+=(--ro-bind "$app_source" /app --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run --dir /run/user)
    args+=(--perms 0700 --dir "/run/user/$(id -u)")
    args+=(--dir /var --dir /var/lib)
    args+=(--bind "$app_data" /var/lib/ulpm)

    if [[ "$HOME" == /* && "$HOME" != / ]]; then
        local home_parent
        home_parent="$(dirname -- "$HOME")"
        [[ "$home_parent" == / ]] || args+=(--dir "$home_parent")
    fi
    args+=(--bind "$sandbox_home" "$HOME")

    # Bind the true Downloads folder directly to its real path and its home path
    if [[ -d "$host_downloads" ]]; then
        args+=(--bind "$host_downloads" "$host_downloads")
        [[ "$host_downloads" != "$HOME/$dl_base" ]] && args+=(--bind "$host_downloads" "$HOME/$dl_base")
    fi
    [[ -f "$HOME/.config/user-dirs.dirs" ]] && args+=(--ro-bind-try "$HOME/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs")

    _ulpm_add_common_mounts args "$allow_gpu" "$allow_audio"

    if (( disable_net )) || [[ "$app_net" == "false" && "${ULPM_SANDBOX_NETWORK:-0}" != 1 ]]; then
        args+=(--unshare-net)
    fi

    _ulpm_collect_env env_args
    args+=("${env_args[@]}")
    args+=(--setenv HOME "$HOME" --setenv ULPM_APP_NAME "${app_name:-$(basename "$pkg_path" .lpk)}")

    _ulpm_add_gui_mounts args "$allow_gui" "$allow_audio"
    _ulpm_add_dbus args

    local bind_rc=0
    _ulpm_add_custom_binds args "${custom_binds[@]}" || bind_rc=$?
    if ((bind_rc != 0)); then
        _ulpm_cleanup_lpk_run
        return "$bind_rc"
    fi

    if [[ "$entrypoint" == *chrom* || "$entrypoint" == *electron* || "$entrypoint" == *AppRun* ]]; then
        if [[ "${ULPM_CHROMIUM_NO_SANDBOX:-1}" == 1 ]]; then
            command_args+=(--no-sandbox --disable-dev-shm-usage)
        fi
    fi

    local rc=0
    bwrap "${args[@]}" --chdir /app -- "/app/$entrypoint" "${command_args[@]}" || rc=$?

    _ulpm_cleanup_lpk_run
    return "$rc"
}
