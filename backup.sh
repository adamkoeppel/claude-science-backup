#!/bin/bash
# Nightly Claude Science backup (macOS). Default destination is iCloud Drive.
# Installed by install.sh to ~/Library/Application Support/claude-science-backup and run by launchd.
# It never deletes anything, from the source or from the backup. Backups accumulate until you decide otherwise.
# It leaves out the encryption key, login tokens and local TLS keys on purpose; see RESTORE.md.
#
# Claude Science keeps two kinds of folder:
#   - the default folder (~/.claude-science): settings, login tokens, the shared software environment
#   - the data folder: conversations, artifacts, workspaces (orgs/<id>/). This is the default folder
#     unless config.toml sets data_dir, in which case the script follows it.
# On a Mac where Claude Science opens in its own window, it also keeps window settings and unsent
# drafts in ~/Library/Application Support/Claude Science, which is backed up too.
#
# Overrides (set at install time, or for testing):
#   CSB_SRC       Claude Science default folder   (default ~/.claude-science)
#   CSB_DATA_DIR  Claude Science data folder      (default: data_dir from config.toml, else CSB_SRC)
#   CSB_APPWIN    app-window support folder       (default ~/Library/Application Support/Claude Science)
#   CSB_DEST      backup destination folder       (default iCloud Drive/Claude Science Backup)
#   CSB_LOG       log file                        (default ~/Library/Logs/claude-science-backup.log)
#   CSB_SQLITE    sqlite3 binary                  (default /usr/bin/sqlite3)
#   CSB_RSYNC     rsync binary (tests only)
#   CSB_STAMP     run label, normally the date/time (tests only)
#   CSB_PRINT_PATHS=1  print the resolved folders and exit without backing anything up
set -uo pipefail

SRC="${CSB_SRC:-$HOME/.claude-science}"
DEST="${CSB_DEST:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude Science Backup}"
APPWIN="${CSB_APPWIN:-$HOME/Library/Application Support/Claude Science}"
SQLITE="${CSB_SQLITE:-/usr/bin/sqlite3}"

# Find the data folder. data_dir is a top-level key in config.toml, before any [section].
config_data_dir() {
  local cfg="$SRC/config.toml"
  [ -f "$cfg" ] || return 0
  awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*data_dir[[:space:]]*=/ {
      v = $0
      sub(/^[^=]*=[[:space:]]*/, "", v)
      if (v ~ /^"/)      { sub(/^"/, "", v); sub(/".*$/, "", v) }
      else if (v ~ /^'\''/) { sub(/^'\''/, "", v); sub(/'\''.*$/, "", v) }
      else               { sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]+$/, "", v) }
      print v; exit
    }' "$cfg"
}
DATA="${CSB_DATA_DIR:-$(config_data_dir)}"
DATA="${DATA:-$SRC}"
case "$DATA" in "~"|"~/"*) DATA="$HOME${DATA#\~}" ;; esac
SEPARATE_DATA=0
[ "${DATA%/}" != "${SRC%/}" ] && SEPARATE_DATA=1

if [ "${CSB_PRINT_PATHS:-0}" = 1 ]; then
  echo "default folder: $SRC"
  echo "data folder:    $DATA"
  echo "app window:     $APPWIN$( [ -d "$APPWIN" ] || echo ' (not present)')"
  echo "destination:    $DEST"
  exit 0
fi

STAMP="${CSB_STAMP:-$(date +%Y-%m-%d_%H%M)}"
LOG="${CSB_LOG:-$HOME/Library/Logs/claude-science-backup.log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $STAMP start (default folder $SRC, data folder $DATA)"

fail() {
  echo "FAILED: $*"
  printf '%s FAILED: %s\n' "$STAMP" "$*" > "$DEST/last-run.txt" 2>/dev/null
  /usr/bin/osascript -e "display notification \"$*\" with title \"Claude Science backup failed\"" >/dev/null 2>&1
  exit 1
}

case "$DATA" in /*) ;; *) fail "data_dir in config.toml is not an absolute path ($DATA); set CSB_DATA_DIR and reinstall" ;; esac
[ -d "$SRC" ] || fail "Claude Science folder not found at $SRC"
[ -d "$DATA/orgs" ] || fail "Claude Science data not found at $DATA (no orgs folder)"
mkdir -p "$DEST/data" "$DEST/db" "$DEST/previous-versions" || fail "cannot write to the backup folder $DEST"

# 0. Software manifest: a record of each conda environment, so it can be rebuilt after a loss.
#    The environments themselves are not copied. One small dated folder per night.
MAN="$DEST/software-manifest/$STAMP"; mkdir -p "$MAN" || fail "cannot write software manifest"
MANIFEST_NOTE=""
ls "$SRC/runtime" > "$MAN/claude-science-version.txt" 2>/dev/null
MM="$SRC/conda/bin/micromamba"
for env in "$SRC"/conda/envs/*/; do
  name=$(basename "$env")
  [ -d "$env/conda-meta" ] || continue
  cp "$env/conda-meta/history" "$MAN/$name.history.txt" 2>/dev/null
  if [ -x "$MM" ]; then
    "$MM" -r "$SRC/conda" env export -p "$env" > "$MAN/$name.yml" 2>/dev/null || MANIFEST_NOTE=" Manifest export failed for $name."
    "$MM" -r "$SRC/conda" env export -p "$env" --explicit > "$MAN/$name.explicit.txt" 2>/dev/null || MANIFEST_NOTE=" Manifest export failed for $name."
  else
    MANIFEST_NOTE=" micromamba not found; manifest has install histories only."
  fi
  [ -x "$env/bin/python" ] && "$env/bin/python" -m pip list --format=freeze > "$MAN/$name.pip.txt" 2>/dev/null
  [ -x "$env/bin/Rscript" ] && "$env/bin/Rscript" -e 'ip <- installed.packages()[, c("Package","Version")]; write.csv(ip, row.names = FALSE)' > "$MAN/$name.R-packages.csv" 2>/dev/null
