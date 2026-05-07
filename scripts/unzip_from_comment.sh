#!/usr/bin/env bash
# =============================================================================
# unzip_from_comment.sh
# Downloads, validates, extracts, and splits large files from a list of URLs.
#
# Usage:
#   bash scripts/unzip_from_comment.sh <RUN_LABEL> <url1> [url2] ...
#
# Arguments:
#   $1  - RUN_LABEL  (e.g. "issue42-run-123456789") — used for unique folder names
#   $2+ - Archive URLs to download
#
# Safety features:
#   - Path-traversal validation before extraction for all formats
#   - Multi-part archive detection (extracts only from part 1)
#   - Per-run unique output folders to avoid accidental overwrites
#   - Split parts keep original extension: video.mp4.part_aa
# =============================================================================
set -Eeuo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
RUN_LABEL="${1:-unknown}"
shift || true

DOWNLOAD_DIR="folder/${RUN_LABEL}"
EXTRACT_BASE="extracted/${RUN_LABEL}"
SPLIT_SIZE_BYTES=$((90 * 1024 * 1024))   # 90 MB in bytes

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_BASE"

# ── 1. Parse URLs from arguments ──────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  err "No URLs provided."
  exit 1
fi

URLS=("$@")
log "Run label   : $RUN_LABEL"
log "Download dir: $DOWNLOAD_DIR"
log "Extract base: $EXTRACT_BASE"
log "Received ${#URLS[@]} URL(s)."

# ── 2. Download files with aria2c ─────────────────────────────────────────────
log "Downloading files into '$DOWNLOAD_DIR/' ..."
for url in "${URLS[@]}"; do
  log "  Downloading: $url"
  aria2c \
    --dir="$DOWNLOAD_DIR" \
    --file-allocation=none \
    --continue=true \
    --max-connection-per-server=4 \
    --split=4 \
    --retry-wait=3 \
    --max-tries=5 \
    "$url"
done
log "Download complete."

# ── 3. Collect downloaded files ───────────────────────────────────────────────
mapfile -t ALL_FILES < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f | sort)

if [[ ${#ALL_FILES[@]} -eq 0 ]]; then
  err "No files found in '$DOWNLOAD_DIR/' after download."
  exit 1
fi

log "Downloaded files:"
for f in "${ALL_FILES[@]}"; do log "  $f"; done

# =============================================================================
# PATH-TRAVERSAL VALIDATION
# =============================================================================
resolve_path() {
  local base="$1" entry="$2"
  local candidate
  candidate="$(cd "$base" && pwd)/${entry}"
  local result=""
  local IFS='/'
  local -a parts
  read -ra parts <<< "$candidate"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|'.')  ;;
      '..')    result="${result%/*}" ;;
      *)       result="${result}/${part}" ;;
    esac
  done
  echo "${result:-/}"
}

