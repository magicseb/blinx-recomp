# BlinxSetup.ps1 - installe Blinx: The Time Sweeper (recompilation PC).
#
# A partir de votre propre ISO du jeu : installe ce qui manque (Git, CMake,
# Ninja, Python + capstone, ffmpeg) avec winget, clone blinx-recomp et le
# toolkit xboxrecomp, extrait l'ISO, regenere le C, compile le jeu et son
# lanceur, et cree les raccourcis Bureau et menu Demarrer.
#
# Relancer le script met a jour (git pull) et recompile ; chaque etape deja
# faite est sautee. Windows PowerShell 5.1 suffit.
#
#   powershell -ExecutionPolicy Bypass -File BlinxSetup.ps1 [-InstallDir D:\Blinx] [-Iso jeu.iso]

param(
    [string]$InstallDir = '',
    [string]$Iso = '',
    [switch]$NoShortcuts,
    [switch]$Unattended     # no question at the end (and errors only printed)
)

$ErrorActionPreference = 'Stop'
$BlinxRepo = 'https://github.com/magicseb/blinx-recomp.git'
$ToolkitRepo = 'https://github.com/magicseb/xboxrecomp.git'
$ToolkitBranch = 'blinx'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Host.UI.RawUI.WindowTitle = 'Installation de Blinx'
$script:LogFile = $null

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    # Opened, written and closed at each line, sharing it with any reader;
    # a line that cannot be written (the file held by another program) is
    # lost from the log, never fatal.
    if ($script:LogFile) {
        try {
            $fs = New-Object System.IO.FileStream $script:LogFile, 'Append', 'Write', 'ReadWrite'
            $sw = New-Object System.IO.StreamWriter $fs, (New-Object System.Text.UTF8Encoding $false)
            $sw.WriteLine($msg)
            $sw.Dispose()
        } catch { }
    }
}
function Step([string]$msg) { Say ''; Say "==> $msg" 'Green' }
function Fail([string]$msg) {
    Say "ERREUR : $msg" 'Red'
    if (-not $Unattended) {
        [System.Windows.Forms.MessageBox]::Show($msg, 'Installation de Blinx',
            'OK', 'Error') | Out-Null
    }
    exit 1
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u;$env:LOCALAPPDATA\Microsoft\WinGet\Links"
}

function Find-Exe([string]$name, [string[]]$candidates) {
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -notlike '*\WindowsApps\*') { return $cmd.Source }
    return $null
}

function Winget-Install([string]$id, [string]$what) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "winget est introuvable : installez $what a la main, ou installez 'App Installer' depuis le Microsoft Store, puis relancez."
    }
    Say "    installation de $what (winget $id)..."
    & winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
    Refresh-Path
}

# Runs a long command with its output in a log file, showing the time spent
# and its last line, until it ends. Returns the exit code.
function Run-Logged([string]$exe, [string[]]$argv, [string]$cwd, [string]$log) {
    $err = "$log.err"
    $p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $cwd `
        -RedirectStandardOutput $log -RedirectStandardError $err -NoNewWindow -PassThru
    $t0 = Get-Date
    while (-not $p.HasExited) {
        Start-Sleep -Seconds 2
        $last = ''
        foreach ($f in @($log, $err)) {
            if (Test-Path $f) {
                $l = Get-Content $f -Tail 1 -ErrorAction SilentlyContinue
                if ($l) { $last = "$l" }
            }
        }
        if ($last.Length -gt 70) { $last = $last.Substring(0, 70) }
        $el = (Get-Date) - $t0
        Write-Host ("`r    {0:mm\:ss}  {1,-70}" -f $el, $last) -NoNewline
    }
    Write-Host ''
    $p.WaitForExit()
    return $p.ExitCode
}

function Bash-Path([string]$p) { return ($p -replace '\\', '/') }

# ---- 0. where -----------------------------------------------------------------

Say 'Blinx: The Time Sweeper - installation (recompilation PC)' 'Cyan'
Say 'Aucune donnee du jeu n''est fournie : il faut votre propre ISO du disque.'

