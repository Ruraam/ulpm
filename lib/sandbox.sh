#!/usr/bin/env bash
# ==============================================================================
# lib/sandbox.sh - Concurrent-Safe Production Sandboxing Engine (App & RootFS)
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
    __GLX_VENDOR_LIBRARY_NAME __NV_PRIME_RENDER_OFFLOAD __VK_LAYER_NV_optimus
    VK_ICD_FILENAMES VK_DRIVER_FILES LIBVA_DRIVER_NAME MESA_LOADER_DRIVER_OVERRIDE
    # Recalbox / Gaming specific variables
    RECALBOX_SYSTEM_DIR CONTROLLER_CONFIG SDL_JOYSTICK_DEVICE
)

# ------------------------------------------------------------------------------
# D-Bus Session Socket Helper
# ------------------------------------------------------------------------------

session_bus_socket() {
    local run_user_dir="$1"
    local addr="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$run_user_dir/bus}"
    if [[ "$addr" =~ ^unix:path=([^,]+) ]] && [[ -S "${BASH_REMATCH[1]}" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# RootFS Detection & Execution Mode (Debian XFCE, Recalbox Container, etc.)
# ------------------------------------------------------------------------------

lpk_is_rootfs() {
    local mount_dir="$1"
    local manifest="$2"

    if [[ -f "$manifest" ]]; then
        local is_rootfs
        is_rootfs=$(jq -r '.type // .kind // empty' "$manifest" 2>/dev/null || true)
        if [[ "$is_rootfs" == "rootfs" || "$is_rootfs" == "distro" || "$is_rootfs" == "os" ]]; then
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
    shift 5

    local rootfs_dir="$mnt_dir"
    if [[ -d "$mnt_dir/root" && -d "$mnt_dir/root/etc" ]]; then
        rootfs_dir="$mnt_dir/root"
    fi

    local app_data_dir="$HOME/.var/app/$app_id"
    mkdir -p "$app_data_dir/home" "$app_data_dir/cache" "$app_data_dir/tmp"

    local run_uid run_user_dir
    run_uid="$(id -u)"
    run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"

    local bwrap_args=(
        bwrap
        --die-with-parent
        --new-session
        --clearenv
        --unshare-uts
        --unshare-cgroup-try
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
    )

    if [[ "$force_offline" == "true" || "$allow_net" == "false" ]]; then
        bwrap_args+=(--unshare-net)
    else
        bwrap_args+=(--share-net)
    fi

    # Recalbox & Host Hardware Binding
    bwrap_args+=(
        --dev-bind-try /dev/input /dev/input
        --dev-bind-try /dev/js0 /dev/js0
        --dev-bind-try /dev/js1 /dev/js1
        --dev-bind-try /dev/js2 /dev/js2
        --dev-bind-try /dev/js3 /dev/js3
        --dev-bind-try /dev/snd /dev/snd
        --dev-bind-try /dev/dri /dev/dri
        --dev-bind-try /dev/fb0 /dev/fb0
        --dev-bind-try /dev/uinput /dev/uinput
        --ro-bind-try /run/udev /run/udev
    )

    if [[ -d "/recalbox/share" ]]; then
        bwrap_args+=(
            --bind-try /recalbox/share /recalbox/share
            --bind-try /recalbox/share/roms /recalbox/share/roms
            --bind-try /recalbox/share/saves /recalbox/share/saves
            --bind-try /recalbox/share/bios /recalbox/share/bios
            --bind-try /recalbox/share/system /recalbox/share/system
        )
    fi

    # Display Server
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

    # Audio Sockets
    local pulse_sock="$run_user_dir/pulse/native"
    if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
        pulse_sock="${BASH_REMATCH[1]}"
    fi
    bwrap_args+=(
        --bind-try "$pulse_sock" "$pulse_sock"
        --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
    )

    bwrap_args+=(
        --ro-bind-try /etc/resolv.conf /etc/resolv.conf
        --ro-bind-try /etc/hosts /etc/hosts
    )

    for env_var in "${ENV_WHITELIST[@]}"; do
        if [[ -n "${!env_var:-}" ]]; then
            bwrap_args+=(--setenv "$env_var" "${!env_var}")
        fi
    done

    local entrypoint="${exec_bin:-/bin/sh}"
    if [[ -z "$exec_bin" || "$exec_bin" == "/bin/main" ]]; then
        if [[ -x "$rootfs_dir/usr/bin/startxfce4" ]]; then
            entrypoint="/usr/bin/startxfce4"
        elif [[ -x "$rootfs_dir/usr/bin/x-session-manager" ]]; then
            entrypoint="/usr/bin/x-session-manager"
        elif [[ -x "$rootfs_dir/bin/bash" ]]; then
            entrypoint="/bin/bash"
        fi
    fi

    log "Starting RootFS session [$app_id] with entrypoint: $entrypoint"
    "${bwrap_args[@]}" "$entrypoint" "$@"
}

# ------------------------------------------------------------------------------
# App Mode Execution (Shared Host Base + Sandbox + Full Concurrency)
# ------------------------------------------------------------------------------

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
        error "No target specified"
        return 1
    fi
    shift || true

    local pkg_path=""
    if [[ -f "$target" ]]; then
        pkg_path="$(realpath -- "$target")"
    elif [[ -f "$ULPM_APPS_DIR/$target.lpk" ]]; then
        pkg_path="$ULPM_APPS_DIR/$target.lpk"
    elif [[ -f "$ULPM_APPS_DIR/$target/$target.lpk" ]]; then
        pkg_path="$ULPM_APPS_DIR/$target/$target.lpk"
    else
        error "Target package '$target' could not be resolved"
        return 1
    fi

    # Cryptographic signature verification
    if ! verify_package "$pkg_path"; then
        warn "Signature check failed or missing. Continuing in sandbox..."
    fi

    # Instance-isolated scope execution (immune to race conditions)
    local instance_id
    instance_id="$$-${RANDOM}"
    local mnt_dir dbus_proxy_dir dbus_pid=""

    mnt_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/ulpm_mnt_${instance_id}.XXXXXX")"

    # Contextual cleanup attached only to this instance
    cleanup_instance() {
        if [[ -n "$dbus_pid" ]] && kill -0 "$dbus_pid" 2>/dev/null; then
            kill "$dbus_pid" 2>/dev/null || true
            wait "$dbus_pid" 2>/dev/null || true
        fi
        [[ -n "$dbus_proxy_dir" && -d "$dbus_proxy_dir" ]] && rm -rf "$dbus_proxy_dir"

        if command -v fusermount3 &>/dev/null; then
            fusermount3 -u -z "$mnt_dir" 2>/dev/null || true
        elif command -v fusermount &>/dev/null; then
            fusermount -u -z "$mnt_dir" 2>/dev/null || true
        elif command -v safe_unmount &>/dev/null; then
            safe_unmount "$mnt_dir" 2>/dev/null || true
        fi
        rm -rf "$mnt_dir"
    }
    trap cleanup_instance EXIT INT TERM HUP

    if ! squashfuse "$pkg_path" "$mnt_dir" 2>/dev/null; then
        error "Failed to mount SquashFS image ($pkg_path)"
        return 1
    fi

    local manifest="$mnt_dir/meta/manifest.json"
    if [[ ! -f "$manifest" ]]; then
        manifest="$mnt_dir/lpk.json"
    fi

    local app_id="app_$(basename "$target" .lpk)"
    local exec_bin="bin/main"
    local is_chromium=false
    local allow_net=true

    if [[ -f "$manifest" ]]; then
        app_id=$(jq -r '.id // .name // "'"$app_id"'"' "$manifest" 2>/dev/null || echo "$app_id")
        exec_bin=$(jq -r '.exec // "bin/main"' "$manifest" 2>/dev/null || echo "bin/main")
        is_chromium=$(jq -r '.chromium // false' "$manifest" 2>/dev/null || echo "false")
        allow_net=$(jq -r '.network // true' "$manifest" 2>/dev/null || echo "true")
    fi

    # --------------------------------------------------------------------------
    # ROOTFS ROUTING
    # --------------------------------------------------------------------------
    if lpk_is_rootfs "$mnt_dir" "$manifest"; then
        local rootfs_rc=0
        lpk_run_rootfs "$mnt_dir" "$app_id" "$exec_bin" "$force_offline" "$allow_net" "$@" || rootfs_rc=$?
        return "$rootfs_rc"
    fi

    # --------------------------------------------------------------------------
    # STANDARD APP SANDBOX SETUP
    # --------------------------------------------------------------------------
    local app_data_dir="$HOME/.var/app/$app_id"
    mkdir -p "$app_data_dir/home" "$app_data_dir/config" "$app_data_dir/data" "$app_data_dir/cache"

    local run_uid run_user_dir dl_dir
    run_uid="$(id -u)"
    run_user_dir="${XDG_RUNTIME_DIR:-/run/user/$run_uid}"
    dl_dir="${HOME}/Downloads"
    mkdir -p "$dl_dir"

    # Clean leading slash in execution target
    local clean_exec="${exec_bin#/}"

    # Determine payload directory (/root/ structure or direct root)
    local app_payload_dir="$mnt_dir"
    if [[ -d "$mnt_dir/root" ]]; then
        app_payload_dir="$mnt_dir/root"
    fi

    # Electron / Chromium sandbox management
    local chromium_flags=()
    if [[ "$is_chromium" == "true" ]] || grep -qiE "chromium|electron" "$app_payload_dir/$clean_exec" 2>/dev/null; then
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
        bwrap
        --die-with-parent
        --new-session
        --clearenv
        --cap-drop ALL
        --unshare-uts
        --unshare-cgroup-try
        --ro-bind /usr /usr
        --proc /proc
        --dev /dev
        --dev-bind /dev/shm /dev/shm
        --ro-bind /sys /sys
        --tmpfs /tmp
        --tmpfs /run
        --tmpfs /var/tmp
        --bind "$app_data_dir/home" "$HOME"
    )

    # Multiarch library symlinks support
    for dir in /lib /lib64 /lib32 /bin /sbin; do
        if [[ -d "$dir" ]]; then
            bwrap_args+=(--ro-bind "$dir" "$dir")
        fi
    done

    # Network configuration
    if [[ "$force_offline" == "true" || "$allow_net" == "false" ]]; then
        bwrap_args+=(--unshare-net)
    else
        bwrap_args+=(--share-net)
    fi

    # System configurations & certificates
    local etc_item
    for etc_item in alternatives ld.so.cache ld.so.conf ld.so.conf.d \
        ssl ca-certificates pki crypto-policies fonts X11 xdg gtk-2.0 gtk-3.0 pulse vulkan glvnd \
        localtime timezone os-release machine-id passwd group nsswitch.conf hosts resolv.conf; do
        bwrap_args+=(--ro-bind-try "/etc/$etc_item" "/etc/$etc_item")
    done

    # Hardware, Gaming & User directories
    bwrap_args+=(
        --dev-bind-try /dev/dri /dev/dri
        --dev-bind-try /dev/snd /dev/snd
        --dev-bind-try /dev/input /dev/input
        --dev-bind-try /dev/js0 /dev/js0
        --dev-bind-try /dev/js1 /dev/js1
        --dev-bind-try /dev/js2 /dev/js2
        --dev-bind-try /dev/js3 /dev/js3
        --dev-bind-try /dev/uinput /dev/uinput
        --ro-bind-try /run/udev /run/udev
        --ro-bind-try /usr/share/vulkan /usr/share/vulkan
        --ro-bind-try /usr/share/glvnd /usr/share/glvnd
        --ro-bind-try /usr/share/fonts /usr/share/fonts
        --ro-bind-try /usr/share/themes /usr/share/themes
        --ro-bind-try /usr/share/icons /usr/share/icons
        --perms 0700 --dir "$run_user_dir"
        --bind "$dl_dir" "$dl_dir"
        --bind "$app_data_dir/config" "$HOME/.config"
        --bind "$app_data_dir/data" "$HOME/.local/share"
        --bind "$app_data_dir/cache" "$HOME/.cache"
        --ro-bind "$app_payload_dir" /app
    )

    if [[ -d "/recalbox/share" ]]; then
        bwrap_args+=(--bind-try /recalbox/share /recalbox/share)
    fi

    # Display Protocols (Wayland & X11)
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

    # Audio Routing (PulseAudio / PipeWire)
    local pulse_sock="$run_user_dir/pulse/native"
    if [[ "${PULSE_SERVER:-}" =~ ^unix:(.+)$ ]]; then
        pulse_sock="${BASH_REMATCH[1]}"
    fi
    bwrap_args+=(
        --bind-try "$pulse_sock" "$pulse_sock"
        --bind-try "$run_user_dir/pipewire-0" "$run_user_dir/pipewire-0"
    )

    # --------------------------------------------------------------------------
    # D-Bus Isolation Proxy (Per-Instance Safe)
    # --------------------------------------------------------------------------
    case "${ULPM_DBUS_MODE:-proxy}" in
        none) ;;
        full)
            local full_sock
            if full_sock=$(session_bus_socket "$run_user_dir"); then
                bwrap_args+=(--bind "$full_sock" "$run_user_dir/bus")
            fi
            ;;
        *)
            if command -v xdg-dbus-proxy &>/dev/null; then
                local real_sock
                if real_sock=$(session_bus_socket "$run_user_dir"); then
                    dbus_proxy_dir="$(mktemp -d "$run_user_dir/ulpm_dbus_${instance_id}.XXXXXX" 2>/dev/null || true)"
                    if [[ -n "$dbus_proxy_dir" && -d "$dbus_proxy_dir" ]]; then
                        local dbus_extra=()
                        if [[ -n "${ULPM_DBUS_EXTRA:-}" ]]; then
                            # shellcheck disable=SC2206
                            dbus_extra=($ULPM_DBUS_EXTRA)
                        fi

                        xdg-dbus-proxy "unix:path=$real_sock" "$dbus_proxy_dir/bus" --filter \
                            --own="${app_id}.*" \
                            --own='org.mpris.MediaPlayer2.*' \
                            --talk=org.freedesktop.Notifications \
                            --talk=org.freedesktop.ScreenSaver \
                            --talk=org.freedesktop.PowerManagement.Inhibit \
                            --talk=org.freedesktop.portal.Desktop \
                            --talk=org.freedesktop.portal.Documents \
                            --talk=org.kde.StatusNotifierWatcher \
                            ${dbus_extra[@]+"${dbus_extra[@]}"} &
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
            fi
            ;;
    esac

    # Forward environment variables
    for env_var in "${ENV_WHITELIST[@]}"; do
        if [[ -n "${!env_var:-}" ]]; then
            bwrap_args+=(--setenv "$env_var" "${!env_var}")
        fi
    done

    # Deterministic entrypoint resolution
    local real_exec="/app/$clean_exec"
    if [[ ! -x "$app_payload_dir/$clean_exec" ]]; then
        if [[ -x "$app_payload_dir/AppRun" ]]; then
            real_exec="/app/AppRun"
        elif [[ -x "$app_payload_dir/bin/main" ]]; then
            real_exec="/app/bin/main"
        elif [[ -x "$app_payload_dir/main" ]]; then
            real_exec="/app/main"
        fi
    fi

    bwrap_args+=(
        --setenv PATH "/app/bin:/app/usr/bin:/app:$PATH"
        --setenv LD_LIBRARY_PATH "/app/lib:/app/usr/lib:/app/lib64:/app/usr/lib64:/usr/lib/x86_64-linux-gnu:/usr/lib64:/usr/lib"
        --setenv XDG_DATA_DIRS "/app/share:/app/usr/share:/usr/share:/usr/local/share"
    )

    log "Launching application [$app_id] via Bubblewrap sandbox (Instance: $instance_id)..."
    "${bwrap_args[@]}" "$real_exec" "${chromium_flags[@]:-}" "$@"
}
