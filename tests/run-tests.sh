#!/bin/bash
# Self-test for backup.sh. Builds fake Claude Science folders in a new temporary
# directory, runs the backup against them, and checks the results.
# It never touches your real Claude Science data or your real backup folder,
# and it deletes nothing (the temporary directory is left for you to inspect).
# Needs: bash, rsync, sqlite3, gzip. On macOS it runs the backup with /bin/bash,
# the same shell launchd uses for the nightly job.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/csb-test.XXXXXX")
SQL="${CSB_SQLITE:-$(command -v sqlite3)}"
[ -x "$SQL" ] || { echo "sqlite3 not found"; exit 1; }
if [ -n "${CSB_BASH:-}" ]; then SH="$CSB_BASH"; elif [ "$(uname)" = Darwin ]; then SH=/bin/bash; else SH=bash; fi
echo "Testing with $("$SH" -c 'echo bash $BASH_VERSION')"
pass=0; failn=0
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; failn=$((failn+1)); fi; }

make_default_folder() {  # make_default_folder <dir>
  mkdir -p "$1/conda/envs/demo/conda-meta" "$1/.oauth-tokens" "$1/tls" "$1/runtime/0.0.0-test"
  echo secret > "$1/encryption.key"; echo token > "$1/.oauth-tokens/a.enc"; echo cert > "$1/tls/c.pem"
  echo pkgs > "$1/conda/envs/demo/x"; echo '# cmd: create -p demo python=3.12' > "$1/conda/envs/demo/conda-meta/history"
  echo '{"x":1}' > "$1/preferences.json"
}
make_data_folder() {  # make_data_folder <dir>
  local O="$1/orgs/test-org"; local W="$O/workspaces/w1"
  mkdir -p "$W/.venv" "$O/artifacts/p1"
  echo v1 > "$W/result.csv"; echo keep > "$W/removed-later.csv"; echo junk > "$W/.venv/lib.py"; echo img > "$O/artifacts/p1/a.png"
  "$SQL" "$O/operon-cli.db" "create table t(x); insert into t values (42);"
}
run() {  # run <dest> <stamp> [VAR=value ...]
  local dest="$1" stamp="$2"; shift 2
  env CSB_DEST="$dest" CSB_SQLITE="$SQL" CSB_LOG="$T/backup.log" CSB_SCRATCH="$T/scratch" \
      CSB_APPWIN="$T/no-app-window" CSB_STAMP="$stamp" "$@" "$SH" "$HERE/backup.sh"
}
RSYNC_HELP=$(rsync --help 2>&1 || true)

echo
echo "Case 1: standard layout, run twice"
S=$T/case1/src; D=$T/case1/dest; W=$S/orgs/test-org/workspaces/w1
make_default_folder "$S"; make_data_folder "$S"
run "$D" run1 CSB_SRC="$S"
sleep 2
echo "v2-changed" > "$W/result.csv"; mv "$W/removed-later.csv" "$T/moved-away.csv"
run "$D" run2 CSB_SRC="$S"
check "last-run.txt says OK"                      'grep -q OK "$D/last-run.txt"'
check "one database snapshot per run"             '[ -f "$D/db/test-org-run1.db.gz" ] && [ -f "$D/db/test-org-run2.db.gz" ]'
check "database snapshot restores"                '[ "$(gunzip -c "$D/db/test-org-run2.db.gz" > "$T/restored.db" && "$SQL" "$T/restored.db" "select x from t;")" = 42 ]'
check "files are mirrored"                        '[ -f "$D/data/orgs/test-org/artifacts/p1/a.png" ]'
check "settings are mirrored"                     '[ -f "$D/data/preferences.json" ]'
check "changed file is updated in the mirror"     'grep -q v2-changed "$D/data/orgs/test-org/workspaces/w1/result.csv"'
check "file removed at source stays in backup"    '[ -f "$D/data/orgs/test-org/workspaces/w1/removed-later.csv" ]'
check "encryption key left out"                   '[ ! -e "$D/data/encryption.key" ]'
check "login tokens left out"                     '[ ! -e "$D/data/.oauth-tokens" ]'
check "TLS keys left out"                         '[ ! -e "$D/data/tls" ]'
check "conda environments left out"               '[ ! -e "$D/data/conda" ]'
check "Python venvs left out"                     '[ ! -e "$D/data/orgs/test-org/workspaces/w1/.venv" ]'
check "live database files left out of mirror"   '[ ! -e "$D/data/orgs/test-org/operon-cli.db" ]'
check "software manifest written each run"        '[ -f "$D/software-manifest/run1/demo.history.txt" ] && [ -f "$D/software-manifest/run2/claude-science-version.txt" ]'
check "no default-folder copy when data is in the default folder" '[ ! -e "$D/default-folder" ]'
if [[ "$RSYNC_HELP" == *--backup-dir* ]]; then
  check "previous version of changed file kept"   'grep -q v1 "$D/previous-versions/run2/data/orgs/test-org/workspaces/w1/result.csv"'
else
  echo "  skip previous-version check (this rsync has no --backup-dir; brew install rsync)"
