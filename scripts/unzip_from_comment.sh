#!/usr/bin/env bash
# =============================================================================
# unzip_from_comment.sh
# Downloads, validates, extracts, and splits large files from a list of URLs.
#
# Usage:
#   bash scripts/unzip_from_comment.sh <RUN_ID> <ISSUE_NUMBER> <url1> [url2] ...
#
# Arguments:
#   $1  - GitHub run ID  (used for unique output folder names)
#   $2  - Issue number   (used for output folder names)
#   $3+ - Archive URLs to download
#
# Safety features:
#   - Path-traversal validation before extraction for all formats
#   - Multi-part archive detection (extracts only from part 1)
#   - Per-run unique output folders to avoid accidental overwrites
#   - Split parts keep original extension: video.mp4.part_aa
# =============================================================================
set -Eeuo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
RUN_ID="${1:-unknown}"
ISSUE_NUM="${2:-0}"
shift 2 || true

# Each run writes into a unique subfolder: folder/<issue>-<runid>/
# This is the safe default that prevents accidental overwrites.
RUN_LABEL="issue${ISSUE_NUM}-run${RUN_ID}"
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
# Archives can contain entries like "../../evil.sh" or "/etc/passwd" that,
# when extracted naively, write files outside the intended target directory.
# We list each archive's contents before extraction and reject any entry whose
# resolved path escapes the target directory.

