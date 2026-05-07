#!/usr/bin/env bash
# =============================================================================
# unzip_from_comment.sh
# Downloads, extracts, and splits large files from a list of URLs.
# Usage: bash scripts/unzip_from_comment.sh <url1> [url2] [url3] ...
# =============================================================================
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
DOWNLOAD_DIR="folder"
EXTRACT_BASE="extracted"
SPLIT_SIZE_BYTES=$((90 * 1024 * 1024))   # 90 MB in bytes

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_BASE"

# ── 1. Parse URLs from arguments ─────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  err "No URLs provided."
  exit 1
fi

URLS=("$@")
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

# ── 3. Determine archive base name and extract ────────────────────────────────
# Gather all downloaded filenames (sorted so part1 comes before part2, etc.)
mapfile -t DOWNLOADED < <(ls "$DOWNLOAD_DIR/")

if [[ ${#DOWNLOADED[@]} -eq 0 ]]; then
  err "No files found in '$DOWNLOAD_DIR/' after download."
  exit 1
fi

log "Downloaded files: ${DOWNLOADED[*]}"

# Determine the "representative" archive file (first URL's filename)
FIRST_URL="${URLS[0]}"
FIRST_FILE="$(basename "${FIRST_URL%%\?*}")"

# Derive base name by stripping common archive extensions and part suffixes
# e.g. movie.part1.rar -> movie
#       archive.tar.gz -> archive
#       archive.zip    -> archive
BASE_NAME="$FIRST_FILE"
for ext in ".part"[0-9]*.rar ".part"[0-9]*.7z; do
  if [[ "$FIRST_FILE" == *$ext ]]; then
    BASE_NAME="${FIRST_FILE%$ext}"
    break
  fi
done
# Strip multi-part .partN.rar pattern properly
if [[ "$BASE_NAME" == "$FIRST_FILE" ]]; then
  BASE_NAME=$(echo "$FIRST_FILE" | sed -E 's/\.part[0-9]+\.(rar|7z|zip)$//')
fi
# Strip remaining single-level extensions
BASE_NAME=$(echo "$BASE_NAME" | sed -E 's/\.(tar\.gz|tar\.xz|tar\.bz2|tgz|tar|zip|rar|7z)$//')

EXTRACT_DIR="$EXTRACT_BASE/$BASE_NAME"
mkdir -p "$EXTRACT_DIR"
log "Extracting into '$EXTRACT_DIR/' ..."

# Pick the primary archive file to pass to the extractor
PRIMARY="$DOWNLOAD_DIR/$FIRST_FILE"

if [[ ! -f "$PRIMARY" ]]; then
  # Fallback: just use the first file in the folder
  PRIMARY="$DOWNLOAD_DIR/${DOWNLOADED[0]}"
fi

# Detect format and extract
case "$PRIMARY" in
  *.tar.gz|*.tgz)
    log "Format: tar.gz"
    tar -xzf "$PRIMARY" -C "$EXTRACT_DIR"
    ;;
  *.tar.xz)
    log "Format: tar.xz"
    tar -xJf "$PRIMARY" -C "$EXTRACT_DIR"
    ;;
  *.tar.bz2)
    log "Format: tar.bz2"
    tar -xjf "$PRIMARY" -C "$EXTRACT_DIR"
    ;;
  *.tar)
    log "Format: tar"
    tar -xf "$PRIMARY" -C "$EXTRACT_DIR"
    ;;
  *.zip)
    log "Format: zip"
    unzip -o "$PRIMARY" -d "$EXTRACT_DIR"
    ;;
  *.rar|*.part[0-9]*.rar)
    log "Format: rar (may be multi-part)"
    # unrar will automatically join all parts if they're in the same folder
    unrar x -o+ "$PRIMARY" "$EXTRACT_DIR/"
    ;;
  *.7z)
    log "Format: 7z"
    7z x "$PRIMARY" -o"$EXTRACT_DIR"
    ;;
  *)
    warn "Unsupported archive format for '$PRIMARY'. Skipping extraction."
    ;;
esac

log "Extraction complete."

# ── 4. Split files larger than 90 MB ─────────────────────────────────────────
log "Checking for files larger than 90 MB in '$EXTRACT_DIR/' ..."
find "$EXTRACT_DIR" -type f | while read -r filepath; do
  filesize=$(stat -c%s "$filepath")
  if (( filesize > SPLIT_SIZE_BYTES )); then
    log "  Large file found: $filepath ($(( filesize / 1024 / 1024 )) MB) — splitting..."
    split \
      --bytes="${SPLIT_SIZE_BYTES}" \
      --suffix-length=2 \
      --additional-suffix="" \
      "$filepath" \
      "${filepath}.part_"
    log "    Split complete. Removing original: $filepath"
    rm -f "$filepath"
  fi
done

log "All done. Contents of '$EXTRACT_DIR/':"
find "$EXTRACT_DIR" -type f | sort
