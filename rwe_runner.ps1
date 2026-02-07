Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force | Out-Null } catch { }

function Write-Section { param([string]$Text) Write-Host ""; Write-Host ("=== {0} ===" -f $Text) -ForegroundColor Cyan }
function Wait-ForEnter { param([string]$Message = "Press Enter to continue...") [void](Read-Host $Message) }
function Hide-ConsoleWindow {
    try {
        $sig = @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        Add-Type -Name RweWin -Namespace Rwe -MemberDefinition $sig -ErrorAction SilentlyContinue | Out-Null
        $hwnd = [Rwe.RweWin]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [Rwe.RweWin]::ShowWindow($hwnd, 0) | Out-Null
        }
    } catch { }
}

function Show-ErrorAndWait {
    param([string]$Context, [System.Exception]$Ex)
    Write-Host ""
    Write-Host ("[ERROR] {0}" -f $Context) -ForegroundColor Red
    if ($Ex) { Write-Host $Ex.ToString() -ForegroundColor DarkRed }
    Write-Host ""
    Wait-ForEnter
}

function Get-ScriptPath {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) { return $PSCommandPath }
    try { $p = $MyInvocation.MyCommand.Path; if ($p -and (Test-Path -LiteralPath $p)) { return $p } } catch { }
    try { $d = $MyInvocation.MyCommand.Definition; if ($d -and (Test-Path -LiteralPath $d)) { return $d } } catch { }
    return $null
}

function Get-ScriptDir {
    $sp = Get-ScriptPath
    if ([string]::IsNullOrWhiteSpace($sp)) { return $null }
    return (Split-Path -Parent $sp)
}

function Get-PowerShellExe {
    if ($PSVersionTable.PSEdition -eq "Core") { return "pwsh.exe" }
    return "powershell.exe"
}

function Assert-Or-Elevate {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Host "Not elevated. Restarting as Administrator..." -ForegroundColor Yellow
    $scriptPath = Get-ScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw "This script must be saved as a .ps1 file to self-elevate." }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-PowerShellExe)
    $psi.Arguments = ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $scriptPath)
    $psi.Verb = "runas"
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    exit 0
}

function Ensure-Tls12 { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { } }
function Ensure-Folder { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null } }
function Command-Exists { param([string]$Name) try { (Get-Command $Name -ErrorAction SilentlyContinue) -ne $null } catch { $false } }
function Get-PyLauncherPath {
    $cmd = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return "py.exe"
}

