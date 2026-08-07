# libation-audible-drive-sync-tool

One-click Windows tool that sorts new [Libation](https://github.com/rmcrackan/Libation)
audiobook downloads into category folders and uploads only new files to Google
Drive with [rclone](https://rclone.org/).

It exists because Libation can save books as `<Author>\<Series>\` but has no
concept of a category above that. This tool adds the missing step, then syncs.

```
Libation downloads              →  <books>\<Author>\<Series>\NN - Title.m4b
Sync Audiobooks (this tool)     →  asks: Kids? Young Adult? General?
                                →  uploads only what is new to Google Drive
```

## Quick start

1. Copy this folder anywhere.
2. Double-click **`Setup Audiobook Sync.bat`**.
3. Fix anything it reports, run it again until every check passes.
4. From then on, double-click **`Sync Audiobooks`** on your desktop.

Setup creates the books folder, the category folders, the config file, and the
desktop shortcut, then re-runs its checks so you can see the result.

## Files

| File | Purpose |
|---|---|
| `Sync-Audiobooks.ps1` | The entire tool. |
| `Sync Audiobooks.bat` | Launcher for a normal run. |
| `Setup Audiobook Sync.bat` | Launcher for guided setup. |
| `README.md` | This file. |
| `.gitignore` | Excludes the per-machine config and log. |

All files must stay **in the same folder** — the `.bat` launchers find the
script via `%~dp0`, and the config and log default to sitting beside it.

Created at runtime, never copied between machines:
`audiobook-sync.config.json` (machine-specific paths) and `audiobook-sync.log`.

## Requirements

- **rclone** with a configured Google Drive remote — `winget install Rclone.Rclone`
- **Libation**, configured as below

### Libation settings this depends on

| Setting | Value |
|---|---|
| Important settings → Books location | your books folder (must match `LibationRoot`) |
| Download/Decrypt → folder format | `<first author>\<if series-><series><-if series>` |
| Download/Decrypt → pdf and audio file format | `<if series-><series#[00]> - <-if series><title>` |
| Download/Decrypt → In progress files | System temporary folder |

The **folder format is load-bearing**. It makes Libation drop new books at
`<books folder>\<Author>\<Series>\`, at the top level, where this tool can find
them. Change it and the sort step silently finds nothing — so the tool verifies
it on every run and refuses to continue if it is wrong.

Setup reads these straight out of Libation's own `Settings.json` (found via
`<install>\appsettings.json` → `LibationFiles`), so it tells you about a
mismatch instead of guessing.

## ⚠ Do not remove the `--drive-encoding` line

```powershell
$DriveEncoding = "InvalidUtf8,Slash,BackSlash,Colon,Question,Asterisk,Pipe,DoubleQuote,LtGt"
```

It looks like noise. It is load-bearing.

Windows forbids `? : * | " < > /` in filenames, so Libation substitutes
full-width look-alikes — `How Do Dinosaurs Learn to Read?.m4b` is really stored
with `U+FF1F` (`？`). Google Drive holds the byte-identical name.

But rclone's **local** backend decodes `？` back to `?`, while its **drive**
backend does not. Without this flag rclone concludes those files are missing
from Drive:

- `rclone copy` → uploads duplicate files
- `rclone sync` → uploads duplicates **and deletes the originals**

The flag makes both sides normalize the same way. Measured on a real library:
9 phantom differences without it, 0 with it.

## Safety design

- Uses `rclone copy`, never `rclone sync` — structurally cannot delete anything
  on Google Drive.
- Files on Drive but not local are reported as a yellow **ALERT** and left
  alone. You decide what to do.
- Category moves are same-volume renames (instant, no byte copying) and merge
  into an existing author folder rather than replacing it. Name collisions are
  skipped and reported, never overwritten.
- Refuses to run at all if any setup check fails.
- Every run is appended to `audiobook-sync.log`.

## Usage

```powershell
.\Sync-Audiobooks.ps1              # normal run
.\Sync-Audiobooks.ps1 -Setup       # guided setup + full check
.\Sync-Audiobooks.ps1 -DryRun      # preview, change nothing
.\Sync-Audiobooks.ps1 -SkipSort    # skip category sort, just sync
.\Sync-Audiobooks.ps1 -NoPause     # unattended (no "press Enter")
```

Override paths without touching the config file:

```powershell
.\Sync-Audiobooks.ps1 -LibationRoot "D:\Books" -Remote "gdrive:Audiobooks"
```

## Categories

Any folder matching `NN - Name` at the top of the books folder is treated as a
category and offered in the sort menu. The defaults are `01 - Kids`,
`02 - Young Adult`, `03 - General`; add `04 - Nonfiction` and it appears
automatically, no code change needed.

## Notes

- Replaced an older FreeFileSync **Mirror** job, which was unsafe here: Mirror
  deletes Drive-only files, and it carried the encoding bug above.
- `(1)` suffixes visible in a Google Drive for Desktop mount (`H:\My Drive\...`)
  are a local mount artifact, not the real filename. rclone talks to the Drive
  API directly and sees the true names, so it is unaffected.
- Windows PowerShell 5.1 turns native-exe stderr into a terminating error under
  `$ErrorActionPreference = 'Stop'`. rclone writes routine notices to stderr, so
  all rclone calls go through `Invoke-Rclone`, which relaxes the preference.
  Don't call rclone directly.
