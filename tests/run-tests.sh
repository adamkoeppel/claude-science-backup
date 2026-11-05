#!/bin/bash
# Self-test for backup.sh. Builds a fake Claude Science folder in a new temporary
# directory, runs the backup against it twice, and checks the results.
# It never touches your real Claude Science data or your real backup folder,
# and it deletes nothing (the temporary directory is left for you to inspect).
# Needs: bash, rsync, sqlite3, gzip. Works on macOS and Linux.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/csb-test.XXXXXX")
SQL="${CSB_SQLITE:-$(command -v sqlite3)}"
[ -x "$SQL" ] || { echo "sqlite3 not found"; exit 1; }
pass=0; failn=0
check() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; failn=$((failn+1)); fi; }

S=$T/src; O=$S/orgs/test-org; W=$O/workspaces/w1
mkdir -p "$W/.venv" "$O/artifacts/p1" "$S/conda/envs/demo/conda-meta" "$S/.oauth-tokens" "$S/tls" "$S/runtime/0.0.0-test" "$T/dest"
echo secret > "$S/encryption.key"; echo token > "$S/.oauth-tokens/a.enc"; echo cert > "$S/tls/c.pem"
echo pkgs > "$S/conda/envs/demo/x"; echo '# cmd: create -p demo python=3.12' > "$S/conda/envs/demo/conda-meta/history"
echo v1 > "$W/result.csv"; echo keep > "$W/removed-later.csv"; echo junk > "$W/.venv/lib.py"; echo img > "$O/artifacts/p1/a.png"
"$SQL" "$O/operon-cli.db" "create table t(x); insert into t values (42);"

run() { CSB_SRC="$S" CSB_DEST="$T/dest" CSB_SQLITE="$SQL" CSB_LOG="$T/backup.log" CSB_SCRATCH="$T/scratch" CSB_STAMP="$1" bash "$HERE/backup.sh"; }

echo "First run"
run run1; echo "  exit $?"
sleep 2
echo "v2-changed" > "$W/result.csv"; mv "$W/removed-later.csv" "$T/moved-away.csv"
echo "Second run"
run run2; echo "  exit $?"

D=$T/dest
echo "Checks"
check "last-run.txt says OK"                      'grep -q OK "$D/last-run.txt"'
check "one database snapshot per run"             '[ -f "$D/db/test-org-run1.db.gz" ] && [ -f "$D/db/test-org-run2.db.gz" ]'
check "database snapshot restores"                '[ "$(gunzip -c "$D/db/test-org-run2.db.gz" > "$T/restored.db" && "$SQL" "$T/restored.db" "select x from t;")" = 42 ]'
check "files are mirrored"                        '[ -f "$D/data/orgs/test-org/artifacts/p1/a.png" ]'
check "changed file is updated in the mirror"     'grep -q v2-changed "$D/data/orgs/test-org/workspaces/w1/result.csv"'
check "file removed at source stays in backup"    '[ -f "$D/data/orgs/test-org/workspaces/w1/removed-later.csv" ]'
check "encryption key left out"                   '[ ! -e "$D/data/encryption.key" ]'
check "login tokens left out"                     '[ ! -e "$D/data/.oauth-tokens" ]'
check "TLS keys left out"                         '[ ! -e "$D/data/tls" ]'
check "conda environments left out"               '[ ! -e "$D/data/conda" ]'
check "Python venvs left out"                     '[ ! -e "$D/data/orgs/test-org/workspaces/w1/.venv" ]'
check "live database files left out of mirror"    '[ ! -e "$D/data/orgs/test-org/operon-cli.db" ]'
check "software manifest written each run"        '[ -f "$D/software-manifest/run1/demo.history.txt" ] && [ -f "$D/software-manifest/run2/claude-science-version.txt" ]'
RSYNC_HELP=$(rsync --help 2>&1 || true)
if [[ "$RSYNC_HELP" == *--backup-dir* ]]; then
  check "previous version of changed file kept"   'grep -q v1 "$D/previous-versions/run2/orgs/test-org/workspaces/w1/result.csv"'
else
  echo "  skip previous-version check (this rsync has no --backup-dir; brew install rsync)"
fi

echo
echo "$pass passed, $failn failed. Test files are in $T"
[ $failn -eq 0 ]