function Get-VideoControllers {
    try {
        return @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Test-CommandExists {
    param([Parameter(Mandatory=$true)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return ($cmd -ne $null)
}

function Get-PreferredBackend {
    $gpus = Get-VideoControllers
    $names = @($gpus | ForEach-Object { $_.Name } | Where-Object { $_ })
    $joined = ($names -join " | ").ToLowerInvariant()

    $hasNvidia = $joined -match "nvidia"
    $hasAmd    = $joined -match "amd|radeon"
    $hasIntel  = $joined -match "intel|uhd|iris"

    if ($hasNvidia -and (Test-CommandExists "nvidia-smi")) {
        return "cuda"
    }

    if ($hasAmd -or $hasIntel -or $hasNvidia) {
        return "directml"
    }

    return "cpu"
}

function Test-VulkanRuntime {
    $paths = @(
        "$env:WINDIR\System32\vulkan-1.dll",
        "$env:WINDIR\SysWOW64\vulkan-1.dll"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return $false
}

function Write-DetectedHardwareInfo {
    $gpus = @(Get-VideoControllers)

    Write-Host ""
    Write-Host "Detected GPUs:" -ForegroundColor Cyan
    if ($gpus.Count -eq 0) {
        Write-Host "  (none found via WMI)" -ForegroundColor Yellow
    } else {
        foreach ($g in $gpus) {
            $n = $g.Name
            $ram = $g.AdapterRAM
            $ramGb = $null
            if ($ram -and $ram -gt 0) { $ramGb = [Math]::Round(($ram / 1GB), 1) }
            if ($ramGb) {
                Write-Host ("  - {0} ({1} GB VRAM reported)" -f $n, $ramGb)
            } else {
                Write-Host ("  - {0}" -f $n)
            }
        }
    }

    $vk = Test-VulkanRuntime
    Write-Host ("Vulkan runtime detected: {0}" -f ($(if ($vk) { "yes" } else { "no" }))) -ForegroundColor Cyan
}

function Install-TorchForBackend {
    param(
        [Parameter(Mandatory=$true)][string]$PipPath,
        [Parameter(Mandatory=$true)][ValidateSet("cuda","directml","cpu")][string]$Backend
    )

    if ($Backend -eq "cuda") {
        & $PipPath install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
        return
    }

    if ($Backend -eq "directml") {
        & $PipPath install --upgrade torch-directml
        return
    }

    & $PipPath install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
}

function Test-BackendInPython {
    param(
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [Parameter(Mandatory=$true)][ValidateSet("cuda","directml","cpu")][string]$Backend
    )

    $code = @"
import sys
import importlib.util
backend = sys.argv[1]

if backend == "cuda":
    import torch
    ok = torch.cuda.is_available()
    print("torch.cuda.is_available() =", ok)
    sys.exit(0 if ok else 2)

if backend == "directml":
    if importlib.util.find_spec("torch_directml") is None:
        print("DirectML not installed")
        sys.exit(2)
    import torch_directml
    d = torch_directml.device()
    print("torch_directml.device() =", d)
    sys.exit(0)

print("CPU backend selected")
sys.exit(0)
"@

    $tmp = Join-Path -Path $env:TEMP -ChildPath ("rwe_backend_test_{0}.py" -f ([Guid]::NewGuid().ToString("N")))
    Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8

    & $PythonPath $tmp $Backend
    $exit = $LASTEXITCODE

    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
    return $exit
}

function Download-File {
    param([Parameter(Mandatory=$true)][string]$Url,[Parameter(Mandatory=$true)][string]$OutFile)
    Ensure-Tls12
    Ensure-Folder ([System.IO.Path]::GetDirectoryName($OutFile))
    Write-Host ("Downloading: {0}" -f $Url)
    try {
        if ($PSVersionTable.PSVersion.Major -le 5) { Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing }
        else { Invoke-WebRequest -Uri $Url -OutFile $OutFile }
        return
    } catch { }
    $wc = New-Object System.Net.WebClient
    try { $wc.DownloadFile($Url, $OutFile) } finally { $wc.Dispose() }
}

function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    $user    = [System.Environment]::GetEnvironmentVariable("Path","User")
    if ($machine -and $user) { $env:Path = ($machine + ";" + $user) }
    elseif ($machine) { $env:Path = $machine }
}

function Winget-Install {
    param([string]$Id)
    Write-Host ("Installing via winget: {0}" -f $Id)
    $args = @("install","--id",$Id,"--exact","--silent","--accept-package-agreements","--accept-source-agreements")
    $p = Start-Process -FilePath "winget" -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ("winget install failed for {0} (ExitCode={1})." -f $Id, $p.ExitCode) }
}

function Install-Python310 {
    $has310 = $false
    if (Command-Exists "py.exe") {
        try {
            $pyLauncher = Get-PyLauncherPath
            $v = & $pyLauncher -3.10 -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null
            if ($LASTEXITCODE -eq 0 -and ($v -match "3\s+10")) { $has310 = $true }
        } catch { }
    }

    if ($has310) {
        Write-Host "Python 3.10 already installed (py -3.10 works)." -ForegroundColor Green
        return
    }

    if (Command-Exists "winget") {
        try { Winget-Install "Python.Python.3.10"; Refresh-Path } catch { }
    }

    $has310 = $false
    if (Command-Exists "py.exe") {
        try {
            $pyLauncher = Get-PyLauncherPath
            $v = & $pyLauncher -3.10 -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null
            if ($LASTEXITCODE -eq 0 -and ($v -match "3\s+10")) { $has310 = $true }
        } catch { }
    }

    if ($has310) { return }

    $tmp = Join-Path $env:TEMP "rwe_bootstrap"
    Ensure-Folder $tmp
    $pyUrl = "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe"
    $pyExe = Join-Path $tmp "python-3.10.11-amd64.exe"
    if (-not (Test-Path -LiteralPath $pyExe)) { Download-File -Url $pyUrl -OutFile $pyExe }
    $args = @("/quiet","InstallAllUsers=1","PrependPath=1","Include_test=0","SimpleInstall=1","SimpleInstallDescription=RWE")
    $p = Start-Process -FilePath $pyExe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ("Python installer failed (ExitCode={0})." -f $p.ExitCode) }
    Refresh-Path

    if (-not (Command-Exists "py.exe")) { throw "Python installed but py.exe launcher not found." }

    $pyLauncher = Get-PyLauncherPath
    $v = & $pyLauncher -3.10 -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not ($v -match "3\s+10")) { throw "Python 3.10 not available after install (py -3.10 failed)." }
}

function Install-Git {
    if (Command-Exists "git.exe") { Write-Host "Git already available in PATH." -ForegroundColor Green; return }
    if (Command-Exists "winget") {
        try { Winget-Install "Git.Git"; Refresh-Path; if (Command-Exists "git.exe") { return } } catch { }
    }
    $tmp = Join-Path $env:TEMP "rwe_bootstrap"
    Ensure-Folder $tmp
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.44.0.windows.1/Git-2.44.0-64-bit.exe"
    $gitExe = Join-Path $tmp "Git-2.44.0-64-bit.exe"
    if (-not (Test-Path -LiteralPath $gitExe)) { Download-File -Url $gitUrl -OutFile $gitExe }
    $args = @("/VERYSILENT","/NORESTART","/SUPPRESSMSGBOXES")
    $p = Start-Process -FilePath $gitExe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ("Git installer failed (ExitCode={0})." -f $p.ExitCode) }
    Refresh-Path
    if (-not (Command-Exists "git.exe")) { throw "git.exe not found after installation." }
}

