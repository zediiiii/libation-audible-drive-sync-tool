<#
    Sync-Audiobooks.ps1
    ==================================================================
    One-click Libation -> Google Drive audiobook pipeline.

      STEP 0  Check this machine is set up correctly. If anything is
              wrong it prints exact, copy-pasteable instructions and
              stops instead of doing damage.  (Run -Setup to see the
              full guide at any time.)

      STEP 1  Sort new author folders sitting loose in the root of the
              Libation books folder into a category folder.
              Libation's folder template is <first author>\<series>, so
              Libation itself can never create the category level.

      STEP 2  Compare against Google Drive with rclone.

      STEP 3  Upload ONLY new/changed files. Uses "rclone copy", which
              is structurally incapable of deleting anything on Drive.

      STEP 4  Report. Files on Drive but not local are ALERTED, never
              deleted.

    Deploying on a new machine?   Just run:   .\Sync-Audiobooks.ps1 -Setup

    Keep this script OUTSIDE the books folder so it doesn't sync.
#>

[CmdletBinding()]
param(
    [string] $LibationRoot,
    [string] $Remote,
    [string] $LogFile,
    [string] $ConfigFile,

    [switch] $Setup,       # run the full setup doctor + guide, then exit
    [switch] $DryRun,      # preview everything, change nothing
    [switch] $SkipSort,    # skip the interactive category sort
    [switch] $NoPause      # don't hold the window open (unattended runs)
)

$ErrorActionPreference = 'Stop'

# Resolve the script's own folder. $PSScriptRoot is not reliably populated
# inside a param() default under Windows PowerShell 5.1, so do it here.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
if (-not $ConfigFile) { $ConfigFile = Join-Path $ScriptDir "audiobook-sync.config.json" }

# ==================================================================
# What this pipeline REQUIRES of Libation. Checked on every run.
# ==================================================================
$ExpectedFolderTemplate = '<first author>\<if series-><series><-if series>'
$ExpectedFileTemplate   = '<if series-><series#[00]> - <-if series><title>'
$DefaultCategories      = @('01 - Kids', '02 - Young Adult', '03 - General')

# ------------------------------------------------------------------
# CRITICAL: filename encoding. Do not remove.
#
# Windows forbids  ? : * | " < > /  in filenames, so Libation stores
# full-width look-alikes instead ("Read?.m4b" is really "Read<U+FF1F>.m4b").
# rclone's LOCAL backend decodes those back to ASCII; its DRIVE backend
# does not. Without this flag rclone thinks those files are missing from
# Drive and re-uploads them as duplicates (and "sync" would delete the
# originals). This makes both sides agree.
# ------------------------------------------------------------------
$DriveEncoding = "InvalidUtf8,Slash,BackSlash,Colon,Question,Asterisk,Pipe,DoubleQuote,LtGt"

$RcloneCommon = @(
    "--drive-encoding", $DriveEncoding
    "--size-only"                     # audiobooks never change in place
    "--exclude", "sync.ffs_db"
    "--exclude", "desktop.ini"
    "--exclude", "thumbs.db"
    "--exclude", "*.tmp"
    "--exclude", "audiobook-sync.config.json"
)

# ==================================================================
# small helpers
# ==================================================================

function Write-Head {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host ("=" * 72) -ForegroundColor $Color
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    return ("{0:N0} KB" -f ($Bytes / 1KB))
}

function Write-Log {
    param([string]$Message)
    if (-not $script:LogFile) { return }
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 } catch { }
}

# PowerShell 5.1 turns native-exe stderr into a terminating ErrorRecord while
# $ErrorActionPreference is 'Stop'. rclone writes normal notices to stderr, so
# every rclone call must relax the preference.
function Invoke-Rclone {
    param([string[]] $Arguments, [switch] $Passthru)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Passthru) { & $script:RclonePath @Arguments }
        else           { & $script:RclonePath @Arguments 2>$null }
    }
    finally { $ErrorActionPreference = $prev }
}