if (-not $InstallDir) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Dossier d''installation de Blinx (environ 8 Go). Un chemin court, sans espace ni accent, par exemple C:\Blinx.'
    $dlg.SelectedPath = 'C:\'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -ne 'OK') { exit 1 }
    $InstallDir = $dlg.SelectedPath
    if ((Split-Path $InstallDir -Leaf) -ne 'Blinx' -and (Get-ChildItem $InstallDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $InstallDir = Join-Path $InstallDir 'Blinx'
    }
}
if ($InstallDir -match '[^\x21-\x7E]') {
    Fail "Le dossier '$InstallDir' contient un espace ou un accent : les outils de compilation n'en veulent pas. Choisissez par exemple C:\Blinx."
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallDir\logs" | Out-Null
$script:LogFile = "$InstallDir\logs\setup.log"
Say "Dossier : $InstallDir"

$drive = (Get-Item $InstallDir).PSDrive
if ($drive.Free -lt 8GB) {
    Fail ("Il faut environ 8 Go libres sur {0}: ({1:N1} Go libres)." -f $drive.Name, ($drive.Free / 1GB))
}

$BlinxDir = "$InstallDir\BLINX"
$ToolkitDir = "$InstallDir\xboxrecomp"
$DepsDir = "$InstallDir\deps"

if (-not (Test-Path "$BlinxDir\game_files\default.xbe") -and -not $Iso) {
    $o = New-Object System.Windows.Forms.OpenFileDialog
    $o.Title = 'Votre ISO de Blinx: The Time Sweeper (Xbox, version PAL)'
    $o.Filter = 'Image de disque Xbox (*.iso;*.xiso)|*.iso;*.xiso|Tous les fichiers (*.*)|*.*'
    if ($o.ShowDialog() -ne 'OK') { exit 1 }
    $Iso = $o.FileName
}

# ---- 1. tools -----------------------------------------------------------------

Step 'Outils (Git, CMake, Ninja, Python, ffmpeg)'
Refresh-Path

if (-not (Test-Path "$env:WINDIR\System32\vulkan-1.dll")) {
    Say '    ATTENTION : vulkan-1.dll est absent. Le jeu demande Vulkan 1.3 : mettez a jour le pilote de la carte graphique.' 'Yellow'
}

$git = Find-Exe 'git' @("$env:ProgramFiles\Git\cmd\git.exe")
if (-not $git) { Winget-Install 'Git.Git' 'Git for Windows'; $git = Find-Exe 'git' @("$env:ProgramFiles\Git\cmd\git.exe") }
$bash = "$env:ProgramFiles\Git\bin\bash.exe"
if (-not $git -or -not (Test-Path $bash)) { Fail 'Git for Windows (et son bash) est introuvable apres installation.' }
Say "    git    : $git"

$cmake = Find-Exe 'cmake' @("$env:ProgramFiles\CMake\bin\cmake.exe")
if (-not $cmake) { Winget-Install 'Kitware.CMake' 'CMake'; $cmake = Find-Exe 'cmake' @("$env:ProgramFiles\CMake\bin\cmake.exe") }
if (-not $cmake) { Fail 'CMake est introuvable apres installation.' }
Say "    cmake  : $cmake"

$ninja = Find-Exe 'ninja' @()
if (-not $ninja) { Winget-Install 'Ninja-build.Ninja' 'Ninja'; $ninja = Find-Exe 'ninja' @() }
if (-not $ninja) { Fail 'Ninja est introuvable apres installation.' }
Say "    ninja  : $ninja"

function Find-Python {
    # python on the PATH first: the py launcher can name an older install.
    $c = Find-Exe 'python' @()
    if ($c) { return $c }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $p = & py -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $p -and (Test-Path $p)) { return "$p".Trim() }
    }
    $g = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}
$python = Find-Python
if (-not $python) { Winget-Install 'Python.Python.3.12' 'Python 3'; $python = Find-Python }
if (-not $python) { Fail 'Python 3 est introuvable apres installation.' }
Say "    python : $python"
& $python -c "import capstone" 2>$null
if ($LASTEXITCODE -ne 0) {
    Say '    installation de capstone (pip)...'
    & $python -m pip install --user --quiet capstone
    & $python -c "import capstone" 2>$null
    if ($LASTEXITCODE -ne 0) { Fail 'Le module Python capstone n''a pas pu etre installe.' }
}

$ffmpeg = Find-Exe 'ffmpeg' @()
if (-not $ffmpeg) { Winget-Install 'Gyan.FFmpeg' 'ffmpeg (videos du jeu)'; $ffmpeg = Find-Exe 'ffmpeg' @() }
if (-not $ffmpeg) {
    $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { $ffmpeg = $g.FullName }
}
if ($ffmpeg) { Say "    ffmpeg : $ffmpeg" } else { Say '    ffmpeg introuvable : les videos du jeu seront sautees.' 'Yellow' }

