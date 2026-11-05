# Instructions for an agentic developer

You are setting up a nightly backup of Claude Science's local data on a person's Mac. Read README.md for what the backup does. These steps cover how to install it safely on someone else's machine.

## Ground rules

- **Never delete anything.** Do not delete files from the Claude Science data folder, from the backup destination, or anywhere else on the Mac. Do not add pruning, retention limits, `rsync --delete` or any cleanup step unless the person explicitly asks for it, in their own words, for that specific thing. If they later ask to trim old backups, show them exactly what would be removed and get a yes first.
- **Do not change the person's data in place.** Treat `~/.claude-science` as read-only. Never move it, symlink it into iCloud Drive or any other synced folder, or run git in it.
- **Do not copy keys or tokens anywhere.** The exclusions in `backup.sh` for `encryption.key`, `.oauth-tokens`, `.key-backups` and `tls` are deliberate. Do not remove them, and do not commit any of the person's data to git.
- **Ask before anything the person would want a say in:** the destination, enabling Full Disk Access, installing Homebrew packages, or changing the schedule.
- **Report what you did plainly.** When you finish, tell the person what was installed, where the backup goes and how to check it.

## Steps

1. **Confirm the platform.** Run `uname` and `sw_vers`. This only works on macOS.
2. **Find the data folder.** Run `CSB_PRINT_PATHS=1 /bin/bash backup.sh` from the repo. It prints the default folder, the data folder (it follows `data_dir` in `~/.claude-science/config.toml`), whether the app-window folder exists, and the destination, and changes nothing. Confirm the data folder contains `orgs/`. If it doesn't, ask the person to check Settings > Storage > Data location in Claude Science and pass that path as `CSB_DATA_DIR`.
3. **Size it.** Run `du -sh` on the data folder's `orgs` subfolder. The first backup is roughly that size. Tell the person the number.
4. **Choose the destination with the person.** The default is iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/Claude Science Backup`).
   - Confirm iCloud Drive exists. If the person uses it, ask them to check free space under System Settings > [their name] > iCloud.
   - Mention that writing to the iCloud folder also uses local disk until macOS offloads the files. "Optimize Mac Storage" in iCloud Drive settings handles that. Check free local disk with `df -h ~`.
   - If they prefer an external disk or another folder, use that path as `CSB_DEST`.
   - Whether to use Advanced Data Protection is the person's call. The backup holds no keys either way, so it works without it.
5. **Check tools.** `sqlite3`, `rsync` and `gzip` ship with macOS. The rsync that comes with recent macOS may not support `--backup-dir`, which the script uses to keep previous versions of changed files. If `rsync --help` doesn't mention `--backup-dir`, offer `brew install rsync`. The script works without it but won't keep old versions of changed files.
6. **Run the self-test.** `bash tests/run-tests.sh` runs the backup against a fake folder in a new temporary directory and prints pass or fail for each check. Every check should pass before you install.
7. **Install.** From the repo folder, run `bash install.sh`, with `CSB_SRC` or `CSB_DEST` set on the same line if they differ from the defaults. The person may want to run this command themselves in Terminal. The installer schedules the job, runs the first backup and then tests the scheduled run. The first run can take a long time on a large folder, so a command timeout does not mean it failed. Check `last-run.txt` and the log.
8. **Handle "Operation not permitted".** If the scheduled run can't write to the destination, macOS privacy controls are blocking background access. Ask the person to add `/bin/bash` under System Settings > Privacy & Security > Full Disk Access, then rerun `install.sh`. Do not try to work around it.
9. **Verify.** Confirm `last-run.txt` in the destination says OK, and that `db/` has a snapshot and `data/orgs/` exists. Decompress the snapshot to a temporary location and run `sqlite3 <file> 'pragma quick_check;'`. It should print `ok`.
10. **Tell the person three things.** Where the backup lives. How to check it (`last-run.txt`). What they will need to re-enter after a restore: their Claude sign-in and any credentials stored in Claude Science. Point them to RESTORE.md, which the installer copied into the backup folder.

## Updating

To change the script, edit `backup.sh` in the repo, rerun `tests/run-tests.sh`, then rerun `install.sh`. Keep `backup.sh` working under `/bin/bash` 3.2, which is what macOS ships and what launchd runs: no namerefs (`local -n`), no `mapfile`, no `${var,,}`, and never expand a possibly empty array under `set -u`. On a Mac the self-test runs the backup with `/bin/bash`, so a passing test there is the real check. The installer copies the new version into place. It never deletes existing backups.

## Uninstalling

Only if the person asks. `launchctl bootout gui/$(id -u)/local.claude-science-backup` stops the schedule. Leave the plist, the installed script and all backups where they are unless the person explicitly asks you to remove them.