# Move $Src into $Dst, merging recursively if $Dst exists. Same-volume moves
# are instant renames, so GB-sized books don't get copied byte by byte.
function Move-Merge {
    param([string]$Src, [string]$Dst)

    if (-not (Test-Path -LiteralPath $Dst)) {
        Move-Item -LiteralPath $Src -Destination $Dst
        return
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Src -Force)) {
        $target = Join-Path $Dst $item.Name
        if ($item.PSIsContainer) { Move-Merge -Src $item.FullName -Dst $target }
        elseif (Test-Path -LiteralPath $target) {
            Write-Host "      ! already exists, left in place: $($item.Name)" -ForegroundColor Yellow
            Write-Log "COLLISION (not moved): $($item.FullName)"
        }
        else { Move-Item -LiteralPath $item.FullName -Destination $target }
    }
    if (-not (Get-ChildItem -LiteralPath $Src -Force)) { Remove-Item -LiteralPath $Src -Force }
}

function Strip-LongPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    return ($Path -replace '^\\\\\?\\', '')
}

# ==================================================================
# Libation discovery
#   <install>\appsettings.json  ->  "LibationFiles"  ->  <cfg>\Settings.json
# ==================================================================
function Get-LibationInfo {
    $info = [ordered]@{
        InstallDir = $null; AppSettings = $null; ConfigDir = $null
        SettingsFile = $null; Books = $null
        FolderTemplate = $null; FileTemplate = $null; InProgress = $null
    }

    $roots = @(
        "$env:ProgramFiles\Libation", "${env:ProgramFiles(x86)}\Libation",
        "$env:LOCALAPPDATA\Programs\Libation", "$env:LOCALAPPDATA\Libation"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($r in $roots) {
        $app = Get-ChildItem -LiteralPath $r -Filter "appsettings.json" -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($app) { $info.InstallDir = $r; $info.AppSettings = $app.FullName; break }
    }

    if ($info.AppSettings) {
        try {
            $j = Get-Content -LiteralPath $info.AppSettings -Raw | ConvertFrom-Json
            if ($j.LibationFiles) { $info.ConfigDir = Strip-LongPath $j.LibationFiles }
        } catch { }
    }
    # Libation's default when appsettings.json is absent or unhelpful.
    if (-not $info.ConfigDir -and (Test-Path "$env:USERPROFILE\Libation")) {
        $info.ConfigDir = "$env:USERPROFILE\Libation"
    }

    if ($info.ConfigDir) {
        $sf = Join-Path $info.ConfigDir "Settings.json"
        if (Test-Path -LiteralPath $sf) {
            $info.SettingsFile = $sf
            try {
                $s = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
                $info.Books          = Strip-LongPath $s.Books
                $info.FolderTemplate = $s.FolderTemplate
                $info.FileTemplate   = $s.FileTemplate
                if ($s.PSObject.Properties.Name -contains 'InProgress') {
                    $info.InProgress = Strip-LongPath $s.InProgress
                }
            } catch { }
        }
    }
    return [pscustomobject]$info
}

# ==================================================================
# the setup doctor
# ==================================================================
$script:Checks = @()
function Add-Check {
    param(
        [ValidateSet('PASS','WARN','FAIL')][string]$State,
        [string]$Name, [string]$Detail, [string[]]$Fix = @()
    )
    $script:Checks += [pscustomobject]@{ State=$State; Name=$Name; Detail=$Detail; Fix=$Fix }
}

function Invoke-Doctor {
    param([string]$Root, [string]$RemoteSpec)

    $script:Checks = @()

    # ---- 1. rclone ------------------------------------------------
    $rc = (Get-Command rclone -ErrorAction SilentlyContinue).Source
    $script:RclonePath = $rc
    if ($rc) {
        $ver = (Invoke-Rclone @("version") | Select-Object -First 1)
        Add-Check PASS "rclone installed" "$ver  ($rc)"
    }
    else {
        Add-Check FAIL "rclone installed" "rclone is not on PATH" @(
            'Install it:',
            '    winget install Rclone.Rclone',
            'then close and reopen the terminal so PATH refreshes.'
        )
    }

    # ---- 2 & 3. rclone remote + target folder ---------------------
    $remoteName = $null
    if ($RemoteSpec -match '^([^:]+):') { $remoteName = $Matches[1] }

    if ($rc -and $remoteName) {
        $remotes = @(Invoke-Rclone @("listremotes") | ForEach-Object { $_.TrimEnd(':') })
        if ($remotes -contains $remoteName) {
            Add-Check PASS "rclone remote '$remoteName'" "configured"

            Invoke-Rclone (@("lsd", $RemoteSpec, "--max-depth", "1") + @("--drive-encoding", $DriveEncoding)) | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Add-Check PASS "Drive folder reachable" $RemoteSpec
            }
            else {
                Add-Check FAIL "Drive folder reachable" "cannot open $RemoteSpec" @(
                    'Either the folder does not exist yet, or the token expired.',
                    "    rclone lsd `"$remoteName`:`"            # see what is there",
                    "    rclone mkdir `"$RemoteSpec`"    # create it",
                    "    rclone config reconnect $remoteName`:   # re-authorise"
                )
            }
        }
        else {
            $have = if ($remotes) { $remotes -join ', ' } else { '(none)' }
            Add-Check FAIL "rclone remote '$remoteName'" "not configured. Found: $have" @(
                'Create a Google Drive remote:',
                '    rclone config',
                "  -> n (new)  -> name it '$remoteName'  -> storage: drive",
                '  -> leave client_id/secret blank -> scope: 1 (full access)',
                '  -> auto config: y -> sign in to the Google account in the browser',
                'Then set "Remote" in the config file to  <name>:<folder on Drive>'
            )
        }
    }

    # ---- 4 & 5. Libation ------------------------------------------
    $lib = Get-LibationInfo
    if ($lib.SettingsFile) {
        Add-Check PASS "Libation installed" "config: $($lib.ConfigDir)"
    }
    else {
        Add-Check FAIL "Libation installed" "could not find Libation's Settings.json" @(
            'Install Libation from  https://github.com/rmcrackan/Libation/releases',
            'Run it once and sign in to your Audible account, then re-run this script.'
        )
    }

    # ---- 6. Books location must equal our root --------------------
    if ($lib.Books) {
        if ($Root -and ($lib.Books.TrimEnd('\') -ieq $Root.TrimEnd('\'))) {
            Add-Check PASS "Libation books location" $lib.Books
        }
        else {
            Add-Check FAIL "Libation books location" "Libation saves to '$($lib.Books)' but this script watches '$Root'" @(
                'In Libation:  Settings -> Important settings -> Books location',
                "  Select the second radio button and set it to:",
                "      $Root",
                'Or change "LibationRoot" in the config file to match Libation.'
            )
        }
    }

    # ---- 7. Folder template (the load-bearing one) ----------------
    if ($lib.FolderTemplate) {
        if ($lib.FolderTemplate -eq $ExpectedFolderTemplate) {
            Add-Check PASS "Libation folder template" $lib.FolderTemplate
        }
        elseif ($lib.FolderTemplate -like '<first author>*') {
            Add-Check WARN "Libation folder template" "'$($lib.FolderTemplate)' - starts with <first author>, so sorting still works, but this is not the tested value" @(
                'Recommended value:',
                "      $ExpectedFolderTemplate"
            )
        }
        else {
            Add-Check FAIL "Libation folder template" "'$($lib.FolderTemplate)' does not start with <first author>" @(
                'The category sort depends on Libation creating <Author>\ at the top',
                'of the books folder. Set it in:',
                '  Settings -> Download/Decrypt -> "How to format the folders in which files will be saved"',
                "      $ExpectedFolderTemplate"
            )
        }
    }

    # ---- 8. File template (cosmetic) ------------------------------
    if ($lib.FileTemplate) {
        if ($lib.FileTemplate -eq $ExpectedFileTemplate) {
            Add-Check PASS "Libation file template" $lib.FileTemplate
        }
        else {
            Add-Check WARN "Libation file template" "'$($lib.FileTemplate)' differs from the tested value" @(
                'Only affects file naming, not syncing. Recommended:',
                '  Settings -> Download/Decrypt -> "How to format the saved pdf and audio files"',
                "      $ExpectedFileTemplate"
            )
        }
    }

    # ---- 9. In-progress folder must not be inside the books tree ---
    if ($lib.InProgress -and $Root -and $lib.InProgress.StartsWith($Root, 'OrdinalIgnoreCase')) {
        Add-Check WARN "Libation in-progress folder" "'$($lib.InProgress)' is inside the books folder" @(
            'Half-finished downloads would get uploaded to Drive.',
            '  Settings -> Download/Decrypt -> In progress files -> "System temporary folder"'
        )
    }
    elseif ($lib.InProgress) {
        Add-Check PASS "Libation in-progress folder" $lib.InProgress
    }

    # ---- 10 & 11. local folders -----------------------------------
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Add-Check PASS "Books folder exists" $Root
        $cats = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d{2}\s*-\s*' })
        if ($cats.Count -gt 0) {
            Add-Check PASS "Category folders" (($cats | Select-Object -Expand Name) -join ', ')
        }
        else {
            $mk = @('Create them (run this script with -Setup to do it automatically):')
            $mk += ($DefaultCategories | ForEach-Object { "    mkdir `"$Root\$_`"" })
            Add-Check FAIL "Category folders" "no 'NN - Name' folders found in $Root" $mk
        }
    }
    else {
        Add-Check FAIL "Books folder exists" "not found: $Root" @(
            "    mkdir `"$Root`"",
            'or point "LibationRoot" in the config file somewhere else.'
        )
    }

    return $lib
}

function Show-Doctor {
    Write-Head "SETUP CHECK" 'Cyan'
    foreach ($c in $script:Checks) {
        $col = switch ($c.State) { 'PASS' {'Green'} 'WARN' {'Yellow'} 'FAIL' {'Red'} }
        $tag = switch ($c.State) { 'PASS' {'[ OK ]'} 'WARN' {'[WARN]'} 'FAIL' {'[FAIL]'} }
        Write-Host ("  {0} {1}" -f $tag, $c.Name) -ForegroundColor $col
        if ($c.Detail) { Write-Host "         $($c.Detail)" -ForegroundColor DarkGray }
    }

    $bad = @($script:Checks | Where-Object { $_.State -ne 'PASS' })
    if ($bad.Count -gt 0) {
        Write-Host ""
        Write-Host ("-" * 72) -ForegroundColor Yellow
        Write-Host "  HOW TO FIX" -ForegroundColor Yellow
        Write-Host ("-" * 72) -ForegroundColor Yellow
        foreach ($c in $bad) {
            if ($c.Fix.Count -eq 0) { continue }
            $col = if ($c.State -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ""
            Write-Host "  * $($c.Name)" -ForegroundColor $col
            foreach ($line in $c.Fix) { Write-Host "    $line" -ForegroundColor Gray }
        }
    }
    return (@($script:Checks | Where-Object { $_.State -eq 'FAIL' }).Count -eq 0)
}

# ==================================================================
# config file (makes redeploying to another machine a 1-file edit)
# ==================================================================
$cfg = $null
if (Test-Path -LiteralPath $ConfigFile) {
    try { $cfg = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json }
    catch { Write-Host "Config file is not valid JSON: $ConfigFile" -ForegroundColor Red }
}

# precedence: command-line parameter > config file > auto-detected default
if (-not $LibationRoot) {
    if ($cfg -and $cfg.LibationRoot) { $LibationRoot = $cfg.LibationRoot }
    else { $LibationRoot = (Get-LibationInfo).Books }
}
if (-not $Remote) {
    if ($cfg -and $cfg.Remote) { $Remote = $cfg.Remote }
    else { $Remote = "gdrive:Audio Books & Podcasts" }
}
if (-not $LogFile) {
    if ($cfg -and $cfg.LogFile) { $LogFile = $cfg.LogFile }
    else { $LogFile = Join-Path $ScriptDir "audiobook-sync.log" }
}
$script:LogFile = $LogFile

# ==================================================================
# STEP 0 - preflight
# ==================================================================
Write-Head "AUDIOBOOK SYNC" 'Cyan'
Write-Host "  Local  : $LibationRoot"
Write-Host "  Remote : $Remote"
Write-Host "  Config : $ConfigFile$(if (-not (Test-Path -LiteralPath $ConfigFile)) { '   (not created yet)' })"
if ($DryRun) { Write-Host "  MODE   : DRY RUN - nothing will be moved or uploaded" -ForegroundColor Yellow }

$libInfo = Invoke-Doctor -Root $LibationRoot -RemoteSpec $Remote
$healthy = Show-Doctor

# -------- -Setup mode: fix what can be fixed automatically
if ($Setup) {
    Write-Head "GUIDED SETUP" 'Cyan'
    Write-Host "  Answer y/n. Anything already correct is skipped automatically.`n" -ForegroundColor DarkGray
    $step = 0

    # --- books folder -------------------------------------------------
    if ($LibationRoot -and -not (Test-Path -LiteralPath $LibationRoot)) {
        $step++
        Write-Host "  [$step] Books folder does not exist yet:" -ForegroundColor White
        Write-Host "      $LibationRoot" -ForegroundColor DarkGray
        if ((Read-Host "      Create it? (y/n)") -eq 'y') {
            New-Item -ItemType Directory -Path $LibationRoot -Force | Out-Null
            Write-Host "      Created.`n" -ForegroundColor Green
        } else { Write-Host "" }
    }

    # --- category folders ---------------------------------------------
    if ($LibationRoot -and (Test-Path -LiteralPath $LibationRoot)) {
        $cats = @(Get-ChildItem -LiteralPath $LibationRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d{2}\s*-\s*' })
        if ($cats.Count -eq 0) {
            $step++
            Write-Host "  [$step] No category folders found. Suggested:" -ForegroundColor White
            foreach ($c in $DefaultCategories) { Write-Host "        $c" -ForegroundColor DarkGray }
            if ((Read-Host "      Create them? (y/n)") -eq 'y') {
                foreach ($c in $DefaultCategories) {
                    New-Item -ItemType Directory -Path (Join-Path $LibationRoot $c) -Force | Out-Null
                    Write-Host "        + $c" -ForegroundColor Green
                }
                Write-Host ""
            } else { Write-Host "" }
        }
    }

    # --- config file ---------------------------------------------------
    $step++
    $cfgExists = Test-Path -LiteralPath $ConfigFile
    Write-Host "  [$step] Config file" -ForegroundColor White
    Write-Host "      Path         : $ConfigFile" -ForegroundColor DarkGray
    Write-Host "      LibationRoot : $LibationRoot" -ForegroundColor DarkGray
    Write-Host "      Remote       : $Remote" -ForegroundColor DarkGray
    $cfgPrompt = if ($cfgExists) { "      Already exists. Overwrite with the values above? (y/n)" }
                 else            { "      Write it? (y/n)" }
    if ((Read-Host $cfgPrompt) -eq 'y') {
        $json = [ordered]@{ LibationRoot = $LibationRoot; Remote = $Remote; LogFile = $LogFile } |
                    ConvertTo-Json
        # ConvertTo-Json escapes & < > ' as \uXXXX. Valid JSON, but this file is
        # meant to be hand-edited, so put the real characters back.
        $json = $json -replace '\\u0026', '&' -replace '\\u003c', '<' `
                      -replace '\\u003e', '>' -replace '\\u0027', "'"
        Set-Content -LiteralPath $ConfigFile -Value $json -Encoding utf8
        Write-Host "      Written.`n" -ForegroundColor Green
    } else { Write-Host "" }

    # --- desktop shortcut ----------------------------------------------
    $step++
    $launcher = Join-Path $ScriptDir "Sync Audiobooks.bat"
    $lnkPath  = Join-Path ([Environment]::GetFolderPath('Desktop')) "Sync Audiobooks.lnk"
    Write-Host "  [$step] Desktop shortcut" -ForegroundColor White
    Write-Host "      $lnkPath" -ForegroundColor DarkGray
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-Host "      Launcher not found next to this script - skipped." -ForegroundColor Yellow
        Write-Host "      ('Sync Audiobooks.bat' must sit in the same folder.)`n" -ForegroundColor Yellow
    }
    else {
        $verb = if (Test-Path -LiteralPath $lnkPath) { "Replace it?" } else { "Create it?" }
        if ((Read-Host "      $verb (y/n)") -eq 'y') {
            try {
                $ws  = New-Object -ComObject WScript.Shell
                $lnk = $ws.CreateShortcut($lnkPath)
                $lnk.TargetPath       = $launcher
                $lnk.WorkingDirectory = $ScriptDir
                $lnk.IconLocation     = "shell32.dll,44"
                $lnk.Description      = "Sort new Libation author folders into categories, then upload new books to Google Drive"
                $lnk.Save()
                Write-Host "      Created.`n" -ForegroundColor Green
            }
            catch {
                Write-Host "      Failed: $($_.Exception.Message)`n" -ForegroundColor Red
            }
        } else { Write-Host "" }
    }

    # --- things only you can do ----------------------------------------
    Write-Head "SET THESE IN LIBATION YOURSELF" 'Cyan'
    Write-Host @"
  These live inside Libation's own settings and cannot be set from here.

    Settings -> Important settings -> Books location
        $LibationRoot

    Settings -> Download/Decrypt -> folder format
        $ExpectedFolderTemplate

    Settings -> Download/Decrypt -> pdf and audio file format
        $ExpectedFileTemplate

    Settings -> Download/Decrypt -> In progress files
        System temporary folder   (never a cloud-synced folder)

  The folder format is the important one. It makes Libation drop new books
  at  <books folder>\<Author>\<Series>\ , at the top level. This tool then
  asks which category each new author belongs in and moves it there.
  Libation cannot create the category level itself - that is the whole
  reason this tool exists. Change that template and the sort step silently
  finds nothing.
"@ -ForegroundColor Gray

    # --- re-check so the user sees the result ---------------------------
    Invoke-Doctor -Root $LibationRoot -RemoteSpec $Remote | Out-Null
    $nowHealthy = Show-Doctor

    Write-Host ""
    if ($nowHealthy) {
        Write-Host "  Setup complete. Double-click 'Sync Audiobooks' to run." -ForegroundColor Green
    } else {
        Write-Host "  Still some items to fix above, then run setup again." -ForegroundColor Yellow
    }

    Write-Host ""
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit 0
}

if (-not $healthy) {
    Write-Host ""
    Write-Host "  Setup problems above must be fixed before syncing." -ForegroundColor Red
    Write-Host "  Run with -Setup for guided help." -ForegroundColor Red
    Write-Log "ABORTED - failed setup checks"
    if (-not $NoPause) { Read-Host "`nPress Enter to close" }
    exit 1
}

Write-Log "=== run started ==="

# ==================================================================
# STEP 1 - sort loose author folders into categories
# ==================================================================
$sorted = 0

if ($SkipSort) {
    Write-Head "STEP 1 - CATEGORY SORT (skipped)" 'DarkGray'
}
else {
    Write-Head "STEP 1 - SORT NEW AUTHOR FOLDERS" 'Cyan'

    # Discovered, not hard-coded, so adding "04 - Nonfiction" just works.
    $categories = @(Get-ChildItem -LiteralPath $LibationRoot -Directory |
                      Where-Object { $_.Name -match '^\d{2}\s*-\s*' } | Sort-Object Name)
    $loose = @(Get-ChildItem -LiteralPath $LibationRoot -Directory |
                 Where-Object { $_.Name -notmatch '^\d{2}\s*-\s*' } | Sort-Object Name)

    if ($loose.Count -eq 0) {
        Write-Host "  Nothing to sort - every author folder is already categorized." -ForegroundColor Green
    }
    else {
        Write-Host "  $($loose.Count) new author folder(s) need a category.`n" -ForegroundColor Yellow

        foreach ($folder in $loose) {
            $books = @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -in '.m4b', '.mp3', '.m4a' })
            $bytes = ($books | Measure-Object Length -Sum).Sum
            if (-not $bytes) { $bytes = 0 }

            Write-Host ("-" * 72) -ForegroundColor DarkGray
            Write-Host "  AUTHOR: $($folder.Name)" -ForegroundColor White
            Write-Host "  $($books.Count) audio file(s), $(Format-Size $bytes)"
            foreach ($b in ($books | Select-Object -First 6)) {
                Write-Host "     - $($b.Name)" -ForegroundColor DarkGray
            }
            if ($books.Count -gt 6) { Write-Host "     ... and $($books.Count - 6) more" -ForegroundColor DarkGray }

            Write-Host ""
            for ($i = 0; $i -lt $categories.Count; $i++) {
                Write-Host "     [$($i + 1)] $($categories[$i].Name)" -ForegroundColor Green
            }
            Write-Host "     [s] skip for now    [q] stop sorting" -ForegroundColor DarkGray

            $choice = Read-Host "`n  Category"
            if ($choice -eq 'q') { Write-Host "  Sorting stopped." -ForegroundColor Yellow; break }
            if ($choice -eq 's' -or [string]::IsNullOrWhiteSpace($choice)) {
                Write-Host "  Skipped." -ForegroundColor DarkGray; continue
            }

            $idx = 0
            if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $categories.Count) {
                Write-Host "  Not a valid choice - skipped." -ForegroundColor Yellow; continue
            }

            $target = Join-Path $categories[$idx - 1].FullName $folder.Name
            if ($DryRun) {
                Write-Host "  [DRY RUN] would move -> $target" -ForegroundColor Yellow
            }
            else {
                try {
                    Move-Merge -Src $folder.FullName -Dst $target
                    Write-Host "  Moved -> $($categories[$idx - 1].Name)\$($folder.Name)" -ForegroundColor Green
                    Write-Log "SORTED: $($folder.Name) -> $($categories[$idx - 1].Name)"
                    $sorted++
                }
                catch {
                    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Log "SORT FAILED: $($folder.Name) :: $($_.Exception.Message)"
                }
            }
        }
    }
}

# ==================================================================
# STEP 2 - diff against Google Drive
# ==================================================================
Write-Head "STEP 2 - COMPARING WITH GOOGLE DRIVE" 'Cyan'
Write-Host "  Reading remote file list (this takes a moment)..." -ForegroundColor DarkGray

$combined = Invoke-Rclone (@("check", $LibationRoot, $Remote) + $RcloneCommon + @("--combined", "-"))
$global:LASTEXITCODE = 0   # "check" exits 1 whenever differences exist; that is normal

$toUpload   = @($combined | Where-Object { $_ -like '+ *' } | ForEach-Object { $_.Substring(2) })
$remoteOnly = @($combined | Where-Object { $_ -like '- *' } | ForEach-Object { $_.Substring(2) })
$differing  = @($combined | Where-Object { $_ -like '* *' -and $_ -notlike '+ *' -and $_ -notlike '- *' -and $_ -notlike '= *' } |
                  ForEach-Object { $_.Substring(2) })

$uploadBytes = 0
foreach ($rel in $toUpload) {
    $p = Join-Path $LibationRoot ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $p) { $uploadBytes += (Get-Item -LiteralPath $p).Length }
}

