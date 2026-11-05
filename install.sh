#!/bin/bash
# Installs the nightly Claude Science backup on macOS. Run once from Terminal, from this folder:
#   bash install.sh
# Optional: choose a different source or destination by setting them on the same line, e.g.
#   CSB_DEST="/Volumes/Backup/Claude Science Backup" bash install.sh
# The installer never deletes anything. Rerun it after updating backup.sh.
set -euo pipefail

[ "$(uname)" = "Darwin" ] || { echo "This installer is for macOS."; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${CSB_SRC:-$HOME/.claude-science}"
DEST="${CSB_DEST:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude Science Backup}"
LOG="$HOME/Library/Logs/claude-science-backup.log"
LABEL=local.claude-science-backup
APPDIR="$HOME/Library/Application Support/claude-science-backup"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -d "$SRC/orgs" ] || { echo "No Claude Science data found at $SRC. Check Settings > Storage > Data location in Claude Science and rerun with CSB_SRC set to that folder."; exit 1; }
mkdir -p "$DEST" || { echo "Cannot create the backup folder $DEST"; exit 1; }
mkdir -p "$APPDIR" "$HOME/Library/LaunchAgents"
cp "$HERE/backup.sh" "$APPDIR/backup.sh"; chmod 755 "$APPDIR/backup.sh"
cp "$HERE/RESTORE.md" "$DEST/RESTORE.md" 2>/dev/null || true

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$APPDIR/backup.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CSB_SRC</key><string>$SRC</string>
    <key>CSB_DEST</key><string>$DEST</string>
  </dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>17</integer></dict>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict></plist>
PL

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Source:      $SRC"
echo "Destination: $DEST"
echo "Running the first backup now. The first one copies everything and can take a while..."
CSB_SRC="$SRC" CSB_DEST="$DEST" /bin/bash "$APPDIR/backup.sh" || true
cat "$DEST/last-run.txt" 2>/dev/null || echo "No last-run.txt was written. See $LOG"
if grep -q "can't keep previous versions" "$LOG" 2>/dev/null; then
  echo "Note: this Mac's rsync can't keep previous versions of changed files. Run 'brew install rsync' to enable that."
fi

echo "Checking that the nightly job can run on its own..."
before=$(stat -f %m "$DEST/last-run.txt" 2>/dev/null || echo 0)
launchctl kickstart -k "gui/$(id -u)/$LABEL"
after=$before
for i in $(seq 1 60); do
  sleep 5
  after=$(stat -f %m "$DEST/last-run.txt" 2>/dev/null || echo 0)
  [ "$after" != "$before" ] && break
done
if [ "$after" != "$before" ] && grep -q OK "$DEST/last-run.txt"; then
  echo "All set. It runs every night at 2:17 AM, or when the Mac next wakes if it was asleep."
else
  echo "The scheduled run didn't finish. See $LOG"
  echo "If it says 'Operation not permitted', add /bin/bash under System Settings >"
  echo "Privacy & Security > Full Disk Access, then run this installer again."
fi