function Copy-FileSafe {
    param([string]$Src,[string]$Dst)
    try {
        Ensure-Folder (Split-Path -Parent $Dst)
        Copy-Item -LiteralPath $Src -Destination $Dst -Force
    } catch { }
}

function Remove-VenvIfWrongPython {
    param([string]$VenvPath)
    $cfg = Join-Path $VenvPath "pyvenv.cfg"
    if (-not (Test-Path -LiteralPath $cfg)) { return }
    $content = Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue
    if (-not $content) { return }
    $homeLine = ($content | Where-Object { $_ -match "^home\s*=" } | Select-Object -First 1)
    if (-not $homeLine) { return }
    $home = ($homeLine -split "=",2)[1].Trim()
    if ($home -match "Python27" -or $home -match "Python2") {
        Write-Host "Detected wrong venv base (Python 2.x). Recreating venv..." -ForegroundColor Yellow
        try { Remove-Item -LiteralPath $VenvPath -Recurse -Force -ErrorAction Stop } catch { }
    }
}

function Ensure-Venv310 {
    param([string]$VenvPath)

    Ensure-Folder (Split-Path -Parent $VenvPath)
    if (Test-Path -LiteralPath $VenvPath) { Remove-VenvIfWrongPython -VenvPath $VenvPath }

    if (-not (Command-Exists "py.exe")) { throw "py.exe not found. Install Python 3.10 first." }

    $pyLauncher = Get-PyLauncherPath
    $v = & $pyLauncher -3.10 -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not ($v -match "3\s+10")) { throw "Python 3.10 is not available (py -3.10 failed)." }

    if (-not (Test-Path -LiteralPath $VenvPath)) {
        Write-Host ("Creating venv with Python 3.10: {0}" -f $VenvPath)
        $homeFallback = $env:USERPROFILE

        $venvCreated = $false
        try {
            & $pyLauncher -3.10 -m venv $VenvPath
            if ($LASTEXITCODE -eq 0) { $venvCreated = $true }
        } catch {
            $venvCreated = $false
        }

        if (-not $venvCreated -and -not [string]::IsNullOrWhiteSpace($homeFallback)) {
            Write-Host "Venv creation failed in PowerShell. Retrying via cmd.exe to avoid HOME variable errors..." -ForegroundColor Yellow
            $cmd = "set HOME=$homeFallback && `"$pyLauncher`" -3.10 -m venv `"$VenvPath`""
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $cmd) -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -ne 0) {
                throw ("Venv creation failed in cmd.exe as well (ExitCode={0})." -f $proc.ExitCode)
            }
        } elseif (-not $venvCreated) {
            throw "Venv creation failed and HOME fallback is unavailable."
        }
    } else {
        Write-Host ("Venv exists: {0}" -f $VenvPath) -ForegroundColor Green
    }

    $py = Join-Path $VenvPath "Scripts\python.exe"
    $pip = Join-Path $VenvPath "Scripts\pip.exe"
    if (-not (Test-Path -LiteralPath $py))  { throw ("Venv python not found: {0}" -f $py) }
    if (-not (Test-Path -LiteralPath $pip)) { throw ("Venv pip not found: {0}" -f $pip) }

    $ver = & $py -c "import sys; print(sys.version_info[0], sys.version_info[1])" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not ($ver -match "3\s+10")) { throw "Venv is not Python 3.10. Delete the venv folder and rerun." }

    return @{ Py=$py; Pip=$pip }
}

