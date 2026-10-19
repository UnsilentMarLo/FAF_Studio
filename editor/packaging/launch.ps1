# FAF Studio launcher. Finds the FAForever game data, links it into the program folder, starts the editor and says so in plain words when it ends badly.
#
#   FAFStudio.cmd [map arguments]              normal start (the start screen, or /map <name> to open a map)
#   environment:  FAF_DATA          the FAForever data folder (default %ProgramData%\FAForever)
#                 FAFSTUDIO_USER  the folder for settings, logs, thumbnails (default %APPDATA%\FAFStudio)
#   -Test      no message boxes (text on the console), engine process id written to <user>\engine.pid, does not wait for the editor to end
#   FAFSTUDIO_NOGUI=1   no message boxes either, but waits and reports like a normal start (the package test uses it to check the crash message)
#   everything else is handed to the engine, e.g. /map my_map  or  /edcmd <file>
#
# What it does, in order: 1. look for the FAF data folder, 2. copy init_faf.lua / SupComDataPath.lua / fa_path.lua from it (FAF updates them), 3. link cache, gamedata,
# movies, sounds and themes into this folder (folder junctions: no copy, no admin rights), 4. start bin\FAFStudio.exe with the editor arguments, 5. when it ended with an
# error or left a crash report, show where the report is. The game data is only read, never changed or copied.

param(
    [switch]$Test,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'

function Show-Message([string]$text, [string]$icon = 'Error') {
    if ($Test -or $env:FAFSTUDIO_NOGUI) { Write-Host $text; return }
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show($text, 'FAF Studio', 'OK', $icon)
}

# ---- 1. the FAF data folder ---------------------------------------------------------------------------------------------------------------

$faf = $env:FAF_DATA
if (-not $faf) { $faf = Join-Path $env:ProgramData 'FAForever' }
$needed = @('gamedata', 'fa_path.lua', 'bin\init_faf.lua', 'bin\SupComDataPath.lua')
$missing = @($needed | Where-Object { -not (Test-Path (Join-Path $faf $_)) })
if ($missing.Count -gt 0) {
    Show-Message ("FAF Studio needs Supreme Commander: Forged Alliance with the FAForever client installed, and the game data of it.`n`n" +
        "Looked in: $faf`nMissing: " + ($missing -join ', ') + "`n`n" +
        "Install the FAForever client and start it once (it downloads the data), or set the environment variable FAF_DATA to the folder that holds 'gamedata'.`n" +
        "FAF Studio does not contain any game data.")
    exit 2
}

# ---- 2. files FAF keeps up to date ---------------------------------------------------------------------------------------------------------

Copy-Item (Join-Path $faf 'bin\init_faf.lua') $bin -Force
Copy-Item (Join-Path $faf 'bin\SupComDataPath.lua') $bin -Force
Copy-Item (Join-Path $faf 'fa_path.lua') $root -Force

# ---- 3. link the data ----------------------------------------------------------------------------------------------------------------------

foreach ($name in @('cache', 'gamedata', 'movies', 'sounds', 'themes')) {
    $target = Join-Path $faf $name
    if (-not (Test-Path $target)) { continue }
    $link = Join-Path $root $name
    $item = Get-Item $link -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.LinkType -eq 'Junction' -and ($item.Target | Select-Object -First 1) -eq $target) { continue }
        if ($item.LinkType -ne 'Junction') {
            Show-Message "The folder '$link' exists and is not a link to the FAF data. Rename or remove it and start again."
            exit 3
        }
        $item.Delete()
    }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
}

# ---- 4. start -------------------------------------------------------------------------------------------------------------------------------

$user = $env:FAFSTUDIO_USER
if (-not $user) { $user = Join-Path $env:APPDATA 'FAFStudio' }
# the editor was called SC Map Studio until 2026-10-19: its settings, workspaces and logs move to the new folder once
$oldUser = Join-Path $env:APPDATA 'SCMapStudio'
if (-not $env:FAFSTUDIO_USER -and (Test-Path $oldUser) -and -not (Test-Path $user)) { Move-Item $oldUser $user }
New-Item -ItemType Directory -Force -Path (Join-Path $user 'logs') | Out-Null
foreach ($d in @('mapout', 'modproj')) { New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null }
New-Item -ItemType Directory -Force -Path (Join-Path $bin 'config') | Out-Null
foreach ($f in @('editor_mods.txt', 'editor_mods_trial.txt')) {
    $p = Join-Path $bin $f
    if (-not (Test-Path $p)) { New-Item -ItemType File -Path $p | Out-Null }
}
$log = Join-Path $user 'logs\editor.log'
if (Test-Path $log) { Move-Item $log (Join-Path $user 'logs\editor.previous.log') -Force }

# a window that fits the screen (90 % of the work area, at most 1920 x 1080)
Add-Type -AssemblyName System.Windows.Forms
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$w = [Math]::Min(1920, [int]($area.Width * 0.9))
$h = [Math]::Min(1080, [int]($area.Height * 0.9))

$stamp = Get-Date
# an argument with a space is quoted for the engine's command line
$extra = @($ExtraArgs | Where-Object { $_ } | ForEach-Object { if ($_ -match '\s' -and $_ -notmatch '^"') { '"' + $_ + '"' } else { $_ } })
$engineArgs = @('/init', 'init_editor.lua', '/log', ('"' + $log + '"'), '/nomovie', '/nosound', '/windowed', "$w", "$h", '/editor', '/eduser', ('"' + $user + '"')) + $extra
$exe = Join-Path $bin 'FAFStudio.exe'
if (-not (Test-Path $exe)) { Show-Message "bin\FAFStudio.exe is missing: the package is incomplete."; exit 4 }
$p = Start-Process -FilePath $exe -ArgumentList $engineArgs -WorkingDirectory $bin -PassThru
if ($Test) {
    Set-Content -Path (Join-Path $user 'engine.pid') -Value $p.Id
    exit 0
}
$p.WaitForExit()

# ---- 5. the end -----------------------------------------------------------------------------------------------------------------------------

$reports = @(Get-ChildItem -Path $bin -Filter 'faf_crash_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $stamp } | Sort-Object LastWriteTime)
if ($reports.Count -gt 0 -or $p.ExitCode -ne 0) {
    $text = "FAF Studio stopped unexpectedly.`n`n"
    if ($reports.Count -gt 0) { $text += "Crash report: " + $reports[-1].FullName + "`n" }
    $text += "Log: $log`n`nYour work is not lost: if the editor autosaved, it offers to restore it the next time you start.`n" +
        "Please send the report and the log with a short description of what you were doing."
    Show-Message $text
}
exit $p.ExitCode
