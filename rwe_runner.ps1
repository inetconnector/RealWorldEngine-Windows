Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force | Out-Null } catch { }

function Write-Section { param([string]$Text) Write-Host ""; Write-Host ("=== {0} ===" -f $Text) -ForegroundColor Cyan }
function Wait-ForEnter { param([string]$Message = "Press Enter to continue...") [void](Read-Host $Message) }

function Show-ErrorAndWait {
    param([string]$Context, [System.Exception]$Ex)
    Write-Host ""
    Write-Host ("[ERROR] {0}" -f $Context) -ForegroundColor Red
    if ($Ex) { Write-Host $Ex.ToString() -ForegroundColor DarkRed }
    Write-Host ""
    exit 1
}

function Minimize-ConsoleWindow {
    try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
'@ -ErrorAction SilentlyContinue | Out-Null
        $h = [Win32.NativeMethods]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) {
            [void][Win32.NativeMethods]::ShowWindowAsync($h, 6)
        }
    } catch { }
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
    $psi.Arguments = ("-NoProfile -WindowStyle Minimized -ExecutionPolicy Bypass -File `"{0}`"" -f $scriptPath)
    $psi.Verb = "runas"
    try { $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized } catch { }
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

function Get-PyWLauncherPath {
    $cmd = Get-Command "pyw.exe" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return "pyw.exe"
}

function Get-VideoControllers {
    try { return @(Get-CimInstance Win32_VideoController -ErrorAction Stop) } catch { return @() }
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

    if ($hasNvidia -and (Test-CommandExists "nvidia-smi")) { return "cuda" }
    if ($hasAmd -or $hasIntel -or $hasNvidia) { return "directml" }
    return "cpu"
}

function Test-VulkanRuntime {
    $paths = @(
        "$env:WINDIR\System32\vulkan-1.dll",
        "$env:WINDIR\SysWOW64\vulkan-1.dll"
    )
    foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { return $true } }
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
            if ($ramGb) { Write-Host ("  - {0} ({1} GB VRAM reported)" -f $n, $ramGb) }
            else { Write-Host ("  - {0}" -f $n) }
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

    $py = Join-Path (Split-Path -Parent $PipPath) "python.exe"
    if (-not (Test-Path -LiteralPath $py)) { throw ("Venv python not found next to pip: {0}" -f $py) }

    try {
        $ok = Test-BackendInPython -PythonPath $py -Backend $Backend
        if ($ok -eq 0) {
            Write-Host ("Torch backend already OK: {0} (skip install)" -f $Backend) -ForegroundColor Green
            return
        }
    } catch { }

    if ($Backend -eq "cuda") {
        & $py -m pip install --upgrade torch torchvision --index-url https://download.pytorch.org/whl/cu121
        return
    }

    if ($Backend -eq "directml") {
        & $py -m pip install --upgrade torch-directml
        return
    }

    & $py -m pip install --upgrade torch torchvision --index-url https://download.pytorch.org/whl/cpu
}

function Uninstall-TorchStack {
    param([Parameter(Mandatory=$true)][string]$PipPath)

    $pkgs = @("torch","torchvision","torchaudio","torchtext","torchdata","torch-directml")
    foreach ($p in $pkgs) {
        try { & $PipPath uninstall -y $p 2>$null | Out-Null } catch { }
    }
}

function Install-TorchStack {
    param(
        [Parameter(Mandatory=$true)][string]$PipPath,
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [Parameter(Mandatory=$true)][ValidateSet("cuda","directml","cpu")][string]$Backend
    )

    $st = Get-TorchStatus -PythonPath $PythonPath
    if ($st.has_torch) {
        Write-Host ("Torch already installed ({0}). Skipping torch install." -f $st.torch_version) -ForegroundColor Green
        return
    }

    if ($Backend -eq "cuda") {
        & $PipPath install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
        if ($LASTEXITCODE -ne 0) { throw "Torch CUDA install failed." }
        return
    }

    if ($Backend -eq "directml") {
        & $PipPath install torch-directml
        if ($LASTEXITCODE -ne 0) { throw "Torch DirectML install failed." }
        return
    }

    & $PipPath install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
    if ($LASTEXITCODE -ne 0) { throw "Torch CPU install failed." }
}

function Test-BackendInPython {
    param(
        [Parameter(Mandatory=$true)][string]$PythonPath,
        [Parameter(Mandatory=$true)][ValidateSet("cuda","directml","cpu")][string]$Backend
    )

    $code = @"
import sys
import importlib.util
import traceback

backend = sys.argv[1]

if backend == "cuda":
    try:
        import torch
        ok = torch.cuda.is_available()
        print("torch.cuda.is_available() =", ok)
        sys.exit(0 if ok else 2)
    except Exception:
        traceback.print_exc()
        sys.exit(2)

if backend == "directml":
    try:
        if importlib.util.find_spec("torch_directml") is None:
            print("DirectML not installed")
            sys.exit(2)
        import torch_directml
        d = torch_directml.device()
        print("torch_directml.device() =", d)
        sys.exit(0)
    except Exception:
        traceback.print_exc()
        sys.exit(2)

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

function Get-TorchStatus {
    param([Parameter(Mandatory=$true)][string]$PythonPath)

    $code = @'
import json
import importlib.util

out = {
  "has_torch": False,
  "torch_version": None,
  "cuda_available": False,
  "has_directml": False,
}

try:
  import torch
  out["has_torch"] = True
  out["torch_version"] = getattr(torch, "__version__", None)
  try:
    out["cuda_available"] = bool(torch.cuda.is_available())
  except Exception:
    out["cuda_available"] = False
except Exception:
  pass

try:
  out["has_directml"] = (importlib.util.find_spec("torch_directml") is not None)
except Exception:
  out["has_directml"] = False

print(json.dumps(out))
'@

    $tmp = Join-Path -Path $env:TEMP -ChildPath ("rwe_torch_status_{0}.py" -f ([Guid]::NewGuid().ToString("N")))
    Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8
    $raw = & $PythonPath $tmp 2>$null
    $exit = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
    if ($exit -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return @{ has_torch=$false; torch_version=$null; cuda_available=$false; has_directml=$false }
    }
    try { return ($raw | ConvertFrom-Json) } catch { return @{ has_torch=$false; torch_version=$null; cuda_available=$false; has_directml=$false } }
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

function Write-ProgressEvent {
    param(
        [string]$ProgressFile,
        [double]$Percent,
        [string]$Message,
        [string]$Phase = "bootstrap",
        [switch]$Close
    )
    if ([string]::IsNullOrWhiteSpace($ProgressFile)) { return }
    try {
        $obj = [ordered]@{
            ts = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            phase = $Phase
            percent = [double]$Percent
            message = $Message
        }
        if ($Close) { $obj.close = $true }
        $json = ($obj | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $ProgressFile -Value $json -Encoding UTF8
    } catch { }
}

function Start-LoadingUi {
    param(
        [string]$ProgressFile,
        [string]$AppDir,
        [string]$TokenFile = ""
    )
    try {
        if (-not (Test-Path -LiteralPath $ProgressFile)) { "" | Set-Content -LiteralPath $ProgressFile -Encoding UTF8 }
    } catch { }

    try {
        $pyLauncher = if (Command-Exists "pyw.exe") { Get-PyWLauncherPath } else { Get-PyLauncherPath }
        $ui = Join-Path $AppDir "rwe_loading_ui.py"
        if (-not (Test-Path -LiteralPath $ui)) { return $null }
        $args = @("-3.10", $ui, "--progress", $ProgressFile)
        if ($TokenFile -and -not [string]::IsNullOrWhiteSpace($TokenFile)) { $args += @("--token-file", $TokenFile) }
        $p = Start-Process -FilePath $pyLauncher -ArgumentList $args -PassThru -WindowStyle Normal
        return $p
    } catch {
        return $null
    }
}

function Test-UiAbort {
    param([System.Diagnostics.Process]$Proc)
    try { if ($Proc -and $Proc.HasExited) { return $true } } catch { }
    return $false
}

function Stop-LoadingUi {
    param([System.Diagnostics.Process]$Proc)
    try {
        if ($Proc -and (-not $Proc.HasExited)) {
            try { $Proc.CloseMainWindow() | Out-Null } catch { }
            try { $Proc.WaitForExit(1500) | Out-Null } catch { }
            if (-not $Proc.HasExited) {
                try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
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

    if ($has310) { Write-Host "Python 3.10 already installed (py -3.10 works)." -ForegroundColor Green; return }

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
    $venvHome = ($homeLine -split "=",2)[1].Trim()
    if ($venvHome -match "Python27" -or $venvHome -match "Python2") {
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

    function Invoke-VenvCreateCmd {
        param([string]$PyLauncher, [string]$VenvPath)

        $homeDir = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($homeDir)) { $homeDir = "C:\" }

        $drv = ""
        $pth = ""
        try {
            $drv = [System.IO.Path]::GetPathRoot($homeDir)
            if ($drv -and $drv.EndsWith("\")) { $drv = $drv.Substring(0, $drv.Length - 1) }
            if ($drv -and $homeDir.Length -gt $drv.Length) { $pth = $homeDir.Substring($drv.Length) }
        } catch { }

        $cmdParts = @()
        $cmdParts += ('set "USERPROFILE={0}"' -f $homeDir)
        if ($drv) { $cmdParts += ('set "HOMEDRIVE={0}"' -f $drv) }
        if ($pth) { $cmdParts += ('set "HOMEPATH={0}"' -f $pth) }
        $cmdParts += ('"{0}" -3.10 -m venv "{1}"' -f $PyLauncher, $VenvPath)
        $cmd = ($cmdParts -join " && ")

        $p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $cmd) -Wait -NoNewWindow -PassThru
        if ($p.ExitCode -ne 0) { throw ("Venv creation failed in cmd.exe (ExitCode={0})." -f $p.ExitCode) }
    }

    if (-not (Test-Path -LiteralPath $VenvPath)) {
        Write-Host ("Creating venv with Python 3.10: {0}" -f $VenvPath)

        $created = $false
        try {
            & $pyLauncher -3.10 -m venv $VenvPath
            if ($LASTEXITCODE -eq 0) { $created = $true }
        } catch { $created = $false }

        if (-not $created) {
            Write-Host "Venv creation failed in PowerShell. Retrying via cmd.exe..." -ForegroundColor Yellow
            Invoke-VenvCreateCmd -PyLauncher $pyLauncher -VenvPath $VenvPath
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

    $py = Join-Path (Split-Path -Parent $PipPath) "python.exe"
    if (-not (Test-Path -LiteralPath $py)) { throw ("Venv python not found next to pip: {0}" -f $py) }

    function Invoke-Pip {
        param(
            [Parameter(Mandatory=$true)][string]$PythonPath,
            [Parameter(Mandatory=$true)][string[]]$Args
        )
        & $PythonPath -m pip @Args 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw ("pip failed: {0}" -f (($Args -join " "))) }
    }

    function Get-PipPackageVersion {
        param([string]$PythonPath, [string]$Name)
        $code = @'
import sys
try:
    from importlib import metadata
except Exception:
    metadata = None

name = sys.argv[1]
if metadata is None:
    sys.exit(1)

try:
    v = metadata.version(name)
    sys.stdout.write(v)
except Exception:
    sys.exit(2)
'@
        $out = & $PythonPath -c $code $Name 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return ($out.ToString().Trim())
    }

    function Test-PipHasExact {
        param([string]$PythonPath, [string]$Spec)
        if ($Spec -match '^([A-Za-z0-9_\-]+)==(.+)$') {
            $name = $Matches[1]
            $want = $Matches[2]
            $have = Get-PipPackageVersion -PythonPath $PythonPath -Name $name
            return ($have -ne $null -and $have -eq $want)
        }
        $name = $Spec
        if ($name -match '^[A-Za-z0-9_\-]+$') {
            return ((Get-PipPackageVersion -PythonPath $PythonPath -Name $name) -ne $null)
        }
        return $false
    }

    function Ensure-PipSpec {
        param([string]$PythonPath, [string]$Spec)
        if (Test-PipHasExact -PythonPath $PythonPath -Spec $Spec) {
            Write-Host ("OK: {0}" -f $Spec) -ForegroundColor Green
            return
        }
        Write-Host ("Installing: {0}" -f $Spec) -ForegroundColor Cyan
        Invoke-Pip -PythonPath $PythonPath -Args @("install", $Spec)
    }

    Write-Host "Checking core Python packages..."
    Invoke-Pip -PythonPath $py -Args @("install","--upgrade","pip","setuptools","wheel","--no-warn-script-location")

    foreach ($tool in @("pip","setuptools","wheel")) {
        $v = Get-PipPackageVersion -PythonPath $py -Name $tool
        if ($v) { Write-Host ("OK: {0} {1}" -f $tool, $v) -ForegroundColor Green }
        else { throw ("Core tool missing after upgrade: {0}" -f $tool) }
    }

    Write-Host "Ensuring pinned diffusers stack (skip if already satisfied)..."
    foreach ($spec in @(
        "diffusers==0.30.3",
        "transformers==4.44.2",
        "accelerate==0.33.0",
        "safetensors==0.4.5",
        "huggingface_hub==0.24.7",
        "pillow",
        "numpy"
    )) { Ensure-PipSpec -PythonPath $py -Spec $spec }

    Write-Host "Ensuring model extras..."
    foreach ($spec in @("sentencepiece","protobuf")) { Ensure-PipSpec -PythonPath $py -Spec $spec }

    Write-Host "Ensuring analysis + PDF deps..."
    foreach ($spec in @("scikit-learn","pandas","reportlab","matplotlib")) { Ensure-PipSpec -PythonPath $py -Spec $spec }
}

function Prompt-Int {
    param([string]$Label, [int]$DefaultValue)
    while ($true) {
        $v = Read-Host ("{0} [{1}]" -f $Label, $DefaultValue)
        if ([string]::IsNullOrWhiteSpace($v)) { return $DefaultValue }
        if ($v -match '^\d+$') { return [int]$v }
        Write-Host "Please enter an integer." -ForegroundColor Yellow
    }
}

function Prompt-YesNo {
    param([string]$Label, [bool]$DefaultNo=$true)
    $suffix = if ($DefaultNo) { " [y/N]" } else { " [Y/n]" }
    while ($true) {
        $v = Read-Host ($Label + $suffix)
        if ([string]::IsNullOrWhiteSpace($v)) { return (-not $DefaultNo) }
        $t = $v.Trim().ToLowerInvariant()
        if ($t -eq "y" -or $t -eq "yes") { return $true }
        if ($t -eq "n" -or $t -eq "no") { return $false }
        Write-Host "Please enter y or n." -ForegroundColor Yellow
    }
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

    $required = @("initial_words","banned_motifs","stopwords","style_pool","novelty_motif_pool","escape_motifs")

    foreach ($k in $required) {
        if (-not ($cfg.PSObject.Properties.Name -contains $k)) { throw ("Config missing required key: {0}" -f $k) }
        $lst = Get-ConfigList -Section $cfg.$k
        if (-not $lst -or $lst.Count -lt 1) { throw ("Config key '{0}' must have a non-empty 'values' array." -f $k) }
    }

    $iters = Read-ConfigDefaultIterations -ConfigPath $ConfigPath -Fallback 10
    if ($iters -lt 1 -or $iters -gt 100000) { throw "Config runtime_defaults.values.iterations must be between 1 and 100000." }

    if ($cfg.slideshow -and $cfg.slideshow.values -and $cfg.slideshow.values.interval_seconds) {
        $interval = $cfg.slideshow.values.interval_seconds
        $parsed = 0.0
        if (-not [double]::TryParse([string]$interval, [ref]$parsed) -or $parsed -le 0) {
            throw "Config slideshow.values.interval_seconds must be a positive number."
        }
    }
}

function Apply-HFTokenFromFile {
    param([string]$TokenFile)
    try {
        if (-not $TokenFile) { return }
        if (-not (Test-Path -LiteralPath $TokenFile)) { return }
        $json = Get-Content -LiteralPath $TokenFile -Raw
        if ([string]::IsNullOrWhiteSpace($json)) { return }
        $o = $json | ConvertFrom-Json
        if ($o -and $o.use -and $o.token -and -not [string]::IsNullOrWhiteSpace([string]$o.token)) {
            $env:HF_TOKEN = [string]$o.token
        } else {
            if (Test-Path Env:HF_TOKEN) { Remove-Item Env:HF_TOKEN -ErrorAction SilentlyContinue | Out-Null }
        }
    } catch { }
}

function Get-HFHubCacheDir {
    $cache = $env:HUGGINGFACE_HUB_CACHE
    if (-not [string]::IsNullOrWhiteSpace($cache)) { return $cache }

    $hfHome = $env:HF_HOME
    if (-not [string]::IsNullOrWhiteSpace($hfHome)) {
        return (Join-Path $hfHome "hub")
    }

    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) { return $null }
    return (Join-Path (Join-Path $userProfile ".cache\\huggingface") "hub")
}

function Get-HFCacheDownloadBytes {
    param([string]$CacheDir)
    if ([string]::IsNullOrWhiteSpace($CacheDir)) { return 0 }
    if (-not (Test-Path -LiteralPath $CacheDir)) { return 0 }
    try {
        $total = 0
        Get-ChildItem -LiteralPath $CacheDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(incomplete|tmp|part)$' } |
            ForEach-Object { $total += $_.Length }
        return $total
    } catch {
        return 0
    }
}

function New-RunFolderNextToScript {
    param([string]$ScriptDir)
    $dateStamp = (Get-Date).ToString("yyyy-MM-dd")
    $base = Join-Path $ScriptDir $dateStamp
    Ensure-Folder $base
    $runStamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $run = Join-Path $base ("run-" + $runStamp)
    Ensure-Folder $run
    return $run
}

# FIXED: Non-blocking process streaming (handles carriage-return progress output like tqdm)
function Invoke-ProcessStreamingToProgress {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$ArgumentList,
        [Parameter(Mandatory=$true)][string]$ProgressFile,
        [Parameter(Mandatory=$true)][double]$Percent,
        [Parameter(Mandatory=$true)][string]$Phase,
        [string]$LogFile = "",
        [scriptblock]$HeartbeatInfo = $null
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true

    $q = New-Object System.Collections.Concurrent.ConcurrentQueue[string]

    $null = $p.Start()

    $reader = {
        param(
            [System.IO.Stream]$Stream,
            [System.Text.Encoding]$Encoding,
            [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue
        )
        $buffer = New-Object byte[] 4096
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $read = $Stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $text = $Encoding.GetString($buffer, 0, $read)
            foreach ($ch in $text.ToCharArray()) {
                if ($ch -eq "`r" -or $ch -eq "`n") {
                    if ($sb.Length -gt 0) {
                        $Queue.Enqueue($sb.ToString())
                        $null = $sb.Clear()
                    }
                } else {
                    $null = $sb.Append($ch)
                }
            }
        }
        if ($sb.Length -gt 0) { $Queue.Enqueue($sb.ToString()) }
    }

    $enc = [System.Text.Encoding]::UTF8
    try {
        if ($p.StartInfo.StandardOutputEncoding) { $enc = $p.StartInfo.StandardOutputEncoding }
    } catch { }

    $startReaderThread = {
        param(
            [System.IO.Stream]$Stream,
            [System.Text.Encoding]$Encoding,
            [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue
        )
        & $reader $Stream $Encoding $Queue
    }

    $outThread = New-Object System.Threading.Thread([System.Threading.ParameterizedThreadStart]{
        param($state)
        & $startReaderThread $state[0] $state[1] $state[2]
    })
    $errThread = New-Object System.Threading.Thread([System.Threading.ParameterizedThreadStart]{
        param($state)
        & $startReaderThread $state[0] $state[1] $state[2]
    })
    $outThread.IsBackground = $true
    $errThread.IsBackground = $true
    $outThread.Start(@($p.StandardOutput.BaseStream, $enc, $q))
    $errThread.Start(@($p.StandardError.BaseStream, $enc, $q))

    $lastUiTs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $lastOutputMs = $lastUiTs
    $lastHeartbeatMs = $lastUiTs
    $minIntervalMs = 250
    $heartbeatIntervalMs = 15000
    $stallHintMs = 30000

    while (-not $p.HasExited) {
        $line = $null
        $had = $false

        while ($q.TryDequeue([ref]$line)) {
            $had = $true

            if ($LogFile) {
                try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
            }

            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $lastOutputMs = $nowMs
            if (($nowMs - $lastUiTs) -ge $minIntervalMs) {
                $msg = $line.Trim()
                if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + "..." }
                Write-ProgressEvent -ProgressFile $ProgressFile -Percent $Percent -Message $msg -Phase $Phase
                $lastUiTs = $nowMs
            }
        }

        if (-not $had) {
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ((($nowMs - $lastOutputMs) -ge $stallHintMs) -and (($nowMs - $lastHeartbeatMs) -ge $heartbeatIntervalMs)) {
                $noOutputSec = [Math]::Round((($nowMs - $lastOutputMs) / 1000.0), 0)
                $logHint = ""
                if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
                    $logHint = " See " + [System.IO.Path]::GetFileName($LogFile) + "."
                }
                $extra = ""
                if ($HeartbeatInfo) {
                    try { $extra = & $HeartbeatInfo } catch { $extra = "" }
                }
                $msg = ("Still working... no output for {0}s.{1}{2}" -f $noOutputSec, $logHint, $extra)
                Write-ProgressEvent -ProgressFile $ProgressFile -Percent $Percent -Message $msg -Phase $Phase
                $lastHeartbeatMs = $nowMs
                $lastUiTs = $nowMs
            }
            Start-Sleep -Milliseconds 80
        }
    }

    # Flush remaining lines after exit
    $line2 = $null
    while ($q.TryDequeue([ref]$line2)) {
        if ($LogFile) {
            try { Add-Content -LiteralPath $LogFile -Value $line2 -Encoding UTF8 } catch { }
        }
        $m = $line2.Trim()
        if ($m.Length -gt 160) { $m = $m.Substring(0, 160) + "..." }
        Write-ProgressEvent -ProgressFile $ProgressFile -Percent $Percent -Message $m -Phase $Phase
    }

    $p.WaitForExit()
    try { $outThread.Join(2000) } catch { }
    try { $errThread.Join(2000) } catch { }

    if ($p.ExitCode -ne 0) {
        throw ("Process failed: {0} (ExitCode={1})" -f $FilePath, $p.ExitCode)
    }
}

function Find-LatestRunFolder {
    param([string]$ScriptDir)
    $dirs = Get-ChildItem -LiteralPath $ScriptDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
        Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $runs = Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^run-\d{8}-\d{6}$' } |
            Sort-Object Name -Descending
        foreach ($r in $runs) {
            $state = Join-Path (Join-Path $r.FullName "outputs") "world_state.json"
            $log   = Join-Path (Join-Path $r.FullName "outputs") "world_log.jsonl"
            if ((Test-Path -LiteralPath $state) -or (Test-Path -LiteralPath $log)) { return $r.FullName }
        }
    }
    return $null
}

function Prompt-Path {
    param([string]$Label, [string]$DefaultValue)
    while ($true) {
        $v = Read-Host ("{0} [{1}]" -f $Label, $DefaultValue)
        if ([string]::IsNullOrWhiteSpace($v)) { $v = $DefaultValue }
        $v = $v.Trim()
        if (Test-Path -LiteralPath $v) { return $v }
        Write-Host "Path not found. Please enter an existing path." -ForegroundColor Yellow
    }
}

function Assert-AppFiles {
    param([string]$AppDir)

    $missing = @()
    $req = @("rwe_v04.py","rwe_config_editor.py","rwe_slideshow.py","rwe_launcher.py")
    foreach ($f in $req) {
        $p = Join-Path $AppDir $f
        if (-not (Test-Path -LiteralPath $p)) { $missing += $f }
    }

    if ($missing.Count -gt 0) { throw ("Missing required file(s) in app folder: {0}" -f ($missing -join ", ")) }
}

function Write-RunSlideshowStarter {
    param([string]$RunRoot, [string]$AppDir)

    $starterPath = Join-Path $RunRoot "start_slideshow.ps1"
    $slideshowPy = Join-Path $AppDir "rwe_slideshow.py"

@"
Set-StrictMode -Version 2
`$ErrorActionPreference = "Stop"

function Resolve-PythonExe {
    param([string]`$RunRoot)
    `$scriptDir = Split-Path -Parent (Split-Path -Parent `$RunRoot)
    `$venvPy = Join-Path `$scriptDir "venv\Scripts\python.exe"
    if (Test-Path -LiteralPath `$venvPy) { return `$venvPy }
    `$cmd = Get-Command "python" -ErrorAction SilentlyContinue
    if (`$cmd -and `$cmd.Source) { return `$cmd.Source }
    return `$null
}

`$runRoot = `$PSScriptRoot
`$py = Resolve-PythonExe -RunRoot `$runRoot
if (-not `$py) {
    Write-Host "Python nicht gefunden. Bitte zuerst rwe_runner.ps1 ausfÃ¼hren." -ForegroundColor Red
    Read-Host "Enter drÃ¼cken zum Beenden"
    exit 1
}

`$slideshowPy = `"$slideshowPy`"
if (-not (Test-Path -LiteralPath `$slideshowPy)) {
    Write-Host "rwe_slideshow.py nicht gefunden: `$slideshowPy" -ForegroundColor Red
    Read-Host "Enter drÃ¼cken zum Beenden"
    exit 1
}

& `$py `$slideshowPy --run-root `$runRoot
"@ | Set-Content -LiteralPath $starterPath -Encoding UTF8

    return $starterPath
}

try {
    Assert-Or-Elevate
    Minimize-ConsoleWindow

    # NOTE: From here on, everything continues in Python UI (setup + config + generation).
    $scriptDir = Get-ScriptDir
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { throw "Could not determine script directory." }

    $bootstrapPy = Join-Path $scriptDir "app\rwe_bootstrap_ui.py"
    if (-not (Test-Path -LiteralPath $bootstrapPy)) { throw ("Missing bootstrap UI: {0}" -f $bootstrapPy) }

    $pywLauncher = $null
    try { $pywLauncher = (Get-Command "pyw.exe" -ErrorAction SilentlyContinue).Source } catch { $pywLauncher = $null }
    if ([string]::IsNullOrWhiteSpace($pywLauncher)) { $pywLauncher = "pyw.exe" }

    $pyLauncher = $null
    try { $pyLauncher = (Get-Command "py.exe" -ErrorAction SilentlyContinue).Source } catch { $pyLauncher = $null }
    if ([string]::IsNullOrWhiteSpace($pyLauncher)) { $pyLauncher = "py.exe" }

    $args = @("-3.10", "`"$bootstrapPy`"", "--repo", "`"$scriptDir`"")

    # Prefer pyw.exe to avoid console focus issues. Fall back to py.exe if needed.
    try {
        Start-Process -FilePath $pywLauncher -ArgumentList $args -WindowStyle Normal | Out-Null
    } catch {
        Start-Process -FilePath $pyLauncher -ArgumentList $args -WindowStyle Normal | Out-Null
    }

    return

    $scriptPath = Get-ScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw "This script must be saved as a .ps1 file." }
    $scriptDir = Get-ScriptDir
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { throw "Could not determine script directory." }

    $loadingUi = $null

    $configPath = Join-Path $scriptDir "rwe_config.json"
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Missing rwe_config.json next to this ps1." }

    $appDir   = Join-Path $scriptDir "app"
    $cacheDir = Join-Path $scriptDir "cache"
    $venvDir  = Join-Path $scriptDir "venv"

    Ensure-Folder $appDir
    Ensure-Folder $cacheDir

    Assert-AppFiles -AppDir $appDir

    Write-Section "Validate config"
    Validate-Config -ConfigPath $configPath
    Write-Host "Config OK." -ForegroundColor Green

    Write-Section "Resume mode"
    $runRoot = $null
    $latest = Find-LatestRunFolder -ScriptDir $scriptDir
    if ([string]::IsNullOrWhiteSpace($latest)) {
        Write-Host "No previous run folder found. Starting a new run." -ForegroundColor Yellow
        $runRoot = New-RunFolderNextToScript -ScriptDir $scriptDir
    } else {
        $runRoot = $latest
        Write-Host "Previous run folder found. Resuming latest run." -ForegroundColor Green
    }

    Write-Host ("Run folder: {0}" -f $runRoot) -ForegroundColor Cyan

    $outDir = Join-Path $runRoot "outputs"
    Ensure-Folder $outDir

    $runConfig = Join-Path $runRoot "rwe_config.json"
    if (-not (Test-Path -LiteralPath $runConfig)) { Copy-FileSafe -Src $configPath -Dst $runConfig }

    Write-RunSlideshowStarter -RunRoot $runRoot -AppDir $appDir | Out-Null

    $env:HF_HOME = $cacheDir

    Write-Section "Install prerequisites (Python 3.10, Git)"
    Install-Python310
    if (Test-UiAbort -Proc $loadingUi) { return }
    Install-Git
    if (Test-UiAbort -Proc $loadingUi) { return }

    $progressFile = Join-Path $runRoot "bootstrap_progress.jsonl"
    try { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

    $tokenFile = Join-Path $runRoot "hf_token.json"
    $loadingUi = Start-LoadingUi -ProgressFile $progressFile -AppDir $appDir -TokenFile $tokenFile
    if (Test-UiAbort -Proc $loadingUi) { return }

    Write-ProgressEvent -ProgressFile $progressFile -Percent 5 -Message "Prerequisites ready" -Phase "bootstrap"

    Write-Section "Create venv (Python 3.10)"
    Write-ProgressEvent -ProgressFile $progressFile -Percent 10 -Message "Creating or validating venv" -Phase "venv"
    $venvInfo = Ensure-Venv310 -VenvPath $venvDir
    if (Test-UiAbort -Proc $loadingUi) { return }

    $py  = $venvInfo.Py
    $pip = $venvInfo.Pip

    Write-ProgressEvent -ProgressFile $progressFile -Percent 20 -Message "Venv ready" -Phase "venv"

    Write-Section "Install packages"
    Write-ProgressEvent -ProgressFile $progressFile -Percent 25 -Message "Detecting hardware" -Phase "packages"
    Write-DetectedHardwareInfo

    $preferred = Get-PreferredBackend
    Write-Host ("Selected backend (pre-check): {0}" -f $preferred) -ForegroundColor Cyan

    $backend = $preferred
    $st = Get-TorchStatus -PythonPath $py

    if ($backend -eq "cuda") {
        if (-not ($st.has_torch -and $st.cuda_available)) {
            Install-TorchStack -PipPath $pip -PythonPath $py -Backend "cuda"
        }
        $verify = Test-BackendInPython -PythonPath $py -Backend "cuda"
        if ($verify -ne 0) {
            Write-Host "CUDA verify failed. Falling back to DirectML..." -ForegroundColor Yellow
            $backend = "directml"
        }
    }

    if ($backend -eq "directml") {
        $st = Get-TorchStatus -PythonPath $py
        if ($st.has_directml) {
            $verify = Test-BackendInPython -PythonPath $py -Backend "directml"
            if ($verify -ne 0) {
                Write-Host "DirectML verify failed. Falling back to CPU..." -ForegroundColor Yellow
                $backend = "cpu"
            }
        } else {
            if ($st.has_torch) {
                Write-Host "Torch is already installed. Skipping DirectML install to avoid changing the existing environment. Using CPU backend." -ForegroundColor Yellow
                $backend = "cpu"
            } else {
                Install-TorchStack -PipPath $pip -PythonPath $py -Backend "directml"
                $verify = Test-BackendInPython -PythonPath $py -Backend "directml"
                if ($verify -ne 0) {
                    Write-Host "DirectML verify failed. Falling back to CPU..." -ForegroundColor Yellow
                    $backend = "cpu"
                }
            }
        }
    }

    if ($backend -eq "cpu") {
        $st = Get-TorchStatus -PythonPath $py
        if (-not $st.has_torch) { Install-TorchStack -PipPath $pip -PythonPath $py -Backend "cpu" }
        $verify = Test-BackendInPython -PythonPath $py -Backend "cpu" | Out-Null
    }

    Write-Host ("Selected backend (verified): {0}" -f $backend) -ForegroundColor Green
    $env:RWE_BACKEND = $backend

    Write-ProgressEvent -ProgressFile $progressFile -Percent 55 -Message "Installing Python packages" -Phase "packages"
    Install-Pip-Packages -PipPath $pip
    if (Test-UiAbort -Proc $loadingUi) { return }

    $rwePy      = Join-Path $appDir "rwe_v04.py"
    $editorPy   = Join-Path $appDir "rwe_config_editor.py"
    $prefetchPy = Join-Path $appDir "rwe_prefetch_models.py"

    Apply-HFTokenFromFile -TokenFile $tokenFile

    Write-ProgressEvent -ProgressFile $progressFile -Percent 70 -Message "Prefetching models (downloads happen here)" -Phase "prefetch"

    if (Test-Path -LiteralPath $prefetchPy) {
        $prefetchLog = Join-Path $runRoot "prefetch_output.log"
        try { Remove-Item -LiteralPath $prefetchLog -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

        $env:RWE_PROGRESS = $progressFile
        $prevPyUnbuffered = $env:PYTHONUNBUFFERED
        $env:PYTHONUNBUFFERED = "1"

        $hfCacheDir = Get-HFHubCacheDir
        Invoke-ProcessStreamingToProgress `
            -FilePath $py `
            -ArgumentList @("-u", "`"$prefetchPy`"", "--progress", "`"$progressFile`"") `
            -ProgressFile $progressFile `
            -Percent 72 `
            -Phase "prefetch" `
            -LogFile $prefetchLog `
            -HeartbeatInfo {
                $bytes = Get-HFCacheDownloadBytes -CacheDir $hfCacheDir
                if ($bytes -gt 0) {
                    return (" Downloaded so far: {0} MB" -f [Math]::Round(($bytes / 1MB), 1))
                }
                return ""
            }

        if ($null -ne $prevPyUnbuffered) { $env:PYTHONUNBUFFERED = $prevPyUnbuffered }
        else { if (Test-Path Env:\PYTHONUNBUFFERED) { Remove-Item Env:\PYTHONUNBUFFERED -ErrorAction SilentlyContinue } }
        if (Test-Path Env:\RWE_PROGRESS) { Remove-Item Env:\RWE_PROGRESS -ErrorAction SilentlyContinue }
    }

    Write-ProgressEvent -ProgressFile $progressFile -Percent 90 -Message "Opening config editor" -Phase "bootstrap" -Close
    Stop-LoadingUi -Proc $loadingUi

    Write-Section "Config editor"
    $pyw = Join-Path $venvDir "Scripts\pythonw.exe"
    $cfgExit = 0
    if (Test-Path -LiteralPath $pyw) { & $pyw $editorPy --config $runConfig --defaults $configPath --outputs $outDir; $cfgExit = $LASTEXITCODE }
    else { & $py $editorPy --config $runConfig --defaults $configPath --outputs $outDir; $cfgExit = $LASTEXITCODE }

    if ($cfgExit -ne 0) {
        Write-Host "Config editor was closed. Continuing with the current config." -ForegroundColor Yellow
        # Legacy behavior (kept for reference; do not re-enable):
        # Write-Host "Config editor was closed. Exiting." -ForegroundColor Yellow
        # return
    }

    Write-Section "Validate config"
    Validate-Config -ConfigPath $runConfig
    Write-Host "Config OK." -ForegroundColor Green

    Write-Section "Run settings"
    $iters = Read-ConfigDefaultIterations -ConfigPath $runConfig -Fallback 10

    $env:RWE_CONFIG  = $runConfig
    $env:RWE_OUT     = $outDir
    $env:RWE_ITERS   = [string]$iters

    Write-Section "Start"
    Write-Host ("Python: {0}" -f $py) -ForegroundColor Green
    Write-Host ("Script: {0}" -f $rwePy) -ForegroundColor Green
    Write-Host ("Output: {0}" -f $outDir) -ForegroundColor Green

    & $py $rwePy

    if (Test-Path Env:\HF_TOKEN) { Remove-Item Env:\HF_TOKEN -ErrorAction SilentlyContinue }
    if (Test-Path Env:\RWE_CONFIG) { Remove-Item Env:\RWE_CONFIG -ErrorAction SilentlyContinue }
    if (Test-Path Env:\RWE_OUT) { Remove-Item Env:\RWE_OUT -ErrorAction SilentlyContinue }
    if (Test-Path Env:\RWE_ITERS) { Remove-Item Env:\RWE_ITERS -ErrorAction SilentlyContinue }
    if (Test-Path Env:\RWE_BACKEND) { Remove-Item Env:\RWE_BACKEND -ErrorAction SilentlyContinue }

    $pdfPath = Join-Path (Join-Path $outDir "atlas") "rwe_atlas_v04.pdf"

    Write-Section "Result"
    Write-Host ("Run folder: {0}" -f $runRoot) -ForegroundColor Cyan
    Write-Host ("Atlas PDF:  {0}" -f $pdfPath) -ForegroundColor Cyan

    if (Test-Path -LiteralPath $pdfPath) {
        Write-Section "Open PDF"
        Start-Process -FilePath $pdfPath | Out-Null
    } else {
        Write-Host "PDF not found (generation failed or path changed)." -ForegroundColor Yellow
    }
} catch {
    Show-ErrorAndWait "Fatal error." $_.Exception
} finally {
    try { Stop-LoadingUi -Proc $loadingUi } catch { }
}