validate_entry() {
  local base_abs="$1" entry="$2"
  [[ "$entry" == /* ]] && return 1
  local resolved
  resolved=$(resolve_path "$base_abs" "$entry")
  [[ "$resolved" == "$base_abs"* ]] && return 0 || return 1
}

validate_archive() {
  local archive="$1" target_dir="$2"
  local base_abs
  base_abs="$(mkdir -p "$target_dir" && cd "$target_dir" && pwd)"
  local found_unsafe=0

  log "  Validating '$(basename "$archive")' for path traversal ..."

  case "$archive" in
    *.zip)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE zip entry: '$entry'"
          found_unsafe=1
        fi
      done < <(unzip -l "$archive" | awk 'NR>3 && NF>=4{for(i=4;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":"\n")}')
      ;;
    *.tar.gz|*.tgz)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE tar.gz entry: '$entry'"; found_unsafe=1
        fi
      done < <(tar --list -zf "$archive" 2>/dev/null)
      ;;
    *.tar.xz)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE tar.xz entry: '$entry'"; found_unsafe=1
        fi
      done < <(tar --list -Jf "$archive" 2>/dev/null)
      ;;
    *.tar.bz2)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE tar.bz2 entry: '$entry'"; found_unsafe=1
        fi
      done < <(tar --list -jf "$archive" 2>/dev/null)
      ;;
    *.tar)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE tar entry: '$entry'"; found_unsafe=1
        fi
      done < <(tar --list -f "$archive" 2>/dev/null)
      ;;
    *.7z|*.7z.[0-9]*)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE 7z entry: '$entry'"; found_unsafe=1
        fi
      done < <(7z l -slt "$archive" 2>/dev/null | grep '^Path = ' | sed 's/^Path = //')
      ;;
    *.rar|*.part[0-9]*.rar)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE rar entry: '$entry'"; found_unsafe=1
        fi
      done < <(unrar vt "$archive" 2>/dev/null | grep -E '^[[:space:]]+Name: ' | sed 's/^[[:space:]]*Name: //')
      ;;
    *)
      warn "  Cannot validate unknown format: '$(basename "$archive")' — proceeding with caution."
      ;;
  esac

  if (( found_unsafe == 1 )); then
    err "  UNSAFE archive — skipping: $(basename "$archive")"
    return 1
  fi
  log "  Validation passed."
  return 0
}

# =============================================================================
# MULTI-PART ARCHIVE DETECTION
# =============================================================================
derive_base_name() {
  local fname="$1"
  if [[ "$fname" =~ \.part[0-9]+\.rar$ ]]; then
    echo "${fname%%.part[0-9]*.rar}"; return
  fi
  if [[ "$fname" =~ \.7z\.[0-9]+$ ]]; then
    echo "${fname%%.7z.*}"; return
  fi
  echo "$fname" | sed -E 's/\.(tar\.gz|tar\.xz|tar\.bz2|tgz|tar|zip|rar|7z)$//'
}

is_first_part() {
  local fname="$1"
  if [[ "$fname" =~ \.part([0-9]+)\.rar$ ]]; then
    local n
    n=$(( 10#${BASH_REMATCH[1]} ))
    [[ "$n" -eq 1 ]] && return 0 || return 1
  fi
  if [[ "$fname" =~ \.7z\.([0-9]+)$ ]]; then
    local n
    n=$(( 10#${BASH_REMATCH[1]} ))
    [[ "$n" -eq 1 ]] && return 0 || return 1
  fi
  return 0
}

declare -A BASE_TO_PRIMARY
declare -A BASE_HAS_FIRST_PART

for filepath in "${ALL_FILES[@]}"; do
  fname="$(basename "$filepath")"
  base=$(derive_base_name "$fname")
  if is_first_part "$fname"; then
    BASE_TO_PRIMARY["$base"]="$filepath"
    BASE_HAS_FIRST_PART["$base"]="yes"
  else
    if [[ -z "${BASE_TO_PRIMARY[$base]+x}" ]]; then
      BASE_TO_PRIMARY["$base"]="$filepath"
      BASE_HAS_FIRST_PART["$base"]="no"
    fi
  fi
done

log "Detected ${#BASE_TO_PRIMARY[@]} archive set(s)."

# =============================================================================
# EXTRACTION LOOP
# =============================================================================
for base in "${!BASE_TO_PRIMARY[@]}"; do
  primary="${BASE_TO_PRIMARY[$base]}"
  has_first="${BASE_HAS_FIRST_PART[$base]:-no}"

  log "---"
  log "Archive set : $base"
  log "Primary file: $(basename "$primary")"

  if [[ "$has_first" == "no" ]]; then
    err "First part of '$base' is missing. Cannot extract without part 1. Skipping."
    continue
  fi

  EXTRACT_DIR="$EXTRACT_BASE/$base"
  mkdir -p "$EXTRACT_DIR"

  if ! validate_archive "$primary" "$EXTRACT_DIR"; then
    warn "Skipping '$base' due to safety validation failure."
    rmdir "$EXTRACT_DIR" 2>/dev/null || true
    continue
  fi

  case "$primary" in
    *.tar.gz|*.tgz)  tar -xzf "$primary" -C "$EXTRACT_DIR" ;;
    *.tar.xz)         tar -xJf "$primary" -C "$EXTRACT_DIR" ;;
    *.tar.bz2)        tar -xjf "$primary" -C "$EXTRACT_DIR" ;;
    *.tar)            tar -xf  "$primary" -C "$EXTRACT_DIR" ;;
    *.zip)            unzip -o "$primary" -d "$EXTRACT_DIR" ;;
    *.rar|*.part[0-9]*.rar)
      unrar x -o+ "$primary" "$EXTRACT_DIR/" ;;
    *.7z|*.7z.[0-9]*)
      7z x "$primary" -o"$EXTRACT_DIR" ;;
    *)
      warn "Unsupported archive format: $(basename "$primary"). Skipping."
      rmdir "$EXTRACT_DIR" 2>/dev/null || true
      continue
      ;;
  esac

  log "Extraction complete for '$base'."

  # ── Split files > 90 MB ────────────────────────────────────────────────────
  log "Checking for files > 90 MB in '$EXTRACT_DIR/' ..."
  SPLIT_COUNT=0

  while IFS= read -r -d '' filepath; do
    filesize=$(stat -c%s "$filepath")
    if (( filesize > SPLIT_SIZE_BYTES )); then
      size_mb=$(( filesize / 1024 / 1024 ))
      log "  Large file: $(basename "$filepath") (${size_mb} MB) — splitting ..."
      split \
        --bytes="${SPLIT_SIZE_BYTES}" \
        --suffix-length=2 \
        --numeric-suffixes=0 \
        "$filepath" \
        "${filepath}.part_"
      part_count=$(find "$(dirname "$filepath")" -maxdepth 1 \
        -name "$(basename "$filepath").part_*" | wc -l | xargs)
      log "    Created ${part_count} part(s). Removing original."
      rm -f "$filepath"
      (( SPLIT_COUNT++ )) || true
    fi
  done < <(find "$EXTRACT_DIR" -type f -print0)

  if (( SPLIT_COUNT == 0 )); then
    log "  No files required splitting."
  else
    log "  ${SPLIT_COUNT} file(s) were split."
  fi

done

# ── Final summary ─────────────────────────────────────────────────────────────
log "=== Final file listing ==="
log "Downloads ($DOWNLOAD_DIR):"
find "$DOWNLOAD_DIR" -type f | sort | while read -r f; do
  size=$(stat -c%s "$f")
  log "  $f  ($(( size / 1024 )) KB)"
done

log "Extracted ($EXTRACT_BASE):"
find "$EXTRACT_BASE" -type f | sort | while read -r f; do
  size=$(stat -c%s "$f")
  log "  $f  ($(( size / 1024 )) KB)"
done

log "=== All done. Run label: $RUN_LABEL ==="