$env:Path = "$(Split-Path $git);$(Split-Path $cmake);$(Split-Path $ninja);$(Split-Path $python);$env:Path"

# ---- 2. sources ---------------------------------------------------------------

Step 'Sources (blinx-recomp et le toolkit xboxrecomp)'
if (Test-Path "$BlinxDir\.git") {
    & $git -C $BlinxDir pull --ff-only
} else {
    & $git clone $BlinxRepo $BlinxDir
}
if ($LASTEXITCODE -ne 0) { Fail 'Le depot blinx-recomp n''a pas pu etre recupere (connexion internet ?).' }
if (Test-Path "$ToolkitDir\.git") {
    & $git -C $ToolkitDir pull --ff-only
} else {
    & $git clone -b $ToolkitBranch $ToolkitRepo $ToolkitDir
}
if ($LASTEXITCODE -ne 0) { Fail 'Le toolkit xboxrecomp n''a pas pu etre recupere.' }

# ---- 3. the disc --------------------------------------------------------------

Step 'Le disque du jeu'
if (Test-Path "$BlinxDir\game_files\default.xbe") {
    Say '    deja extrait.'
} else {
    Say "    extraction de $Iso (quelques minutes)..."
    $rc = Run-Logged $python @('-m', 'tools.xiso', 'unpack', "`"$Iso`"", '-o', "`"$BlinxDir\game_files`"") $ToolkitDir "$InstallDir\logs\xiso.log"
    if ($rc -ne 0 -or -not (Test-Path "$BlinxDir\game_files\default.xbe")) {
        Fail "L'ISO n'a pas pu etre extraite (voir $InstallDir\logs\xiso.log). Est-ce bien une image Xbox de Blinx ?"
    }
}

# ---- 4. toolchain, C, build -----------------------------------------------------

$env:BLINX_WINDEPS = Bash-Path $DepsDir
$env:XBOXRECOMP_DIR = Bash-Path $ToolkitDir
$env:FABLE_XBE = Bash-Path "$BlinxDir\game_files\default.xbe"
$env:PYTHON = Bash-Path $python
$env:BUILD_DIR = Bash-Path "$BlinxDir\build\mingw"

Step 'Chaine de compilation (llvm-mingw, SDL2, Vulkan, glslang ; ~1 Go, une seule fois)'
$rc = Run-Logged $bash @('tools/win/fetch-deps.sh') $BlinxDir "$InstallDir\logs\deps.log"
if ($rc -ne 0) { Fail "La chaine de compilation n'a pas pu etre installee (voir $InstallDir\logs\deps.log)." }

Step 'Recompilation du code du jeu en C (10 a 20 minutes)'
$gen = "$BlinxDir\src\recomp\gen\recomp_funcs.h"
$stamp = "$BlinxDir\build\regen.stamp"
$head = (& $git -C $BlinxDir rev-parse HEAD) + (& $git -C $ToolkitDir rev-parse HEAD)
if ((Test-Path $gen) -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $head)) {
    Say '    deja a jour.'
} else {
    $rc = Run-Logged $bash @('./regen.sh', '--disasm') $BlinxDir "$InstallDir\logs\regen.log"
    if ($rc -ne 0 -or -not (Test-Path $gen)) { Fail "La recompilation a echoue (voir $InstallDir\logs\regen.log)." }
    New-Item -ItemType Directory -Force -Path "$BlinxDir\build" | Out-Null
    Set-Content -Path $stamp -Value $head -Encoding ASCII
}

Step 'Compilation de l''executable (15 a 40 minutes selon le PC)'
$rc = Run-Logged $bash @('tools/win/build-mingw.sh', '-DBLINX_WIN_VULKAN=ON') $BlinxDir "$InstallDir\logs\build.log"
$GameDir = "$BlinxDir\build\mingw"
if ($rc -ne 0 -or -not (Test-Path "$GameDir\blinx_recomp.exe")) {
    Fail "La compilation a echoue (voir $InstallDir\logs\build.log)."
}

# ---- 5. launcher ----------------------------------------------------------------

Step 'Lanceur'
$clang = "$DepsDir\llvm-mingw\bin\x86_64-w64-mingw32-clang.exe"
$windres = "$DepsDir\llvm-mingw\bin\x86_64-w64-mingw32-windres.exe"

