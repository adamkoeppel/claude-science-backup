# Claude Science backup for macOS

Claude Science runs on your own computer. Your projects, artifacts, conversation history and memory live in a data folder on that machine, not in your Claude account. If the Mac is lost, stolen or dies, that work goes with it unless you back the folder up. Anthropic's own docs say to include the app's data folder in your regular backups ([Claude Science on multiple computers](https://claude.com/docs/claude-science/multiple-computers)).

This repo is a small nightly backup that does that, to iCloud Drive by default.

## What it does

Every night at 2:17 AM, or when the Mac next wakes if it was asleep, `backup.sh`:

1. Writes a software manifest: an exact export of each conda environment, its install history, and its pip and R package lists. The environments themselves are not copied, because they are large and rebuild cleanly from the manifest.
2. Takes a consistent snapshot of the Claude Science database with SQLite's own backup command, which is safe while the app is running. It checks the snapshot's integrity, compresses it and saves it with the date in its name.
3. Mirrors the rest of the data folder (projects, artifacts, workspaces, skills, settings) with rsync. After the first run only changes are copied. If `data_dir` in Claude Science's `config.toml` moves the data elsewhere, the script follows it and also backs up the default folder's settings.
4. On a Mac where Claude Science opens in its own window, it also backs up `~/Library/Application Support/Claude Science`, which holds window settings and unsent message drafts. Caches and cookies are left out.
5. Writes the result to `last-run.txt`. On failure it also shows a macOS notification.

## What it never does

- It never deletes anything, from the Claude Science folder or from the backup. Files you delete on the Mac stay in the backup, and when a file changes the old version moves to `previous-versions/`. The backup grows over time and trimming it is left to you.
- It never copies keys or login tokens: `encryption.key`, `.oauth-tokens`, `.key-backups` and `tls`. Credentials stored in the database stay encrypted with a key the backup does not hold. After a restore you sign in and re-enter them. This means the backup is safe to keep in ordinary iCloud Drive without Advanced Data Protection.
- It never moves or links the live data folder into iCloud. Syncing a live SQLite database through a cloud drive can corrupt it, so the script writes snapshots into the cloud folder instead.

## Install

Requirements: macOS, Claude Science installed and used at least once, and either iCloud Drive turned on or another destination folder. The first backup is roughly the size of your Claude Science data folder minus its software (check with `du -sh ~/.claude-science/orgs`).

```
git clone https://github.com/adamkoeppel/claude-science-backup.git
cd claude-science-backup
bash tests/run-tests.sh      # optional: runs the backup against a fake folder
bash install.sh
```

The installer copies `backup.sh` to `~/Library/Application Support/claude-science-backup`, schedules it with launchd, runs the first backup, and then checks that the scheduled job works on its own.

To back up somewhere other than iCloud Drive, such as an external disk:

```
CSB_DEST="/Volumes/Backup/Claude Science Backup" bash install.sh
```

The script finds the data folder by itself, including when `data_dir` is set in `~/.claude-science/config.toml`. To see what it will back up without running a backup:

```
CSB_PRINT_PATHS=1 bash backup.sh
```

If that shows the wrong data folder (check Settings > Storage > Data location in the app), set `CSB_DATA_DIR` the same way as `CSB_DEST`.

If the scheduled run fails with "Operation not permitted", macOS is blocking background access to the destination. Add `/bin/bash` under System Settings > Privacy & Security > Full Disk Access and run the installer again.

## Check that it's working

Open `last-run.txt` in the backup folder. It shows the date of the last run, OK or FAILED, and the backup's size. The full log is at `~/Library/Logs/claude-science-backup.log`.

## Restore

See [RESTORE.md](RESTORE.md). The installer also copies it into the backup folder, so it is there when you need it.

## Using an AI coding agent to set this up

[AGENTS.md](AGENTS.md) has step-by-step instructions written for an agentic developer, such as Claude Code, installing this on someone's Mac.

## Status

The scripts pass the self-test in `tests/` and were written against the layout of a real Claude Science data folder (app runtime 0.1.70, November 2026). A future Claude Science release could change that layout. A full end-to-end restore onto a fresh Mac has not been tested yet. Issues and pull requests are welcome.

## License

MIT. See [LICENSE](LICENSE).