function Install-Pip-Packages {
    param([string]$PipPath)

    Write-Host "Upgrading pip tooling..."
    & $PipPath install --upgrade pip wheel setuptools

    Write-Host "Installing pinned diffusers stack..."
    & $PipPath install `
        "diffusers==0.30.3" `
        "transformers==4.44.2" `
        "accelerate==0.33.0" `
        "safetensors==0.4.5" `
        "huggingface_hub==0.24.7" `
        pillow numpy

    Write-Host "Installing model extras..."
    & $PipPath install sentencepiece protobuf

    Write-Host "Installing analysis + PDF deps..."
    & $PipPath install scikit-learn pandas reportlab matplotlib
}

function Read-ConfigDefaultIterations {
    param([string]$ConfigPath, [int]$Fallback)
    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($cfg -and $cfg.runtime_defaults -and $cfg.runtime_defaults.values -and $cfg.runtime_defaults.values.iterations) {
            $n = [int]$cfg.runtime_defaults.values.iterations
            if ($n -gt 0) { return $n }
        }
    } catch { }
    return $Fallback
}

function Get-ConfigList {
    param($Section)
    if ($Section -eq $null) { return @() }
    if ($Section.PSObject.Properties.Name -contains "values") {
        $v = $Section.values
        if ($v -is [System.Array]) { return @($v) }
        return @()
    }
    if ($Section -is [System.Array]) { return @($Section) }
    return @()
}