fi

echo
echo "Case 2: data_dir set in config.toml"
S=$T/case2/src; DD=$T/case2/elsewhere; D=$T/case2/dest
make_default_folder "$S"; make_data_folder "$DD"
printf '# test config\ndisable_telemetry = true\ndata_dir = "%s"   # moved\n\n[update]\nauto_update = false\n' "$DD" > "$S/config.toml"
CSB_PRINT_PATHS=1 CSB_SRC="$S" CSB_DEST="$D" "$SH" "$HERE/backup.sh" > "$T/case2-paths.txt"
check "print-paths shows the moved data folder"   'grep -q "data folder: *$DD" "$T/case2-paths.txt"'
run "$D" run1 CSB_SRC="$S"
check "last-run.txt says OK"                      'grep -q OK "$D/last-run.txt"'
check "database snapshot taken from data_dir"     '[ -f "$D/db/test-org-run1.db.gz" ]'
check "data_dir mirrored to data/"                '[ -f "$D/data/orgs/test-org/artifacts/p1/a.png" ]'
check "default folder mirrored to default-folder/" '[ -f "$D/default-folder/preferences.json" ] && [ -f "$D/default-folder/config.toml" ]'
check "keys still left out of default folder"     '[ ! -e "$D/default-folder/encryption.key" ] && [ ! -e "$D/default-folder/.oauth-tokens" ]'
check "manifest still read from default folder"   '[ -f "$D/software-manifest/run1/demo.history.txt" ]'
printf "data_dir = '~/%s'\n" "${DD#$HOME/}" > "$T/case2-tilde.toml"
if [ "${DD#$HOME/}" != "$DD" ]; then
  mkdir -p "$T/case2b"; cp "$T/case2-tilde.toml" "$T/case2b/config.toml"
  CSB_PRINT_PATHS=1 CSB_SRC="$T/case2b" "$SH" "$HERE/backup.sh" > "$T/case2b-paths.txt"
  check "single-quoted ~ path in config.toml is expanded" 'grep -q "data folder: *$DD" "$T/case2b-paths.txt"'
fi

echo
echo "Case 3: app-window folder present"
S=$T/case3/src; D=$T/case3/dest; A=$T/case3/appwin
make_default_folder "$S"; make_data_folder "$S"
mkdir -p "$A/Local Storage/leveldb" "$A/Cache" "$A/GPUCache" "$A/Network"
echo draft > "$A/Local Storage/leveldb/000003.log"; echo '{"w":1}' > "$A/window-state.json"
echo c > "$A/Cache/data_0"; echo g > "$A/GPUCache/x"; echo cookie > "$A/Cookies"; echo cookie > "$A/Network/Cookies"
run "$D" run1 CSB_SRC="$S" CSB_APPWIN="$A"
check "last-run.txt says OK"                      'grep -q OK "$D/last-run.txt"'
check "drafts (page storage) backed up"           '[ -f "$D/app-window/Local Storage/leveldb/000003.log" ]'
check "window settings backed up"                 '[ -f "$D/app-window/window-state.json" ]'
check "app caches left out"                       '[ ! -e "$D/app-window/Cache" ] && [ ! -e "$D/app-window/GPUCache" ]'
check "cookies left out"                          '[ ! -e "$D/app-window/Cookies" ] && [ ! -e "$D/app-window/Network/Cookies" ]'

echo
echo "Case 4: an rsync without --backup-dir (like the one built into recent macOS)"
S=$T/case4/src; D=$T/case4/dest; W=$S/orgs/test-org/workspaces/w1
make_default_folder "$S"; make_data_folder "$S"
mkdir -p "$T/fake-rsync"
printf '#!/bin/bash\nif [ "${1:-}" = --help ]; then echo "usage: rsync [-a] src dst"; exit 0; fi\nfor a; do case "$a" in --backup*) echo "unsupported: $a" >&2; exit 1;; esac; done\nexec %s "$@"\n' "$(command -v rsync)" > "$T/fake-rsync/rsync"
chmod 755 "$T/fake-rsync/rsync"
run "$D" run1 CSB_SRC="$S" CSB_RSYNC="$T/fake-rsync/rsync"
sleep 2; echo v2 > "$W/result.csv"
run "$D" run2 CSB_SRC="$S" CSB_RSYNC="$T/fake-rsync/rsync"
check "backup still succeeds"                     'grep -q OK "$D/last-run.txt"'
check "changed file is updated"                   'grep -q v2 "$D/data/orgs/test-org/workspaces/w1/result.csv"'
check "log explains how to keep previous versions" 'grep -q "brew install rsync" "$T/backup.log"'

echo
echo "Case 5: nothing is ever deleted"
check "no source files were removed by the backup" '[ -f "$T/case1/src/encryption.key" ] && [ -f "$T/case2/elsewhere/orgs/test-org/operon-cli.db" ] && [ -f "$T/case3/appwin/Cookies" ] && [ -f "$T/case4/src/encryption.key" ]'

echo
echo "$pass passed, $failn failed. Test files are in $T"
[ $failn -eq 0 ]
