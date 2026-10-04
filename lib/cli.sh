#!/usr/bin/env bash
# cli.sh - Commandes utilisateur, installation, streaming, intégration

release_inst_mount() {
  if [[ -n "${INST_MNT_DIR:-}" ]]; then
    unmount_dir "$INST_MNT_DIR"
    INST_MNT_DIR=""
  fi
}

drop_stage() {
  if [[ -n "${STAGE_PKG:-}" ]]; then
    rm -f -- "$STAGE_PKG" 2>/dev/null || true
    STAGE_PKG=""
  fi
}

lpk_install_file() {
  local pkg="$1"
  local repo_origin="${2:-local}"
  local version_override="${3:-}"

  pkg="$(normalize_target "$pkg")" || { echo -e "${RED}[-] Invalid path${NC}" >&2; return 1; }
  if [[ ! -f "$pkg" ]]; then
    echo -e "${RED}[-] Package not found: $pkg${NC}" >&2
    return 1
  fi

  STAGE_PKG="$(mktemp "$ULPM_APPS/.stage.XXXXXX")"
  if ! cp -f -- "$pkg" "$STAGE_PKG"; then
    echo -e "${RED}[-] Cannot copy package into $ULPM_APPS${NC}" >&2
    drop_stage
    return 1
  fi

  if ! verify_package_signature "$STAGE_PKG"; then
    echo -e "${RED}[-] Installation aborted: signature check failed${NC}" >&2
    drop_stage
    return 1
  fi

  if [[ -n "${ULPM_PINNED_FPR:-}" && "$LAST_SIG_FPR" != "$ULPM_PINNED_FPR" ]]; then
    local got="${LAST_SIG_FPR:0:16}"
    echo -e "${RED}[-] Update aborted: signing key differs from the one pinned at first install${NC}" >&2
    echo -e "${GRAY}    pinned: ${ULPM_PINNED_FPR:0:16}...  got: ${got:-unsigned}${NC}" >&2
    echo -e "${GRAY}    If this change is legitimate: ulpm remove <id>, then install again.${NC}" >&2
    drop_stage
    return 1
  fi

  local mnt_tmp
  mnt_tmp=$(mktemp -d "${ULPM_TMPDIR:-${TMPDIR:-/tmp}}/ulpm_inst_XXXXXX")
  INST_MNT_DIR="$mnt_tmp"

  if ! squashfuse "$STAGE_PKG" "$mnt_tmp" 2>/dev/null; then
    echo -e "${RED}[-] Failed to mount package${NC}" >&2
    rmdir "$mnt_tmp" 2>/dev/null || true
    INST_MNT_DIR=""
    drop_stage
    return 1
  fi

  local manifest="$mnt_tmp/meta/manifest.json"
  if [[ ! -f "$manifest" ]] || ! validate_manifest "$manifest"; then
    release_inst_mount
    drop_stage
    return 1
  fi

  local id name version icon_file exec_file
  id=$(jq -r '.id' "$manifest")
  name=$(jq -r '.name' "$manifest")
  version=$(jq -r '.version // "1.0.0"' "$manifest")
  icon_file=$(jq -r '.icon // empty' "$manifest")
  exec_file=$(jq -r '.exec' "$manifest")

  local package_root exec_real
  package_root=$(realpath -e -- "$mnt_tmp")
  exec_real=$(realpath -e -- "$package_root/root/$exec_file" 2>/dev/null || true)
  if [[ -z "$exec_real" || ! -x "$exec_real" ]]; then
    echo -e "${RED}[-] Manifest executable missing or not executable${NC}" >&2
    release_inst_mount
    drop_stage
    return 1
  fi

  echo -e "${BLUE}::${NC} Installing ${BOLD}$name${NC} ($id)..."

  local target_icon="$id" icon_real=""
  if [[ -n "$icon_file" ]]; then
    icon_real=$(realpath -e -- "$package_root/$icon_file" 2>/dev/null || true)
    if [[ -n "$icon_real" && -f "$icon_real" && "$icon_real" == "$package_root/"* ]]; then
      cp -f -- "$icon_real" "$ICON_DIR/$id.png"
      target_icon="$ICON_DIR/$id.png"
    fi
  fi

  release_inst_mount

  local target_pkg="$ULPM_APPS/$id.lpk"
  chmod 644 "$STAGE_PKG"
  mv -f -- "$STAGE_PKG" "$target_pkg"
  STAGE_PKG=""

  write_desktop_entry "$id" "$name" "$target_icon"

  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

  local db_version="${version_override:-$version}"
  db_replace_entry "$id" "${id}|${name}|${db_version}|${repo_origin}|$(date +%s)|${LAST_SIG_FPR:-}"

  echo -e "${GREEN}✔ '$name' installed successfully${NC}"
}