if ($toUpload.Count -eq 0) {
    Write-Host "`n  Google Drive is already up to date. Nothing to upload." -ForegroundColor Green
}
else {
    Write-Host "`n  NEW - will be uploaded ($($toUpload.Count) files, $(Format-Size $uploadBytes)):" -ForegroundColor Green
    foreach ($f in $toUpload) { Write-Host "     + $f" -ForegroundColor Green }
}
if ($differing.Count -gt 0) {
    Write-Host "`n  CHANGED - local and Drive differ in size ($($differing.Count)):" -ForegroundColor Yellow
    foreach ($f in $differing) { Write-Host "     * $f" -ForegroundColor Yellow }
}

# ==================================================================
# STEP 3 - upload (additive only)
# ==================================================================
$uploadRan = $false

if ($toUpload.Count -gt 0 -or $differing.Count -gt 0) {
    if ($DryRun) {
        Write-Head "STEP 3 - UPLOAD (dry run, nothing sent)" 'Yellow'
    }
    else {
        Write-Host ""
        $go = Read-Host "  Upload $($toUpload.Count) file(s), $(Format-Size $uploadBytes), to Google Drive? (y/n)"
        if ($go -eq 'y') {
            Write-Head "STEP 3 - UPLOADING" 'Cyan'
            # "copy" (not "sync") - adds and overwrites, but never deletes.
            Invoke-Rclone -Passthru -Arguments (
                @("copy", $LibationRoot, $Remote) + $RcloneCommon +
                @("--progress", "--transfers", "4", "--drive-chunk-size", "64M")
            )
            if ($LASTEXITCODE -eq 0) {
                Write-Host "`n  Upload complete." -ForegroundColor Green
                Write-Log "UPLOADED $($toUpload.Count) files, $(Format-Size $uploadBytes)"
                $uploadRan = $true
            }
            else {
                Write-Host "`n  rclone reported errors (exit $LASTEXITCODE). See above." -ForegroundColor Red
                Write-Log "UPLOAD ERRORS exit=$LASTEXITCODE"
            }
        }
        else { Write-Host "  Upload skipped." -ForegroundColor DarkGray }
    }
}