function Validate-Config {
    param([string]$ConfigPath)

    $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop

    $required = @(
        "initial_words",
        "banned_motifs",
        "stopwords",
        "style_pool",
        "novelty_motif_pool",
        "escape_motifs"
    )

    foreach ($k in $required) {
        if (-not ($cfg.PSObject.Properties.Name -contains $k)) {
            throw ("Config missing required key: {0}" -f $k)
        }
        $lst = Get-ConfigList -Section $cfg.$k
        if (-not $lst -or $lst.Count -lt 1) {
            throw ("Config key '{0}' must have a non-empty 'values' array." -f $k)
        }
    }

    $iters = Read-ConfigDefaultIterations -ConfigPath $ConfigPath -Fallback 10
    if ($iters -lt 1 -or $iters -gt 100000) {
        throw "Config runtime_defaults.values.iterations must be between 1 and 100000."
    }

    if ($cfg.slideshow -and $cfg.slideshow.values -and $cfg.slideshow.values.interval_seconds) {
        $interval = $cfg.slideshow.values.interval_seconds
        $parsed = 0.0
        if (-not [double]::TryParse([string]$interval, [ref]$parsed) -or $parsed -le 0) {
            throw "Config slideshow.values.interval_seconds must be a positive number."
        }
    }
}

function Read-LaunchOptions {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Write-ProgressEvent {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Phase,
        [Parameter(Mandatory=$true)][string]$Message,
        [int]$Percent = -1,
        [bool]$Close = $false
    )

    $obj = @{
        ts = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        phase = $Phase
        message = $Message
    }
    if ($Percent -ge 0) { $obj.percent = $Percent }
    if ($Close) { $obj.close = $true; $obj.done = $true }
    ($obj | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Read-UiAction {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($obj -and $obj.action) { return [string]$obj.action }
    } catch { }
    return ""
}

function Stop-ProcessSafe {
    param([System.Diagnostics.Process]$Proc)
    if (-not $Proc) { return }
    try { $Proc.Refresh() } catch { }
    if ($Proc.HasExited) { return }
    try { $Proc.CloseMainWindow() | Out-Null } catch { }
    Start-Sleep -Milliseconds 500
    try { $Proc.Refresh() } catch { }
    if (-not $Proc.HasExited) {
        try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}

try {
    Assert-Or-Elevate

    $scriptPath = Get-ScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw "This script must be saved as a .ps1 file." }
    $scriptDir = Get-ScriptDir
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { throw "Could not determine script directory." }

    $configPath = Join-Path $scriptDir "rwe_config.json"

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Missing rwe_config.json next to this ps1."
    }

    Write-Section "Validate config"
    Validate-Config -ConfigPath $configPath
    Write-Host "Config OK." -ForegroundColor Green

    $appDir   = Join-Path $scriptDir "app"
    $cacheDir = Join-Path $scriptDir "cache"
    $venvDir  = Join-Path $scriptDir "venv"

    Ensure-Folder $appDir
    Ensure-Folder $cacheDir

    $env:HF_HOME = $cacheDir

    $rwePy = Join-Path $appDir "rwe_v04.py"
    $launcherPy = Join-Path $appDir "rwe_launcher.py"
    $runUiPy = Join-Path $appDir "rwe_run_ui.py"
    $slideshowPy = Join-Path $appDir "rwe_slideshow.py"
    if (-not (Test-Path -LiteralPath $rwePy)) { throw "Missing app script: $rwePy. Please reinstall or restore the app folder." }
    if (-not (Test-Path -LiteralPath $launcherPy)) { throw "Missing app script: $launcherPy. Please reinstall or restore the app folder." }
    if (-not (Test-Path -LiteralPath $runUiPy)) { throw "Missing app script: $runUiPy. Please reinstall or restore the app folder." }
    if (-not (Test-Path -LiteralPath $slideshowPy)) { throw "Missing app script: $slideshowPy. Please reinstall or restore the app folder." }

    $py = Join-Path $venvDir "Scripts\\python.exe"
    if (-not (Test-Path -LiteralPath $py)) {
        throw "Python venv not found at '$py'. Run rwe_installer.ps1 first."
    }

    $runConfigShared = Join-Path $scriptDir "rwe_config_run.json"
    $launchOut = Join-Path $scriptDir "last_launch.json"

    $keepRunning = $true
    while ($keepRunning) {
        Write-Section "Launcher"
        & $py $launcherPy --script-dir $scriptDir --config-default $configPath --config-run $runConfigShared --python $py --launch-out $launchOut

        $launch = Read-LaunchOptions -Path $launchOut
        if (-not $launch -or -not $launch.run_root) {
            Write-Host "Launcher closed without starting a run." -ForegroundColor Yellow
            break
        }

        $runRoot = $launch.run_root
        if (-not (Test-Path -LiteralPath $runRoot)) { throw ("Run folder not found: {0}" -f $runRoot) }

        $outDir   = Join-Path $runRoot "outputs"
        Ensure-Folder $outDir

        $runConfig = Join-Path $runRoot "rwe_config.json"
        if (Test-Path -LiteralPath $runConfigShared) {
            Copy-FileSafe -Src $runConfigShared -Dst $runConfig
        } elseif (-not (Test-Path -LiteralPath $runConfig)) {
            Copy-FileSafe -Src $configPath -Dst $runConfig
        }

        Write-DetectedHardwareInfo
        $backendFile = Join-Path $scriptDir "rwe_backend.txt"
        $backendPref = $launch.backend
        if ([string]::IsNullOrWhiteSpace($backendPref)) { $backendPref = "auto" }
        if ($backendPref -eq "auto") {
            if (Test-Path -LiteralPath $backendFile) {
                $backendPref = (Get-Content -LiteralPath $backendFile -Raw -ErrorAction SilentlyContinue).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($backendPref)) {
                $backendPref = Get-PreferredBackend
            }
        }

        if ([string]::IsNullOrWhiteSpace($backendPref)) { $backendPref = "cpu" }
        $verify = Test-BackendInPython -PythonPath $py -Backend $backendPref
        if ($verify -ne 0) {
            Write-Host ("Backend '{0}' failed to verify. Falling back to CPU." -f $backendPref) -ForegroundColor Yellow
            $backendPref = "cpu"
        }
        Write-Host ("Selected backend: {0}" -f $backendPref) -ForegroundColor Green
        $env:RWE_BACKEND = $backendPref

        Write-Section "Validate config"
        Validate-Config -ConfigPath $runConfig
        Write-Host "Config OK." -ForegroundColor Green

        $iters = $launch.iterations
        if (-not $iters -or $iters -lt 1) {
            $iters = Read-ConfigDefaultIterations -ConfigPath $runConfig -Fallback 10
        }

        $env:RWE_CONFIG = $runConfig
        $env:RWE_OUT    = $outDir
        $env:RWE_ITERS  = [string]$iters
        if ($launch.show_images) { $env:RWE_SHOW_IMAGES = "1" }
        if ($launch.hf_token) { $env:HF_TOKEN = $launch.hf_token }

        $progressFile = Join-Path $runRoot "progress.jsonl"
        $logFile = Join-Path $runRoot "out.log"
        $errFile = ""
        $doneFlag = Join-Path $runRoot "done.flag"
        $worldLog = Join-Path $outDir "world_log.jsonl"
        $controlFile = Join-Path $runRoot "ui_control.json"
        if (Test-Path -LiteralPath $doneFlag) { Remove-Item -LiteralPath $doneFlag -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $controlFile) { Remove-Item -LiteralPath $controlFile -Force -ErrorAction SilentlyContinue }

        Write-ProgressEvent -Path $progressFile -Phase "setup" -Message "RWE startet..." -Percent 1

        Write-Section "Start"
        Write-Host ("Python: {0}" -f $py) -ForegroundColor Green
        Write-Host ("Script: {0}" -f $rwePy) -ForegroundColor Green
        Write-Host ("Output: {0}" -f $outDir) -ForegroundColor Green

        $pyw = $null
        try {
            $cand = Join-Path (Split-Path -Parent $py) "pythonw.exe"
            if (Test-Path -LiteralPath $cand) { $pyw = $cand }
        } catch { }
        if (-not $pyw) { $pyw = $py }

        $runUiProc = Start-Process -FilePath $pyw -ArgumentList @(
            $runUiPy,
            "--run-root", $runRoot,
            "--out-dir", $outDir,
            "--progress-file", $progressFile,
            "--log-file", $logFile,
            "--error-log", $errFile,
            "--world-log", $worldLog,
            "--done-flag", $doneFlag,
            "--control-file", $controlFile
        ) -PassThru

        Write-ProgressEvent -Path $progressFile -Phase "run" -Message "Generierung läuft..." -Percent 5

        Hide-ConsoleWindow

        Set-Content -LiteralPath $logFile -Value "" -Encoding UTF8
        $runProc = Start-Process -FilePath "cmd.exe" -ArgumentList @(
            "/c",
            "`"$py`" `"$rwePy`" 1>> `"$logFile`" 2>>&1"
        ) -WindowStyle Hidden -PassThru

        $requestedAction = ""
        while ($true) {
            try { $runProc.Refresh() } catch { }
            if ($runProc.HasExited) { break }
            $requestedAction = Read-UiAction -Path $controlFile
            if ($requestedAction) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $requestedAction) {
            $requestedAction = Read-UiAction -Path $controlFile
        }

        if ($requestedAction) {
            Stop-ProcessSafe -Proc $runProc
        }
        try { $runProc.WaitForExit() } catch { }

        $doneMessage = "Generierung abgeschlossen."
        if ($requestedAction -eq "cancel") { $doneMessage = "Run cancelled." }
        if ($requestedAction -eq "new") { $doneMessage = "Run stopped. Starting new run..." }

        Write-ProgressEvent -Path $progressFile -Phase "done" -Message $doneMessage -Percent 100 -Close $true
        Set-Content -LiteralPath $doneFlag -Value "done" -Encoding UTF8

        if ($runUiProc -and -not $runUiProc.HasExited) {
            Stop-ProcessSafe -Proc $runUiProc
        }

        if (Test-Path Env:\RWE_CONFIG) { Remove-Item Env:\RWE_CONFIG -ErrorAction SilentlyContinue }
        if (Test-Path Env:\RWE_OUT) { Remove-Item Env:\RWE_OUT -ErrorAction SilentlyContinue }
        if (Test-Path Env:\RWE_ITERS) { Remove-Item Env:\RWE_ITERS -ErrorAction SilentlyContinue }
        if (Test-Path Env:\RWE_BACKEND) { Remove-Item Env:\RWE_BACKEND -ErrorAction SilentlyContinue }
        if (Test-Path Env:\RWE_SHOW_IMAGES) { Remove-Item Env:\RWE_SHOW_IMAGES -ErrorAction SilentlyContinue }
        if (Test-Path Env:\HF_TOKEN) { Remove-Item Env:\HF_TOKEN -ErrorAction SilentlyContinue }

        if ($requestedAction -eq "new") {
            if (Test-Path -LiteralPath $runRoot) {
                Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            $keepRunning = $true
            continue
        }

        if ($requestedAction -eq "cancel") {
            break
        }

        $pdfPath = Join-Path (Join-Path $outDir "atlas") "rwe_atlas_v04.pdf"

        Write-Section "Result"
        Write-Host ("Run folder: {0}" -f $runRoot) -ForegroundColor Cyan
        Write-Host ("Atlas PDF:  {0}" -f $pdfPath) -ForegroundColor Cyan

        if (-not (Test-Path -LiteralPath $pdfPath)) {
            Write-Host "PDF not found (generation failed or path changed)." -ForegroundColor Yellow
        }

        Write-Section "Slideshow"
        & $py $slideshowPy --run-root $runRoot

        Wait-ForEnter "Press Enter to exit..."
        break
    }
} catch {
    Show-ErrorAndWait "Fatal error." $_.Exception
}