cmd_run() {
  local rc=0 start=$SECONDS log=""
  if [[ ! -t 2 ]]; then
    mkdir -p "$CACHE_DIR"
    log="$CACHE_DIR/last-run.log"
    if [[ -f "$log" ]] && [[ "$(wc -c < "$log")" -gt 1048576 ]]; then
      : > "$log"
    fi
    printf '\n=== %s ulpm run %s ===\n' "$(date '+%F %T')" "$*" >> "$log"
    exec >>"$log" 2>&1
  fi
  lpk_run_isolated "$@" || rc=$?
  if [[ $rc -ne 0 && -n "$log" && $((SECONDS - start)) -lt 5 ]] \
     && command -v notify-send >/dev/null 2>&1; then
    notify-send -a ULPM -i dialog-error "ULPM: launch failed" "Details: $log" >/dev/null 2>&1 || true
  fi
  return "$rc"
}

resolve_and_fetch_cached() {
  local target="$1"
  local dl_url="" cache_file=""

  if [[ "$target" =~ ^https?://.*\.lpk$ ]]; then
    dl_url="$target"
    local hash
    hash=$(printf "%s" "$target" | md5sum | cut -d' ' -f1)
    cache_file="$CACHE_PKG_DIR/${hash}.lpk"
  else
    local repo_path
    repo_path=$(echo "$target" | sed -E 's#^https?://github.com/##; s#/$##; s#\.git$##')
    local release_json
    release_json=$(fetch_github_api "repos/${repo_path}/releases/latest") || return 1
    dl_url=$(find_lpk_download_url "$release_json" "$ARCH_REGEX")
    if [[ -z "$dl_url" ]]; then
      echo -e "${RED}[-] No .lpk found for this architecture${NC}" >&2
      return 1
    fi
    local tag_name safe_repo
    tag_name=$(echo "$release_json" | jq -r '.tag_name // "latest"')
    safe_repo=$(echo "$repo_path" | tr '/' '_')
    tag_name=$(echo "$tag_name" | tr -c 'A-Za-z0-9._\n-' '_')
    cache_file="$CACHE_PKG_DIR/${safe_repo}_${tag_name}.lpk"
  fi

  if [[ -f "$cache_file" ]]; then
    echo -e "${CYAN}-> Checking for updates...${NC}" >&2
    curl -fsSL --time-cond "$cache_file" -o "$cache_file.part" "$dl_url" 2>/dev/null || true
    if [[ -s "$cache_file.part" ]]; then
      mv -f "$cache_file.part" "$cache_file"
      echo -e "${GREEN}✔ Updated${NC}" >&2
    else
      rm -f "$cache_file.part"
      echo -e "${GREEN}✔ Cache up-to-date${NC}" >&2
    fi
  else
    echo -e "${BLUE}::${NC} Downloading into cache..." >&2
    curl -fsSL --progress-bar -o "$cache_file.part" "$dl_url" >&2 \
      && mv -f "$cache_file.part" "$cache_file" \
      || { rm -f "$cache_file.part" "$cache_file"; return 1; }
  fi

  echo "$cache_file"
}

cmd_stream() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo -e "${RED}[-] Usage: ulpm stream <url|owner/repo> [args...]${NC}" >&2
    return 1
  fi
  shift || true

  local tmp_lpk="$TEMP_DIR/streamed.lpk"
  local dl_url=""

  if [[ "$target" =~ ^https?://.*\.lpk$ ]]; then
    dl_url="$target"
  else
    local repo_path
    repo_path=$(echo "$target" | sed -E 's#^https?://github.com/##; s#/$##; s#\.git$##')
    local release_json
    release_json=$(fetch_github_api "repos/${repo_path}/releases/latest") || return 1
    dl_url=$(find_lpk_download_url "$release_json" "$ARCH_REGEX")
    if [[ -z "$dl_url" ]]; then
      echo -e "${RED}[-] No .lpk found for $repo_path${NC}" >&2
      return 1
    fi
  fi

  echo -e "${BLUE}::${NC} Streaming to ephemeral storage..."
  curl -fsSL --progress-bar -o "$tmp_lpk" "$dl_url" || return 1

  echo -e "${CYAN}-> Launching ephemeral container...${NC}"
  local rc=0
  lpk_run_isolated "$tmp_lpk" "$@" || rc=$?

  rm -f "$tmp_lpk"
  echo -e "${GREEN}✔ Ephemeral run finished – everything cleaned${NC}"
  return "$rc"
}

cmd_install_target() {
  local target="${1:-}"
  local app_name_hint="${2:-}"

  if [[ -z "$target" ]]; then
    echo -e "${RED}[-] Usage: ulpm install <file.lpk|AppImage|deb|rpm|owner/repo> [name]${NC}" >&2
    return 1
  fi
  target="$(normalize_target "$target")" || { echo -e "${RED}[-] Invalid target${NC}" >&2; return 1; }

  if [[ -f "$target" && "$target" =~ \.lpk$ ]]; then
    lpk_install_file "$target" "local"
    return $?
  fi

  if [[ -d "$target" || "$target" =~ \.(appimage|AppImage|deb|rpm|tar\..*|tgz|zip)$ ]]; then
    local out_lpk="$TEMP_DIR/bundle_${SYS_ARCH}.lpk"
    lpk_pack "$target" "$app_name_hint" "$out_lpk" || return 1
    lpk_install_file "$out_lpk" "local"
    return $?
  fi

  local repo_path
  repo_path=$(echo "$target" | sed -E 's#^https?://github.com/##; s#/$##; s#\.git$##')
  local release_json
  release_json=$(fetch_github_api "repos/${repo_path}/releases/latest") || return 1

  local tag
  tag=$(echo "$release_json" | jq -r '.tag_name // empty' | tr -d '\r')

  local lpk_url
  lpk_url=$(find_lpk_download_url "$release_json" "$ARCH_REGEX")

  if [[ -n "$lpk_url" ]]; then
    local tmp_lpk="$TEMP_DIR/downloaded.lpk"
    echo -e "${GREEN}✔ Downloading remote .lpk...${NC}"
    curl -fsSL --progress-bar -o "$tmp_lpk" "$lpk_url" || return 1
    lpk_install_file "$tmp_lpk" "$repo_path" "$tag"
    return $?
  fi

  local dl_url
  dl_url=$(find_archive_download_url "$release_json" "$ARCH_REGEX")
  if [[ -z "$dl_url" ]]; then
    echo -e "${RED}[-] No compatible binary found${NC}" >&2
    return 1
  fi

  local dl_name="${dl_url##*/}"
  dl_name="${dl_name%%\?*}"
  local tmp_archive="$TEMP_DIR/archive_dl_$(printf '%s' "$dl_name" | tr -cd 'A-Za-z0-9._-')"
  curl -fsSL --progress-bar -o "$tmp_archive" "$dl_url" || return 1
  local auto_lpk="$TEMP_DIR/generated_${SYS_ARCH}.lpk"
  lpk_pack "$tmp_archive" "${app_name_hint:-$(echo "$repo_path" | cut -d'/' -f2)}" "$auto_lpk" "${tag:-latest}" || return 1
  lpk_install_file "$auto_lpk" "$repo_path" "$tag"
}

cmd_upgrade() {
  echo -e "${BOLD}${CYAN}Checking for updates...${NC}"
  if [[ ! -s "$ULPM_DB" ]]; then
    echo -e "${GRAY}No tracked packages installed.${NC}"
    return 0
  fi

  local id name ver repo ts fpr
  while IFS='|' read -r -u 3 id name ver repo ts fpr; do
    [[ "$repo" == "local" || -z "$repo" ]] && continue
    local rel_data tag_remote
    rel_data=$(fetch_github_api "repos/${repo}/releases/latest") || continue
    tag_remote=$(echo "$rel_data" | jq -r '.tag_name // empty' | tr -d '\r')

    if [[ -n "$tag_remote" && "${tag_remote#v}" != "${ver#v}" ]]; then
      echo -e "  ${YELLOW}★ Update available for $name: $ver → $tag_remote${NC}"
      ULPM_PINNED_FPR="${fpr:-}" cmd_install_target "$repo" "$name" \
        || echo -e "  ${RED}[-] Update of $name failed${NC}" >&2
    else
      echo -e "  ${GREEN}✔ $name is up to date ($ver)${NC}"
    fi
  done 3< "$ULPM_DB"
}

cmd_remove() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo -e "${RED}[-] Specify package to remove${NC}" >&2
    return 1
  fi
  if [[ ! "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$target" == *..* ]]; then
    echo -e "${RED}[-] Invalid package id${NC}" >&2
    return 1
  fi

  local id="io.lpk.${target,,}"
  [[ "$target" =~ ^io\.lpk\. ]] && id="$target"

  rm -f "$ULPM_APPS/$id.lpk" \
        "$DESKTOP_DIR/ulpm-$id.desktop" \
        "$ICON_DIR/$id.png"

  db_replace_entry "$id" ""
  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  echo -e "${GREEN}✔ Removed $id${NC}"
}

cmd_list() {
  echo -e "${BOLD}${CYAN}Installed ULPM packages:${NC}"
  echo -e "${BLUE}---------------------------------------------------------${NC}"
  if [[ -s "$ULPM_DB" ]]; then
    while IFS='|' read -r id name ver repo _; do
      printf "${BOLD}%-25s${NC} ${GREEN}%-12s${NC} ${GRAY}(%s)${NC}\n" "$name" "$ver" "$repo"
    done < "$ULPM_DB"
  else
    echo -e "  ${GRAY}(No packages installed)${NC}"
  fi
  echo -e "${BLUE}---------------------------------------------------------${NC}"
}

cmd_clean() {
  local size
  size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1 || true)
  find "$CACHE_PKG_DIR" "$CACHE_API_DIR" -mindepth 1 -delete 2>/dev/null || true
  echo -e "${GREEN}✔ Cache cleaned (was ${size:-0})${NC}"
}

cmd_integrate() {
  local quiet=false
  [[ "${1:-}" == "quiet" ]] && quiet=true
  say() { [[ "$quiet" == "true" ]] || echo -e "$@"; }

  if [[ -z "$ULPM_BIN" || ! -x "$ULPM_BIN" ]]; then
    echo -e "${RED}[-] Cannot determine the absolute path of ulpm${NC}" >&2
    return 1
  fi

  local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  local conf_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  local mime_dir="$data_home/mime"

  mkdir -p "$mime_dir/packages" "$DESKTOP_DIR"
  cat > "$mime_dir/packages/application-x-lpk.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-lpk">
    <comment>ULPM package</comment>
    <glob pattern="*.lpk" weight="80"/>
    <sub-class-of type="application/octet-stream"/>
  </mime-type>
</mime-info>
EOF

  cat > "$DESKTOP_DIR/ulpm-open.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=ULPM Package Launcher
Comment=Run LPK packages in the ULPM sandbox
Exec=$(desktop_exec_quote "$ULPM_BIN") run %f
Icon=application-x-executable
Terminal=false
NoDisplay=true
MimeType=application/x-lpk;
Categories=System;
EOF

  if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "$mime_dir" >/dev/null 2>&1 || true
  fi
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default ulpm-open.desktop application/x-lpk >/dev/null 2>&1 || true
  fi
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
  refresh_desktop_entries
  say "${GREEN}✔ .lpk files are now associated with ulpm${NC}"

  if [[ "$ULPM_BIN_DIR" == "$HOME"/* ]]; then
    local envd="$conf_home/environment.d/60-ulpm.conf"
    mkdir -p "$(dirname "$envd")"
    printf 'PATH=%s:${PATH}\n' "$ULPM_BIN_DIR" > "$envd"

    local prof="$HOME/.profile"
    touch "$prof"
    if ! grep -qF "$ULPM_BIN_DIR" "$prof" 2>/dev/null; then
      {
        echo ""
        echo "# Added by ULPM (graphical sessions do not read ~/.bashrc)"
        echo "export PATH=\"$ULPM_BIN_DIR:\$PATH\""
      } >> "$prof"
    fi
    say "${GREEN}✔ $ULPM_BIN_DIR added to the graphical-session PATH (re-login to apply)${NC}"
  fi

  mkdir -p "$ULPM_DATA"
  printf '%s\n' "$ULPM_BIN" > "$ULPM_DATA/.integrated"
  return 0
}

ensure_integration() {
  [[ "$ULPM_NO_INTEGRATION" == "true" ]] && return 0
  [[ -n "$ULPM_BIN" && -x "$ULPM_BIN" ]] || return 0
  local current=""
  if [[ -f "$ULPM_DATA/.integrated" ]]; then
    current="$(cat "$ULPM_DATA/.integrated" 2>/dev/null || true)"
  fi
  [[ "$current" == "$ULPM_BIN" ]] && return 0
  cmd_integrate quiet || true
  return 0
}

usage() {
  print_banner
  cat <<EOF
ULPM - Universal Linux Package Manager (LPK Engine v3.3)

Usage: ulpm <command> [options]

Core:
  stream <url|owner/repo> [args]   Ephemeral launch from web/RAM
  run [--offline] <pkg|id|url>     Run in Bubblewrap sandbox
  install, -i <source> [name]      Install (.lpk / AppImage / deb / rpm / GitHub...)
  pack <source> [name] [out]       Create signed .lpk
  deb-pack <pkg|deb> [name]        Pack with recursive APT dependencies
  upgrade, -u                      Update GitHub-tracked packages
  remove, -r <id>                  Uninstall
  list, -l                         List installed packages
  clean                            Purge the package and API caches
  integrate                        (Re)register *.lpk double-click + graphical PATH

Cryptography:
  keygen [name]                    Generate Ed25519 keypair
  sign <file.lpk> [privkey]        Embed signature footer
  trust <file.pub>                 Trust a public key

Environment:
  ULPM_STRICT_SIGNATURES=true|false
  ULPM_REQUIRE_TRUSTED_KEYS=true|false
  ULPM_DBUS_MODE=proxy|full|none
  ULPM_SHARE_PID=true|false
  ULPM_CLEARENV=true|false
  ULPM_ENV_PASSTHROUGH="A B"
  ULPM_NO_INTEGRATION=true|false
EOF
  exit 0
}