done
[ -n "$MANIFEST_NOTE" ] && echo "note:$MANIFEST_NOTE"

# 1. A dated, consistent database snapshot each night (safe while the app is running), gzipped.
#    The snapshot is built in one scratch file that is simply overwritten each night.
for org in "$DATA"/orgs/*/; do
  id=$(basename "$org"); db="$org/operon-cli.db"
  [ -f "$db" ] || continue
  SCRATCH="${CSB_SCRATCH:-$HOME/Library/Caches/claude-science-backup}"; mkdir -p "$SCRATCH"; tmp="$SCRATCH/snap-$id.db"
  "$SQLITE" -cmd ".timeout 60000" "$db" ".backup '$tmp'" || fail "database snapshot failed ($id)"
  [ "$("$SQLITE" "$tmp" 'pragma quick_check;')" = "ok" ] || fail "database snapshot failed integrity check ($id)"
  gzip -c "$tmp" > "$DEST/db/$id-$STAMP.db.gz.part" && mv "$DEST/db/$id-$STAMP.db.gz.part" "$DEST/db/$id-$STAMP.db.gz" || fail "could not write database snapshot ($id)"
done

# 2. Mirror the folders. No --delete: files you remove on the Mac stay in the backup.
#    When a file changes, the previous version is moved to previous-versions/<date>/<part> instead of being lost.
EXCL=(
  --exclude=/encryption.key --exclude=/.oauth-tokens/ --exclude=/.key-backups/ --exclude=/tls/
  --exclude=/auth-owner.lock --exclude=/operon.lock --exclude='*.sock'
  --exclude=/conda/ --exclude=/bin/ --exclude=/runtime/ --exclude=/r-libs/
  --exclude=operon-cli.db --exclude=operon-cli.db-wal --exclude=operon-cli.db-shm
  --exclude=.venv/ --exclude=.cache/ --exclude=.r-libs/ --exclude=.tmp/ --exclude=__pycache__/
)
# The app-window folder is a standard desktop-app profile. Caches, crash dumps and cookies are left out.
APPWIN_EXCL=(
  --exclude=Cache/ --exclude='Code Cache/' --exclude=GPUCache/ --exclude=DawnCache/ --exclude=DawnGraphiteCache/
  --exclude=DawnWebGPUCache/ --exclude=ShaderCache/ --exclude=GrShaderCache/ --exclude=Crashpad/
  --exclude='Cookies' --exclude='Cookies-journal' --exclude='Network/Cookies*' --exclude='*.sock' --exclude=SingletonLock
  --exclude=SingletonSocket --exclude=SingletonCookie
)
RSYNC=/usr/bin/rsync
[ -x "$HOME/.homebrew/bin/rsync" ] && RSYNC="$HOME/.homebrew/bin/rsync"
[ -x /opt/homebrew/bin/rsync ] && RSYNC=/opt/homebrew/bin/rsync
RSYNC="${CSB_RSYNC:-$RSYNC}"
RSYNC_HELP=$("$RSYNC" --help 2>&1 || true)
KEEPS_OLD=0
if [[ "$RSYNC_HELP" == *--backup-dir* ]]; then
  KEEPS_OLD=1
else
  echo "note: $RSYNC can't keep previous versions of changed files; run 'brew install rsync' to enable that"
fi

mirror() {  # mirror <source> <part name> <exclusion set: main|appwin>
  # Written for macOS's bash 3.2: no namerefs, and no expanding empty arrays under set -u.
  local from="$1" part="$2" set="$3" rc
  mkdir -p "$DEST/$part" || fail "cannot write $DEST/$part"
  if [ "$set" = appwin ]; then set -- "${APPWIN_EXCL[@]}"; else set -- "${EXCL[@]}"; fi
  [ $KEEPS_OLD = 1 ] && set -- --backup --backup-dir="$DEST/previous-versions/$STAMP/$part" "$@"
  "$RSYNC" -a "$@" "$from/" "$DEST/$part/"
  rc=$?
  [ $rc -eq 0 ] || [ $rc -eq 24 ] || fail "file mirror of $part failed (rsync exit $rc)"   # 24 = file vanished mid-copy, harmless
}

mirror "$DATA" data main
[ $SEPARATE_DATA = 1 ] && mirror "$SRC" default-folder main
[ -d "$APPWIN" ] && mirror "$APPWIN" app-window appwin

printf '%s OK. Data mirror %s, %s database snapshots, total backup %s.\n' "$STAMP" \
  "$(du -sh "$DEST/data" | cut -f1)" "$(ls "$DEST/db" | grep -c '\.db\.gz$')" "$(du -sh "$DEST" | cut -f1)" > "$DEST/last-run.txt"
[ -n "$MANIFEST_NOTE" ] && echo "Note:$MANIFEST_NOTE" >> "$DEST/last-run.txt"
echo "=== $STAMP done"