# resolve_path: returns the canonical path without requiring it to exist yet.
# We mimic realpath --no-symlinks by collapsing ".." manually.
resolve_path() {
  local base="$1" entry="$2"
  # Build an absolute candidate path
  local candidate
  candidate="$(cd "$base" && pwd)/${entry}"
  # Collapse ".." segments iteratively
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

# validate_entry: returns 0 (safe) or 1 (unsafe).
# $1 = base extraction directory (absolute)
# $2 = entry path as reported by the archive tool
validate_entry() {
  local base_abs="$1" entry="$2"
  # Absolute entries are always unsafe (e.g. /etc/passwd)
  if [[ "$entry" == /* ]]; then
    return 1
  fi
  # Resolve and check it stays within base
  local resolved
  resolved=$(resolve_path "$base_abs" "$entry")
  if [[ "$resolved" != "$base_abs"* ]]; then
    return 1
  fi
  return 0
}

# validate_archive: lists the archive's entries and checks every path.
# Returns 0 if safe, 1 if any unsafe entry is found.
# $1 = archive file path
# $2 = intended extraction directory (will be created if needed)
validate_archive() {
  local archive="$1" target_dir="$2"
  local base_abs
  base_abs="$(mkdir -p "$target_dir" && cd "$target_dir" && pwd)"
  local found_unsafe=0

  log "  Validating contents of '$(basename "$archive")' against path traversal ..."

  case "$archive" in
    # ── ZIP: 'unzip -l' lists paths cleanly ──────────────────────────────────
    *.zip)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in zip: '$entry'"
          found_unsafe=1
        fi
      done < <(unzip -l "$archive" | awk 'NR>3 && NF>=4{for(i=4;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":"\n")}')
      ;;

    # ── TAR variants: 'tar --list' gives all member paths ────────────────────
    *.tar.gz|*.tgz)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in tar.gz: '$entry'"
          found_unsafe=1
        fi
      done < <(tar --list -zf "$archive" 2>/dev/null)
      ;;
    *.tar.xz)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in tar.xz: '$entry'"
          found_unsafe=1
        fi
      done < <(tar --list -Jf "$archive" 2>/dev/null)
      ;;
    *.tar.bz2)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in tar.bz2: '$entry'"
          found_unsafe=1
        fi
      done < <(tar --list -jf "$archive" 2>/dev/null)
      ;;
    *.tar)
      while IFS= read -r entry; do
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in tar: '$entry'"
          found_unsafe=1
        fi
      done < <(tar --list -f "$archive" 2>/dev/null)
      ;;

    # ── 7z: '7z l' with -slt gives full paths ────────────────────────────────
    *.7z|*.7z.[0-9]*)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in 7z: '$entry'"
          found_unsafe=1
        fi
      done < <(7z l -slt "$archive" 2>/dev/null | grep '^Path = ' | sed 's/^Path = //')
      ;;

    # ── RAR: 'unrar l' or 'unrar vt' lists paths ─────────────────────────────
    # NOTE: unrar path listing output varies by version. We use 'unrar vt'
    # which prints "Name: <path>" lines reliably on most versions.
    # For multi-part RAR only the first part needs listing.
    *.rar|*.part[0-9]*.rar)
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if ! validate_entry "$base_abs" "$entry"; then
          warn "    UNSAFE entry in rar: '$entry'"
          found_unsafe=1
        fi
      done < <(unrar vt "$archive" 2>/dev/null | grep -E '^[[:space:]]+Name: ' | sed 's/^[[:space:]]*Name: //')
      ;;

    *)
      # Unknown format — we cannot validate, so we warn and allow with logging.
      # LIMITATION: No entry-level validation is possible for this format.
      warn "  Cannot validate path safety for unknown format: '$(basename "$archive")'"
      warn "  Proceeding with extraction — monitor outputs carefully."
      ;;
  esac

  if (( found_unsafe == 1 )); then
    err "  Archive '$(basename "$archive")' contains unsafe paths. SKIPPING extraction."
    return 1
  fi

  log "  Validation passed for '$(basename "$archive")'"
  return 0
}

# =============================================================================
# MULTI-PART ARCHIVE DETECTION
# =============================================================================
# We group downloaded files into archive sets, then extract only once per set
# starting from the correct first part. This prevents double-extraction errors
# and incorrect output folders.
#
# Supported multi-part patterns:
#   movie.part1.rar, movie.part2.rar  -> base: movie, primary: movie.part1.rar
#   archive.7z.001, archive.7z.002    -> base: archive, primary: archive.7z.001
#   Single-file archives              -> base derived from filename

# derive_base_name: strips archive extension and part suffix from a filename.
derive_base_name() {
  local fname="$1"
  # multi-part RAR: movie.part01.rar  or  movie.part1.rar
  if [[ "$fname" =~ \.part[0-9]+\.rar$ ]]; then
    echo "${fname%%.part[0-9]*.rar}"
    return
  fi
  # multi-part 7z: archive.7z.001
  if [[ "$fname" =~ \.7z\.[0-9]+$ ]]; then
    echo "${fname%%.7z.*}"
    return
  fi
  # Single extensions
  echo "$fname" | sed -E 's/\.(tar\.gz|tar\.xz|tar\.bz2|tgz|tar|zip|rar|7z)$//'
}

# is_first_part: returns 0 if this file is the first (or only) part of a set.
is_first_part() {
  local fname="$1"
  # RAR multi-part: part1 or part01 is the first
  if [[ "$fname" =~ \.part([0-9]+)\.rar$ ]]; then
    local n="${BASH_REMATCH[1]#0}"  # strip leading zeros
    [[ "$n" == "1" ]] && return 0 || return 1
  fi
  # 7z split: .7z.001 is the first
  if [[ "$fname" =~ \.7z\.([0-9]+)$ ]]; then
    local n="${BASH_REMATCH[1]#0}"
    [[ "$n" == "1" ]] && return 0 || return 1
  fi
  # Everything else is treated as standalone / first part
  return 0
}

# Group downloaded files by base name.
# Build associative array: base_name -> primary_file
declare -A BASE_TO_PRIMARY
declare -A BASE_HAS_FIRST_PART

for filepath in "${ALL_FILES[@]}"; do
  fname="$(basename "$filepath")"
  base=$(derive_base_name "$fname")
  # Only mark as primary if this is the first part (or standalone)
  if is_first_part "$fname"; then
    BASE_TO_PRIMARY["$base"]="$filepath"
    BASE_HAS_FIRST_PART["$base"]="yes"
  else
    # Register base even if not first part, so we can report missing-first-part
    if [[ -z "${BASE_TO_PRIMARY[$base]+x}" ]]; then
      BASE_TO_PRIMARY["$base"]="$filepath"   # placeholder, flagged below
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

  # If multi-part set but we don't have part 1, skip with clear error
  if [[ "$has_first" == "no" ]]; then
    err "First part of archive set '$base' is missing. Cannot extract without part 1. Skipping."
    continue
  fi

  EXTRACT_DIR="$EXTRACT_BASE/$base"

  # Duplicate-run safety: if this exact extract dir already exists, skip
  # (The per-run RUN_LABEL prefix already makes this unlikely, but guard anyway)
  if [[ -d "$EXTRACT_DIR" ]] && [[ -n "$(ls -A "$EXTRACT_DIR" 2>/dev/null)" ]]; then
    log "Output directory '$EXTRACT_DIR' already exists and is non-empty. Skipping to avoid overwrite."
    log "(This run's unique label is '$RUN_LABEL' — if you see this, something unexpected happened.)"
    continue
  fi

  mkdir -p "$EXTRACT_DIR"
  log "Extracting into '$EXTRACT_DIR/' ..."

  # ── Validate before extracting ──────────────────────────────────────────────
  if ! validate_archive "$primary" "$EXTRACT_DIR"; then
    warn "Skipping extraction of '$base' due to safety validation failure."
    rmdir "$EXTRACT_DIR" 2>/dev/null || true
    continue
  fi

  # ── Extract ─────────────────────────────────────────────────────────────────
  case "$primary" in
    *.tar.gz|*.tgz)
      log "Format: tar.gz"
      tar -xzf "$primary" -C "$EXTRACT_DIR"
      ;;
    *.tar.xz)
      log "Format: tar.xz"
      tar -xJf "$primary" -C "$EXTRACT_DIR"
      ;;
    *.tar.bz2)
      log "Format: tar.bz2"
      tar -xjf "$primary" -C "$EXTRACT_DIR"
      ;;
    *.tar)
      log "Format: tar"
      tar -xf "$primary" -C "$EXTRACT_DIR"
      ;;
    *.zip)
      log "Format: zip"
      unzip -o "$primary" -d "$EXTRACT_DIR"
      ;;
    *.rar|*.part[0-9]*.rar)
      log "Format: rar (may be multi-part; unrar will auto-join parts in same folder)"
      # unrar auto-discovers all parts when pointed at part1
      unrar x -o+ "$primary" "$EXTRACT_DIR/"
      ;;
    *.7z|*.7z.[0-9]*)
      log "Format: 7z (may be multi-part; 7z auto-joins .001 .002 etc.)"
      7z x "$primary" -o"$EXTRACT_DIR"
      ;;
    *)
      warn "Unsupported archive format for '$(basename "$primary")'. Skipping extraction."
      rmdir "$EXTRACT_DIR" 2>/dev/null || true
      continue
      ;;
  esac

  log "Extraction complete for set '$base'."

  # =============================================================================
  # SPLIT FILES LARGER THAN 90 MB
  # =============================================================================
  # GitHub enforces a 100 MB per-file hard limit; we split at 90 MB to leave
  # headroom. Split parts retain the original filename and extension:
  #   video.mp4  ->  video.mp4.part_aa  video.mp4.part_ab  ...
  # This keeps the original extension visible, making parts easy to identify.

  log "Checking for files > 90 MB in '$EXTRACT_DIR/' ..."
  SPLIT_COUNT=0

  # We use a process-substitution loop to keep variable scope for SPLIT_COUNT.
  while IFS= read -r -d '' filepath; do
    filesize=$(stat -c%s "$filepath")
    if (( filesize > SPLIT_SIZE_BYTES )); then
      size_mb=$(( filesize / 1024 / 1024 ))
      log "  Large file: $(basename "$filepath") (${size_mb} MB) — splitting ..."

      # Prefix for split output:  <original_path>.part_
      # Result:  video.mp4.part_aa  video.mp4.part_ab  etc.
      split \
        --bytes="${SPLIT_SIZE_BYTES}" \
        --suffix-length=2 \
        --numeric-suffixes=0 \
        "$filepath" \
        "${filepath}.part_"

      # Count how many parts were created
      part_count=$(find "$(dirname "$filepath")" -maxdepth 1 \
        -name "$(basename "$filepath").part_*" | wc -l)
      log "    -> Split into ${part_count} part(s). Removing original."
      rm -f "$filepath"
      (( SPLIT_COUNT++ )) || true
    fi
  done < <(find "$EXTRACT_DIR" -type f -print0)

  if (( SPLIT_COUNT == 0 )); then
    log "  No files required splitting."
  else
    log "  ${SPLIT_COUNT} file(s) were split."
  fi

done  # end extraction loop

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
