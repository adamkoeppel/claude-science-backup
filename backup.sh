#!/bin/bash
# Nightly Claude Science backup (macOS). Default destination is iCloud Drive.
# Installed by install.sh to ~/Library/Application Support/claude-science-backup and run by launchd.
# It never deletes anything, from the source or from the backup. Backups accumulate until you decide otherwise.
# It leaves out the encryption key, login tokens and local TLS keys on purpose; see RESTORE.md.
#
# Overrides (set at install time, or for testing):
#   CSB_SRC    Claude Science data folder       (default ~/.claude-science)
#   CSB_DEST   backup destination folder         (default iCloud Drive/Claude Science Backup)
#   CSB_LOG    log file                          (default ~/Library/Logs/claude-science-backup.log)
#   CSB_SQLITE sqlite3 binary                    (default /usr/bin/sqlite3)
#   CSB_STAMP  run label, normally the date/time (tests only)
set -uo pipefail

SRC="${CSB_SRC:-$HOME/.claude-science}"
DEST="${CSB_DEST:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude Science Backup}"
SQLITE="${CSB_SQLITE:-/usr/bin/sqlite3}"
STAMP="${CSB_STAMP:-$(date +%Y-%m-%d_%H%M)}"
LOG="${CSB_LOG:-$HOME/Library/Logs/claude-science-backup.log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== $STAMP start"

fail() {
  echo "FAILED: $*"
  printf '%s FAILED: %s\n' "$STAMP" "$*" > "$DEST/last-run.txt" 2>/dev/null
  /usr/bin/osascript -e "display notification \"$*\" with title \"Claude Science backup failed\"" >/dev/null 2>&1
  exit 1
}

[ -d "$SRC/orgs" ] || fail "Claude Science data folder not found at $SRC"
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
for org in "$SRC"/orgs/*/; do
  id=$(basename "$org"); db="$org/operon-cli.db"
  [ -f "$db" ] || continue
  SCRATCH="${CSB_SCRATCH:-$HOME/Library/Caches/claude-science-backup}"; mkdir -p "$SCRATCH"; tmp="$SCRATCH/snap-$id.db"
  "$SQLITE" -cmd ".timeout 60000" "$db" ".backup '$tmp'" || fail "database snapshot failed ($id)"
  [ "$("$SQLITE" "$tmp" 'pragma quick_check;')" = "ok" ] || fail "database snapshot failed integrity check ($id)"
  gzip -c "$tmp" > "$DEST/db/$id-$STAMP.db.gz.part" && mv "$DEST/db/$id-$STAMP.db.gz.part" "$DEST/db/$id-$STAMP.db.gz" || fail "could not write database snapshot ($id)"
done

# 2. Mirror everything else. No --delete: files you remove on the Mac stay in the backup.
#    When a file changes, the previous version is moved to previous-versions/<date> instead of being lost.
EXCL=(
  --exclude=/encryption.key --exclude=/.oauth-tokens/ --exclude=/.key-backups/ --exclude=/tls/
  --exclude=/auth-owner.lock --exclude=/operon.lock --exclude='*.sock'
  --exclude=/conda/ --exclude=/bin/ --exclude=/runtime/ --exclude=/r-libs/
  --exclude=operon-cli.db --exclude=operon-cli.db-wal --exclude=operon-cli.db-shm
  --exclude=.venv/ --exclude=.cache/ --exclude=.r-libs/ --exclude=.tmp/ --exclude=__pycache__/
)
RSYNC=/usr/bin/rsync
[ -x "$HOME/.homebrew/bin/rsync" ] && RSYNC="$HOME/.homebrew/bin/rsync"
[ -x /opt/homebrew/bin/rsync ] && RSYNC=/opt/homebrew/bin/rsync
KEEPOLD=()
RSYNC_HELP=$("$RSYNC" --help 2>&1 || true)
if [[ "$RSYNC_HELP" == *--backup-dir* ]]; then
  KEEPOLD=(--backup --backup-dir="$DEST/previous-versions/$STAMP")
else
  echo "note: $RSYNC can't keep previous versions of changed files; run 'brew install rsync' to enable that"
fi
"$RSYNC" -a "${KEEPOLD[@]}" "${EXCL[@]}" "$SRC/" "$DEST/data/"
rc=$?
[ $rc -eq 0 ] || [ $rc -eq 24 ] || fail "file mirror failed (rsync exit $rc)"   # 24 = file vanished mid-copy, harmless

printf '%s OK. Mirror %s, %s database snapshots, total backup %s.\n' "$STAMP" \
  "$(du -sh "$DEST/data" | cut -f1)" "$(ls "$DEST/db" | grep -c '\.db\.gz$')" "$(du -sh "$DEST" | cut -f1)" > "$DEST/last-run.txt"
[ -n "$MANIFEST_NOTE" ] && echo "Note:$MANIFEST_NOTE" >> "$DEST/last-run.txt"
echo "=== $STAMP done"
