#!/usr/bin/env bash
# packaging.sh - Extraction, fat-bundling, packaging

validate_manifest() {
  local manifest="$1"
  if ! jq -e --argjson max_version "$ULPM_FORMAT_VERSION" '
    type == "object" and
    ((.format_version // 1) | type == "number" and . == floor and . >= 1 and . <= $max_version) and
    (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") and (contains("..") | not)) and
    (.name | type == "string" and length > 0 and length <= 128) and
    ((.version // "1.0.0") | type == "string" and length > 0 and length <= 64) and
    (.exec | type == "string" and length > 0 and length <= 4096 and
      (startswith("/") | not) and
      (split("/") | all(.[]; . != "" and . != "." and . != ".."))) and
    ((.icon // "") | type == "string" and length <= 4096 and
      (startswith("/") | not) and
      (split("/") | all(.[]; . != ".."))) and
    ((.chromium // false) | type == "boolean") and
    ((.network // true) | type == "boolean")
  ' "$manifest" >/dev/null 2>&1; then
    echo -e "${RED}[-] Invalid or unsafe manifest${NC}" >&2
    return 1
  fi
  return 0
}

appimage_squashfs_offset() {
  local f="$1" class shoff shentsize shnum
  [[ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]] || return 1
  [[ "$(od -An -tu1 -j5 -N1 "$f" | tr -d ' \n')" == "1" ]] || return 1
  class=$(od -An -tu1 -j4 -N1 "$f" | tr -d ' \n')
  case "$class" in
    2)
      shoff=$(od -An -tu8 -j40 -N8 "$f" | tr -d ' \n')
      shentsize=$(od -An -tu2 -j58 -N2 "$f" | tr -d ' \n')
      shnum=$(od -An -tu2 -j60 -N2 "$f" | tr -d ' \n')
      ;;
    1)
      shoff=$(od -An -tu4 -j32 -N4 "$f" | tr -d ' \n')
      shentsize=$(od -An -tu2 -j46 -N2 "$f" | tr -d ' \n')
      shnum=$(od -An -tu2 -j48 -N2 "$f" | tr -d ' \n')
      ;;
    *) return 1 ;;
  esac
  [[ -n "$shoff" && -n "$shentsize" && -n "$shnum" && "$shnum" -gt 0 ]] || return 1
  echo $((shoff + shentsize * shnum))
}

extract_any_payload() {
  local src="$1" dest="$2"

  if [[ -d "$src" ]]; then
    cp -a "$src"/. "$dest/"
  elif [[ "$src" =~ \.(appimage|AppImage)$ ]]; then
    if ! command -v unsquashfs &>/dev/null; then
      echo -e "${RED}[-] unsquashfs (squashfs-tools) required for AppImage${NC}" >&2
      return 1
    fi
    local offset appimg_tmp
    if ! offset=$(appimage_squashfs_offset "$src"); then
      echo -e "${RED}[-] Unsupported AppImage (not a type-2 ELF AppImage)${NC}" >&2
      return 1
    fi
    if [[ "$(hex_at "$src" "$offset" 4)" != "68737173" ]]; then
      echo -e "${RED}[-] No SquashFS payload found in AppImage${NC}" >&2
      return 1
    fi
    appimg_tmp=$(mktemp -d "$TEMP_DIR/appimage.XXXXXX")
    if unsquashfs -no-progress -f -d "$appimg_tmp/squashfs-root" -o "$offset" "$src" >/dev/null 2>&1 \
       && [[ -d "$appimg_tmp/squashfs-root" ]]; then
      cp -a "$appimg_tmp/squashfs-root"/. "$dest/"
      rm -rf "$appimg_tmp"
    else
      rm -rf "$appimg_tmp"
      echo -e "${RED}[-] Failed to extract AppImage${NC}" >&2
      return 1
    fi
  elif [[ "$src" =~ \.deb$ ]]; then
    dpkg-deb -x "$src" "$dest"
  elif [[ "$src" =~ \.rpm$ ]]; then
    if command -v rpm2cpio &>/dev/null; then
      (cd "$dest" && rpm2cpio "$src" | cpio -idm --quiet)
    elif command -v bsdtar &>/dev/null; then
      bsdtar -xf "$src" -C "$dest"
    else
      echo -e "${RED}[-] rpm2cpio or bsdtar required for .rpm${NC}" >&2
      return 1
    fi
  elif [[ "$src" =~ \.zip$ ]]; then
    unzip -q -o "$src" -d "$dest"
  else
    tar -xf "$src" -C "$dest"
  fi
}

is_system_lib() {
  local bname="$1"
  [[ "$bname" =~ ^(ld-linux|ld-musl|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so) ]] && return 0
  [[ "$bname" =~ ^(libGL|libEGL|libGLESv|libdrm|libvulkan|libX11|libXext|libXrender|libXrandr) ]] && return 0
  [[ "$bname" =~ ^(libasound|libpulse|libwayland|libffi|libz\.so|libbz2|liblzma|libnss|libnspr) ]] && return 0
  return 1
}

find_host_loader() {
  local cand
  for cand in \
    /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
    /lib/ld-linux-aarch64.so.1 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
    /lib/ld-linux-armhf.so.3 /lib/arm-linux-gnueabihf/ld-linux-armhf.so.3 \
    /lib/ld-linux.so.2 /lib/i386-linux-gnu/ld-linux.so.2 \
    /lib/ld-linux-riscv64-lp64d.so.1 /lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1 \
    /lib/ld-musl-*.so.1; do
    if [[ -x "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

bundle_libs() {
  local root_dir="$1"
  local bin_path="$2"
  local lib_dest="$root_dir/lib"

  mkdir -p "$lib_dest"
  echo -e "${CYAN}-> Inspecting shared libraries (fat bundle)...${NC}"

  local loader
  if ! loader=$(find_host_loader); then
    echo -e "${YELLOW}[!] No host dynamic loader found, skipping library bundling${NC}" >&2
    return 0
  fi

  local targets=()
  if file -b "$bin_path" 2>/dev/null | grep -q "ELF"; then
    targets+=("$bin_path")
  fi

  while IFS= read -r f; do
    [[ -n "$f" ]] && targets+=("$f")
  done < <(find "$root_dir" -type f -executable 2>/dev/null | while read -r cand; do
    file -b "$cand" 2>/dev/null | grep -q "ELF" && echo "$cand"
  done || true)

  [[ ${#targets[@]} -eq 0 ]] && return 0

  local added=1 pass=0 max_passes=6 t bname lib_file
  while[[ $added -gt 0 && $pass -lt $max_passes ]]; do
    added=0
      pass=$((pass + 1))
      while IFS= read -r lib_file; do
      if [[ -n "$lib_file" && -f "$lib_file" ]];then
        bname=$(basename "$lib_file")
        if ! is_system_lib "$bname"; then
          if [[ ! -f "$lib_dest/$bname" ]]; then
            cp -u -L "$lib_file" "$lib_dest/$bname" 2>/dev/null || true
          if [[ -f "$lib_dest/$bname" ]]; then
            added=$((added + 1))
          fi
        fi
      fi
    fi
  done < <(
  shopt -s nullglob
  local scan_targets=("${targets[@]}" "$lib_dest"/*)
  shopt -u nullglob
    for t in "${scan_targets[@]}"; do
      if [[ -f "$t" ]]; then
        "$loader" --list "$t" 2>/dev/null || true
      fi
    done | grep -oE '/[^ ]+' || true
  )
  done
  return 0
}

lpk_pack() {
  local source_input="$1"
  local raw_name="${2:-}"
  local out_pkg="${3:-}"
  local version_hint="${4:-latest}"

  ensure_default_key || return 1

  local base_clean app_name app_id work_dir target_arch
  base_clean=$(basename "$source_input")
  base_clean="${base_clean%%.*}"
  app_name="${raw_name:-$base_clean}"
  app_name=$(echo "$app_name" | tr -cd 'a-zA-Z0-9._-')
  if [[ -z "$app_name" || "$app_name" == .* ]]; then
    echo -e "${RED}[-] Invalid package name (use letters, digits, '.', '_' or '-')${NC}" >&2
    return 1
  fi
  app_id="io.lpk.${app_name,,}"
  target_arch="$SYS_ARCH"

  [[ -z "$out_pkg" ]] && out_pkg="${app_name}_${target_arch}.lpk"

  if [[ -d "$source_input" && -f "$source_input/meta/manifest.json" && -d "$source_input/root" ]]; then
    echo -e "${CYAN}-> Pre-structured LPK detected → ${BOLD}$out_pkg${NC}"
    validate_manifest "$source_input/meta/manifest.json" || return 1
    rm -f "$out_pkg"
    mksquashfs "$source_input" "$out_pkg" -comp zstd -noappend -reproducible -quiet || return 1
    cmd_sign "$out_pkg" "$DEFAULT_KEY"
    return 0
  fi

  work_dir=$(mktemp -d "${ULPM_TMPDIR:-${TMPDIR:-/tmp}}/ulpm_build_XXXXXX")
  mkdir -p "$work_dir/root" "$work_dir/meta"

  echo -e "${CYAN}-> Extracting payload...${NC}"
  if ! extract_any_payload "$source_input" "$work_dir/root"; then
    rm -rf "$work_dir"
    return 1
  fi

  local entries=("$work_dir/root"/*)
  if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    mv "${entries[0]}"/* "$work_dir/root/" 2>/dev/null || true
    rmdir "${entries[0]}" 2>/dev/null || true
  fi

  local detected_exec="" f fname
  while IFS= read -r f; do
    fname=$(basename "$f")
    if [[ "${fname,,}" =~ ^(${app_name,,}|${base_clean,,})$ ]]; then
      detected_exec=$(realpath --relative-to="$work_dir/root" "$f")
      break
    fi
  done < <(find "$work_dir/root" -maxdepth 4 -type f -executable 2>/dev/null || true)

  if [[ -z "$detected_exec" ]]; then
    while IFS= read -r f; do
        if file -b "$f" 2>/dev/null | grep -q "ELF.*executable"; then
            chmod +x "$f" 2>/dev/null || true
                detected_exec=$(realpath --relative-to="$work_dir/root" "$f")
            break
        fi
    done< <(find "$work_dir/root" -maxdepth 4 -type f 2>/dev/null || true)
  fi

  if [[ -z "$detected_exec" ]]; then
    detected_exec=$(find "$work_dir/root" -maxdepth 3 -type f -executable 2>/dev/null | head -n1 || true)
    [[ -n "$detected_exec" ]] && detected_exec=$(realpath --relative-to="$work_dir/root" "$detected_exec")
  fi

  if [[ -z "$detected_exec" ]]; then
    echo -e "${RED}[-] No executable binary found${NC}" >&2
    rm -rf "$work_dir"
    return 1
  fi

  bundle_libs "$work_dir/root" "$work_dir/root/$detected_exec"

  local best_icon icon_manifest=""
  best_icon=$(find "$work_dir/root" -type f \( -iname "*.png" -o -iname "*.svg" \) 2>/dev/null \
    | grep -iE "512|256|128|logo|icon|app" | head -n1 || true)
  if [[ -n "$best_icon" && -f "$best_icon" ]]; then
    cp -f "$best_icon" "$work_dir/meta/icon.png"
    icon_manifest="meta/icon.png"
  fi

  local is_chromium=false
  if grep -qiE "chromium|electron" "$work_dir/root/$detected_exec" 2>/dev/null || \
     [[ "$detected_exec" =~ (brave|chrome|chromium|electron) ]]; then
    is_chromium=true
  fi

  jq -n \
    --argjson fv "$ULPM_FORMAT_VERSION" \
    --arg id "$app_id" --arg name "$app_name" --arg version "$version_hint" \
    --arg arch "$target_arch" --arg exec "$detected_exec" --arg icon "$icon_manifest" \
    --argjson chromium "$is_chromium" \
    '{format_version:$fv, id:$id, name:$name, version:$version, arch:$arch,
      exec:$exec, icon:$icon, chromium:$chromium, network:true}' \
    > "$work_dir/meta/manifest.json"

  validate_manifest "$work_dir/meta/manifest.json" || { rm -rf "$work_dir"; return 1; }

  echo -e "  ${CYAN}-> Creating SquashFS [${BOLD}$target_arch${NC}${CYAN}] → ${BOLD}$out_pkg${NC}"
  rm -f "$out_pkg"
  if ! mksquashfs "$work_dir" "$out_pkg" -comp zstd -noappend -reproducible -quiet; then
    rm -rf "$work_dir"
    return 1
  fi
  rm -rf "$work_dir"

  cmd_sign "$out_pkg" "$DEFAULT_KEY"
  return 0
}

lpk_pack_from_apt() {
  local pkg_input="${1:-}"
  local app_name_hint="${2:-}"
  local out_pkg="${3:-}"

  if [[ -z "$pkg_input" ]]; then
    echo -e "${RED}[-] Usage: ulpm deb-pack <package|file.deb> [name]${NC}" >&2
    return 1
  fi

  if ! command -v apt-get &>/dev/null || ! command -v apt-cache &>/dev/null; then
    echo -e "${RED}[-] apt-get / apt-cache required${NC}" >&2
    return 1
  fi

  local build_dir deb_dir root_dir
  build_dir=$(mktemp -d "${ULPM_TMPDIR:-${TMPDIR:-/tmp}}/ulpm_apt_XXXXXX")
  deb_dir="$build_dir/debs"
  root_dir="$build_dir/root"
  mkdir -p "$deb_dir" "$root_dir"

  local target_pkg="$pkg_input"
  if [[ -f "$pkg_input" && "$pkg_input" =~ \.deb$ ]]; then
    target_pkg=$(dpkg-deb -f "$pkg_input" Package 2>/dev/null || basename "$pkg_input" .deb)
    cp -f "$pkg_input" "$deb_dir/"
  fi

  local app_name="${app_name_hint:-$target_pkg}"
  echo -e "${BLUE}::${NC} Fetching APT dependencies for '${target_pkg}'..."

  (
    cd "$deb_dir" || exit 1
    [[ ! -f "$pkg_input" ]] && apt-get download "$target_pkg" 2>/dev/null || true
    apt-cache depends --recurse --no-recommends --no-suggests "$target_pkg" 2>/dev/null \
      | grep -E "Depends:" | awk '{print $2}' | grep -v "<" | sort -u \
      | grep -vE "^(libc6|base-files|dpkg|debconf|sensible-utils|init-system-helpers)$" \
      | xargs -r apt-get download 2>/dev/null || true
  )

  local deb
  for deb in "$deb_dir"/*.deb; do
    [[ -f "$deb" ]] && dpkg-deb -x "$deb" "$root_dir"
  done

  find "$root_dir" -type f \( -name "ld-linux*.so*" -o -name "libc.so*" \) -delete 2>/dev/null || true

  local pack_status=0
  lpk_pack "$root_dir" "$app_name" "$out_pkg" || pack_status=$?
  rm -rf "$build_dir"
  return $pack_status
}