# ==================================================================
# STEP 4 - alerts + summary
# ==================================================================
Write-Head "SUMMARY" 'Cyan'
Write-Host "  Author folders sorted : $sorted"
Write-Host "  Files uploaded        : $(if ($uploadRan) { $toUpload.Count } else { 0 })"
Write-Host "  Log                   : $LogFile"

if ($remoteOnly.Count -gt 0) {
    Write-Host ""
    Write-Host ("!" * 72) -ForegroundColor Yellow
    Write-Host "  ALERT - on Google Drive but NOT in the books folder ($($remoteOnly.Count))" -ForegroundColor Yellow
    Write-Host "  Nothing was deleted. Review these yourself:" -ForegroundColor Yellow
    Write-Host ("!" * 72) -ForegroundColor Yellow
    foreach ($f in $remoteOnly) { Write-Host "     - $f" -ForegroundColor Yellow }
    Write-Log "ALERT remote-only: $($remoteOnly.Count) -> $($remoteOnly -join '; ')"
    Write-Host ""
    Write-Host "  A file here usually means one of:" -ForegroundColor DarkGray
    Write-Host "    - you deleted or renamed it locally and Drive still has the old copy" -ForegroundColor DarkGray
    Write-Host "    - Google Drive made a duplicate (a ' (1)' name)" -ForegroundColor DarkGray
    Write-Host "    - it is a file you keep only on Drive (fine, ignore it)" -ForegroundColor DarkGray
}
else {
    Write-Host "`n  No unexpected files on Drive." -ForegroundColor Green
}

Write-Log "=== run finished ==="
if (-not $NoPause) { Write-Host ""; Read-Host "Press Enter to close" }