# The icon: a lime-green Xbox-style disc with a B, as a PNG inside an .ico.
$bmp = New-Object System.Drawing.Bitmap 256, 256
$gr = [System.Drawing.Graphics]::FromImage($bmp)
$gr.SmoothingMode = 'AntiAlias'
$gr.TextRenderingHint = 'AntiAliasGridFit'
$gr.Clear([System.Drawing.Color]::Transparent)
$rect = New-Object System.Drawing.Rectangle 8, 8, 240, 240
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, `
    ([System.Drawing.Color]::FromArgb(255, 0x9b, 0xe0, 0x3c)), ([System.Drawing.Color]::FromArgb(255, 0x10, 0x7c, 0x10)), 90
$gr.FillEllipse($brush, $rect)
$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 0x06, 0x30, 0x08)), 10
$gr.DrawEllipse($pen, 13, 13, 230, 230)
$font = New-Object System.Drawing.Font 'Segoe UI', 120, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = 'Center'
$fmt.LineAlignment = 'Center'
$gr.DrawString('B', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 6, 256, 256), $fmt)
$gr.Dispose()
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$ico = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $ico
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
$bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0)
$bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22)
$bw.Write($png)
$bw.Flush()
[System.IO.File]::WriteAllBytes("$GameDir\blinx.ico", $ico.ToArray())

Set-Content -Path "$GameDir\launcher.rc" -Value '1 ICON "blinx.ico"' -Encoding ASCII
& $windres "$GameDir\launcher.rc" -O coff -o "$GameDir\launcher.res"
if ($LASTEXITCODE -ne 0) { Fail 'Le lanceur n''a pas pu etre compile (icone).' }
& $clang -O2 -municode -mwindows "$BlinxDir\installer\launcher.c" "$GameDir\launcher.res" -o "$GameDir\Blinx.exe"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$GameDir\Blinx.exe")) { Fail 'Le lanceur n''a pas pu etre compile.' }

$cfg = @('# Variables donnees au jeu par Blinx.exe (CLE=VALEUR).')
if ($ffmpeg) { $cfg += "BLINX_FFMPEG=$ffmpeg" }
[System.IO.File]::WriteAllLines("$GameDir\launcher.cfg", $cfg)
Say "    $GameDir\Blinx.exe"

# ---- 6. shortcuts -----------------------------------------------------------------

if (-not $NoShortcuts) {
    Step 'Raccourcis'
    $sh = New-Object -ComObject WScript.Shell
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Blinx'
    New-Item -ItemType Directory -Force -Path $menu | Out-Null
    $links = @(
        @{ Path = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Blinx.lnk'); Target = "$GameDir\Blinx.exe"; Args = ''; Desc = 'Blinx: The Time Sweeper' },
        @{ Path = "$menu\Blinx.lnk"; Target = "$GameDir\Blinx.exe"; Args = ''; Desc = 'Blinx: The Time Sweeper' },
        @{ Path = "$menu\Mettre a jour Blinx.lnk"; Target = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe";
           Args = "-ExecutionPolicy Bypass -File `"$BlinxDir\installer\BlinxSetup.ps1`" -InstallDir `"$InstallDir`""; Desc = 'Met a jour et recompile Blinx' },
        @{ Path = "$menu\Journaux de Blinx.lnk"; Target = "$GameDir\logs"; Args = ''; Desc = 'Les journaux du jeu' }
    )
    New-Item -ItemType Directory -Force -Path "$GameDir\logs" | Out-Null
    foreach ($l in $links) {
        $s = $sh.CreateShortcut($l.Path)
        $s.TargetPath = $l.Target
        $s.Arguments = $l.Args
        $s.WorkingDirectory = $GameDir
        $s.IconLocation = "$GameDir\blinx.ico"
        $s.Description = $l.Desc
        $s.Save()
        Say "    $($l.Path)"
    }
}

Step 'Termine'
Say "Blinx est installe dans $InstallDir." 'Cyan'
Say 'Manette : Select+Start ouvre les reglages (F1 au clavier).'
if (-not $Unattended) {
    $r = [System.Windows.Forms.MessageBox]::Show("Blinx est installe.`n`nUn raccourci est sur le Bureau. Lancer le jeu maintenant ?",
        'Installation de Blinx', 'YesNo', 'Information')
    if ($r -eq 'Yes') { Start-Process -FilePath "$GameDir\Blinx.exe" -WorkingDirectory $GameDir }
}
