# Restoring Claude Science from this backup

Claude Science keeps projects, artifacts, conversation history and memory on your Mac, not in your Claude account. This backup is what lets you get them back after a lost, stolen or dead machine.

## What the backup folder holds

- `data/` is a mirror of the Claude Science data folder: projects, artifacts, workspaces, skills and settings. Files you deleted on the Mac are still here.
- `default-folder/` appears only if `data_dir` in `config.toml` moved the data out of `~/.claude-science`. It holds the settings that stayed behind, including `config.toml` itself.
- `app-window/` appears only if Claude Science opens in its own window on this Mac. It is a copy of `~/Library/Application Support/Claude Science`: window settings and unsent drafts.
- `db/` holds one dated snapshot per night of the database that stores your sessions, messages and memories.
- `previous-versions/` holds older copies of files that changed, filed by date and then by part (`data`, `default-folder`, `app-window`).
- `software-manifest/` has one dated folder per night recording each conda environment: an exact export, the install history and the pip and R package lists.
- `last-run.txt` gives the result of the most recent run.

Nothing in the folder is ever deleted by the backup. If you want to trim old copies, you do that yourself.

## What is left out on purpose

- `encryption.key`, `.oauth-tokens`, `.key-backups` and `tls` are keys and login tokens. The database snapshot still contains your stored credentials, but encrypted with a key the backup does not have, so they are unreadable. After a restore you sign in again and re-enter any credentials you had stored in Claude Science.
- `conda`, `bin`, `runtime`, `r-libs`, Python virtual environments and caches are software. Claude Science reinstalls its own runtime, and the software manifest lets you rebuild your environments. One login file (`conda/_netrc`) sits in this folder, so re-enter any data-source logins it held.

## Restoring to a new Mac

1. Install Claude Science, open it, sign in with the same Claude account, then quit it.
2. In Terminal, point at the backup and copy the data back:

   ```
   B=~/Library/Mobile\ Documents/com~apple~CloudDocs/Claude\ Science\ Backup
   rsync -a "$B/data/" ~/.claude-science/
   ```

3. Find your org folder name with `ls "$B/db"`. Snapshot names start with it. Then put the newest snapshot in place, replacing ORG:

   ```
   gunzip -c "$(ls -t "$B"/db/ORG-*.db.gz | head -1)" > ~/.claude-science/orgs/ORG/operon-cli.db
   ```

   Move any `operon-cli.db-wal` and `operon-cli.db-shm` files in that folder out of the way. They belong to the new install's empty database.

4. If the new install created a different org folder under `~/.claude-science/orgs`, copy the backed-up org folder's contents into the new one instead.

   If the old Mac used `data_dir`, restore `default-folder/` to `~/.claude-science/` and `data/` to the folder `data_dir` names (the old `config.toml` is in `default-folder/`). Put the database snapshot in that folder's `orgs/ORG/`.

   If there is an `app-window/` folder and Claude Science opens in its own window on the new Mac, copy it back with the app closed:

   ```
   rsync -a "$B/app-window/" ~/Library/Application\ Support/Claude\ Science/
   ```

5. Open Claude Science, sign in, and re-enter your stored credentials.
6. Rebuild your environments (below), then run `install.sh` again to resume nightly backups.

## Rebuilding conda environments

Use the newest folder in `software-manifest/`. For each environment NAME:

```
M=~/.claude-science/conda/bin/micromamba
$M create -y -p ~/.claude-science/conda/envs/NAME -f NAME.explicit.txt
```

The `.explicit.txt` file pins every package to the exact build, which works when the new Mac has the same chip family. If it fails, use the looser `.yml` export instead:

```
$M create -y -p ~/.claude-science/conda/envs/NAME -f NAME.yml
```

`NAME.history.txt` shows every install command that built the environment, and `NAME.pip.txt` and `NAME.R-packages.csv` list what pip and R had installed. You can also hand the manifest folder to Claude Science in a new session and ask it to rebuild the environments.

If `~/.claude-science/conda/bin/micromamba` does not exist on the new Mac, install micromamba with `brew install micromamba` and use that instead.
