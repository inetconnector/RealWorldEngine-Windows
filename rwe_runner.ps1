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
        return Get-CimInstance Win32_VideoController -ErrorAction Stop
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
    $gpus = Get-VideoControllers
    Write-Host ""
    Write-Host "Detected GPUs:" -ForegroundColor Cyan
    if (-not $gpus -or $gpus.Count -eq 0) {
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
        & $pyLauncher -3.10 -m venv $VenvPath
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

function Find-LatestRunFolder {
    param([string]$ScriptDir)
    $dirs = Get-ChildItem -LiteralPath $ScriptDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending
    foreach ($d in $dirs) {
        $runs = Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^run-\d{8}-\d{6}$' } | Sort-Object Name -Descending
        foreach ($r in $runs) {
            $state = Join-Path (Join-Path $r.FullName "outputs") "world_state.json"
            $log = Join-Path (Join-Path $r.FullName "outputs") "world_log.jsonl"
            if (Test-Path -LiteralPath $state -or Test-Path -LiteralPath $log) {
                return $r.FullName
            }
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

function Write-RWE-Python {
    param([string]$AppDir)

    Ensure-Folder $AppDir
    $rwePy = Join-Path $AppDir "rwe_v04.py"

@'
import os
import re
import json
import time
import math
import random
import subprocess
import sys
import importlib.util
import textwrap
from dataclasses import dataclass, asdict
from typing import List, Dict, Any, Optional, Tuple

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont

from huggingface_hub import login
from diffusers import StableDiffusionXLPipeline, StableDiffusionPipeline
from transformers import (
    BlipProcessor, BlipForConditionalGeneration,
    CLIPProcessor, CLIPModel
)

from sklearn.cluster import KMeans
from sklearn.metrics import silhouette_score

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas
from reportlab.lib.units import mm

def _as_list(v: Any) -> List[str]:
    if isinstance(v, list):
        out: List[str] = []
        for x in v:
            if x is None:
                continue
            s = str(x).strip()
            if s:
                out.append(s)
        return out
    if isinstance(v, dict) and "values" in v:
        return _as_list(v.get("values"))
    return []

def load_config(path: str) -> Dict[str, Any]:
    if not path:
        return {}
    try:
        if not os.path.exists(path):
            return {}
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}

_CFG_PATH = os.environ.get("RWE_CONFIG", "").strip()
CFG = load_config(_CFG_PATH)

BANNED_MOTIFS = set(s.lower() for s in _as_list(CFG.get("banned_motifs", [])))
STOPWORDS = set(s.lower() for s in _as_list(CFG.get("stopwords", []))).union(BANNED_MOTIFS)

STYLE_POOL = _as_list(CFG.get("style_pool", [])) or [
    "sunlit exterior, wide angle, deep depth of field, cinematic composition",
]

NOVELTY_MOTIF_POOL = _as_list(CFG.get("novelty_motif_pool", [])) or [
    "tidepool", "cathedral forest", "glass desert",
]

ESCAPE_MOTIFS = _as_list(CFG.get("escape_motifs", [])) or [
    "open sky", "mountain ridge", "coastal cliffs",
]

INITIAL_WORDS = _as_list(CFG.get("initial_words", [])) or [
    "mirror", "archive", "threshold", "glyph", "loop", "shadow"
]

def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

def now_stamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")

IMAGE_VIEWER_PROC: Optional[subprocess.Popen] = None
SHOW_IMAGES: Optional[bool] = None

def prompt_show_images() -> bool:
    prompt = "Bilder im Vollbild anzeigen? [Y/n]: "
    try:
        ans = input(prompt).strip().lower()
    except EOFError:
        return True
    if not ans:
        return True
    return ans in {"y", "yes", "j", "ja"}

def _viewer_code() -> str:
    return r"""
import sys
from PIL import Image, ImageTk
import tkinter as tk

path = sys.argv[1]
root = tk.Tk()
root.configure(background="black")
root.attributes("-fullscreen", True)
root.attributes("-topmost", True)
root.focus_force()

def close(_event=None):
    try:
        root.destroy()
    except Exception:
        pass

root.bind("<Return>", close)
root.bind("<space>", close)

sw = root.winfo_screenwidth()
sh = root.winfo_screenheight()
img = Image.open(path).convert("RGB")
img.thumbnail((sw, sh), Image.LANCZOS)
photo = ImageTk.PhotoImage(img)
label = tk.Label(root, image=photo, bg="black")
label.image = photo
label.pack(expand=True)

root.mainloop()
"""

def show_image_fullscreen(path: str) -> None:
    global IMAGE_VIEWER_PROC
    if IMAGE_VIEWER_PROC is not None and IMAGE_VIEWER_PROC.poll() is None:
        try:
            IMAGE_VIEWER_PROC.terminate()
            IMAGE_VIEWER_PROC.wait(timeout=2)
        except Exception:
            try:
                IMAGE_VIEWER_PROC.kill()
            except Exception:
                pass
    try:
        IMAGE_VIEWER_PROC = subprocess.Popen(
            [sys.executable, "-c", _viewer_code(), path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception:
        IMAGE_VIEWER_PROC = None

def _get_directml_device() -> Optional[Any]:
    if importlib.util.find_spec("torch_directml") is None:
        return None
    import torch_directml
    return torch_directml.device()

def resolve_backend() -> Tuple[str, Any]:
    pref = os.environ.get("RWE_BACKEND", "auto").strip().lower()

    if pref == "cuda":
        return "cuda", "cuda"
    if pref == "cpu":
        return "cpu", "cpu"
    if pref == "directml":
        dml = _get_directml_device()
        if dml is not None:
            return "directml", dml
        return "cpu", "cpu"

    if torch.cuda.is_available():
        return "cuda", "cuda"

    dml = _get_directml_device()
    if dml is not None:
        return "directml", dml
    return "cpu", "cpu"

def cosine(a: np.ndarray, b: np.ndarray) -> float:
    na = np.linalg.norm(a) + 1e-9
    nb = np.linalg.norm(b) + 1e-9
    return float(np.dot(a, b) / (na * nb))

def tokenize_keywords(text: str, max_words: int = 12) -> List[str]:
    words = re.findall(r"[a-zA-Z][a-zA-Z\-']+", text.lower())
    out: List[str] = []
    for w in words:
        if w in STOPWORDS:
            continue
        if len(w) < 3:
            continue
        if w not in out:
            out.append(w)
        if len(out) >= max_words:
            break
    return out

def detect_epochs(items: List[Dict[str, Any]], sustain: int = 3, novelty_spike: float = 0.40) -> List[Dict[str, Any]]:
    items = sorted(items, key=lambda x: x["iteration"])
    n = len(items)
    if n == 0:
        return []

    clusters = [int(x["cluster"]) for x in items]
    novelty = []
    for x in items:
        v = x.get("novelty_prev", None)
        novelty.append(float(v) if v is not None else 0.0)

    boundaries = [0]

    def stable_switch(i: int) -> bool:
        cur = clusters[i]
        nxt = clusters[i + 1]
        if cur == nxt:
            return False
        end = min(n, i + 1 + sustain)
        return all(clusters[j] == nxt for j in range(i + 1, end))

    for i in range(0, n - 1):
        if stable_switch(i):
            boundaries.append(i + 1)
            continue
        if novelty[i + 1] >= novelty_spike:
            boundaries.append(i + 1)

    boundaries = sorted(set(boundaries))
    epochs: List[Dict[str, Any]] = []
    for ei, start in enumerate(boundaries):
        end = (boundaries[ei + 1] - 1) if (ei + 1) < len(boundaries) else (n - 1)
        seg = items[start:end + 1]
        it0 = int(seg[0]["iteration"])
        it1 = int(seg[-1]["iteration"])

        nov = [float(x.get("novelty_prev", 0.0) or 0.0) for x in seg]
        avg_nov = float(sum(nov) / max(1, len(nov)))

        cl_counts: Dict[int, int] = {}
        for x in seg:
            c = int(x["cluster"])
            cl_counts[c] = cl_counts.get(c, 0) + 1
        top_clusters = sorted(cl_counts.items(), key=lambda kv: kv[1], reverse=True)[:3]

        epochs.append({
            "epoch_id": ei + 1,
            "start_index": start,
            "end_index": end,
            "iteration_start": it0,
            "iteration_end": it1,
            "size": len(seg),
            "avg_novelty": avg_nov,
            "top_clusters": top_clusters,
            "items": seg,
        })
    return epochs

def motif_counts_from_captions(captions: List[str], topn: int = 15) -> List[Tuple[str, int]]:
    counts: Dict[str, int] = {}
    for cap in captions:
        for t in tokenize_keywords(cap, max_words=40):
            counts[t] = counts.get(t, 0) + 1
    return sorted(counts.items(), key=lambda kv: kv[1], reverse=True)[:topn]

def wrap_lines(text: str, max_len: int) -> List[str]:
    return textwrap.wrap(text, width=max_len, break_long_words=False, break_on_hyphens=False)

def likely_interior(caption: str) -> bool:
    c = caption.lower()
    hits = 0
    for t in ("room","hallway","corridor","wall","ceiling","floor","interior"):
        if t in c:
            hits += 1
    return hits >= 2

@dataclass
class WorldState:
    iteration: int = 0
    motif_bank: List[str] = None
    prompt_style: str = STYLE_POOL[0]
    negative: str = "lowres, blurry, artifacts, text, watermark, logo, signature, deformed"
    width: int = 512
    height: int = 512
    steps: int = 22
    cfg: float = 6.0
    novelty_target: float = 0.28
    seed: int = -1
    interior_strikes: int = 0
    style_index: int = 0
    backend: str = "auto"

    def __post_init__(self):
        if self.motif_bank is None:
            self.motif_bank = list(dict.fromkeys([w for w in INITIAL_WORDS if w]))

@dataclass
class IterationRecord:
    iteration: int
    ts: int
    prompt: str
    negative: str
    width: int
    height: int
    steps: int
    cfg: float
    seed: int
    image_path: str
    caption: str
    motifs_added: List[str]
    similarity_prev: Optional[float]
    novelty_prev: Optional[float]
    rule_change: str
    embedding_path: str
    interior_strikes: int
    backend: str

class RWEv04:
    def __init__(self, out_dir: str):
        self.out_dir = out_dir
        self.state_path = os.path.join(out_dir, "world_state.json")
        self.log_path = os.path.join(out_dir, "world_log.jsonl")
        self.emb_dir = os.path.join(out_dir, "embeddings")
        ensure_dir(out_dir)
        ensure_dir(self.emb_dir)

        self.device_backend, self.device = resolve_backend()
        self.dtype = torch.float16 if self.device_backend == "cuda" else torch.float32

        self.world = self._load_state()

        self.pipe, self.backend = self._load_generation_backend()
        self.blip_processor, self.blip = self._load_blip()
        self.clip_processor, self.clip = self._load_clip()
        self.prev_embed: Optional[np.ndarray] = None

    def _load_state(self) -> WorldState:
        if os.path.exists(self.state_path):
            with open(self.state_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for k, default in (("interior_strikes",0),("style_index",0),("backend","auto")):
                if k not in data:
                    data[k] = default
            return WorldState(**data)
        return WorldState()

    def _save_state(self) -> None:
        with open(self.state_path, "w", encoding="utf-8") as f:
            json.dump(asdict(self.world), f, ensure_ascii=False, indent=2)

    def _append_log(self, rec: IterationRecord) -> None:
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(asdict(rec), ensure_ascii=False) + "\n")

    def _load_generation_backend(self):
        sdxl_id = os.environ.get("RWE_SDXL_MODEL", "stabilityai/stable-diffusion-xl-base-1.0")
        sd15_id = os.environ.get("RWE_SD15_MODEL", "runwayml/stable-diffusion-v1-5")

        if self.world.backend == "sd15":
            return self._load_sd15(sd15_id), "sd15"
        if self.world.backend == "sdxl":
            return self._load_sdxl(sdxl_id), "sdxl"

        try:
            p = self._load_sdxl(sdxl_id)
            self.world.backend = "sdxl"
            return p, "sdxl"
        except Exception as e:
            print("SDXL load failed. Falling back to SD 1.5.")
            print(str(e))
            p = self._load_sd15(sd15_id)
            self.world.backend = "sd15"
            self.world.width = 512
            self.world.height = 512
            self.world.steps = min(28, max(18, int(self.world.steps)))
            return p, "sd15"

    def _load_sdxl(self, model_id: str):
        pipe = StableDiffusionXLPipeline.from_pretrained(
            model_id,
            torch_dtype=self.dtype,
            use_safetensors=True,
            variant="fp16" if self.dtype == torch.float16 else None,
        )
        pipe = pipe.to(self.device)
        if self.device == "cuda":
            pipe.enable_attention_slicing()
            try:
                pipe.enable_vae_tiling()
            except Exception:
                pass
        return pipe

    def _load_sd15(self, model_id: str):
        pipe = StableDiffusionPipeline.from_pretrained(
            model_id,
            torch_dtype=self.dtype,
            safety_checker=None,
        )
        pipe = pipe.to(self.device)
        if self.device == "cuda":
            pipe.enable_attention_slicing()
        return pipe

    def _load_blip(self):
        model_id = os.environ.get("RWE_BLIP_MODEL", "Salesforce/blip-image-captioning-base")
        processor = BlipProcessor.from_pretrained(model_id)
        model = BlipForConditionalGeneration.from_pretrained(model_id).to(self.device)
        model.eval()
        return processor, model

    def _load_clip(self):
        model_id = os.environ.get("RWE_CLIP_MODEL", "openai/clip-vit-base-patch32")
        processor = CLIPProcessor.from_pretrained(model_id)
        model = CLIPModel.from_pretrained(model_id).to(self.device)
        model.eval()
        return processor, model

    def _make_prompt(self) -> str:
        motifs = self.world.motif_bank[:]
        random.shuffle(motifs)
        motifs = motifs[: min(7, len(motifs))]
        core = ", ".join(motifs)
        return f"{core}, {self.world.prompt_style}"

    def _gen_seed(self) -> int:
        if self.world.seed >= 0:
            return self.world.seed
        return random.randint(0, 2**31 - 1)

    @torch.inference_mode()
    def _generate_image(self, prompt: str, seed: int) -> Image.Image:
        gen = torch.Generator(device=self.device).manual_seed(seed) if self.device_backend == "cuda" else None
        if self.backend == "sdxl":
            r = self.pipe(
                prompt=prompt,
                negative_prompt=self.world.negative,
                num_inference_steps=int(self.world.steps),
                guidance_scale=float(self.world.cfg),
                width=int(self.world.width),
                height=int(self.world.height),
                generator=gen,
            )
            return r.images[0]
        r = self.pipe(
            prompt=prompt,
            negative_prompt=self.world.negative,
            num_inference_steps=int(self.world.steps),
            guidance_scale=float(self.world.cfg),
            generator=gen,
        )
        return r.images[0]

    @torch.inference_mode()
    def _caption_image(self, img: Image.Image) -> str:
        inputs = self.blip_processor(images=img, return_tensors="pt").to(self.device)
        out = self.blip.generate(**inputs, max_new_tokens=40)
        cap = self.blip_processor.decode(out[0], skip_special_tokens=True)
        return cap.strip()

    @torch.inference_mode()
    def _embed_image(self, img: Image.Image) -> np.ndarray:
        inputs = self.clip_processor(images=img, return_tensors="pt").to(self.device)
        feats = self.clip.get_image_features(**inputs)
        v = feats[0].detach().float().cpu().numpy()
        v = v / (np.linalg.norm(v) + 1e-9)
        return v

    def _update_motifs_from_caption(self, caption: str) -> List[str]:
        kws = tokenize_keywords(caption, max_words=10)
        added: List[str] = []
        for k in kws:
            if k in BANNED_MOTIFS:
                continue
            if k not in self.world.motif_bank:
                self.world.motif_bank.append(k)
                added.append(k)
        self.world.motif_bank = self.world.motif_bank[-64:]
        return added

    def _inject_novelty(self) -> List[str]:
        added: List[str] = []
        pool = NOVELTY_MOTIF_POOL[:]
        random.shuffle(pool)
        for cand in pool[:3]:
            if cand not in self.world.motif_bank:
                self.world.motif_bank.insert(0, cand)
                added.append(cand)
        self.world.motif_bank = self.world.motif_bank[-64:]
        return added

    def _escape_interior_trap(self) -> List[str]:
        added: List[str] = []
        self.world.motif_bank = [m for m in self.world.motif_bank if m.lower() not in BANNED_MOTIFS]
        pool = ESCAPE_MOTIFS[:]
        random.shuffle(pool)
        for cand in pool[:3]:
            if cand not in self.world.motif_bank:
                self.world.motif_bank.insert(0, cand)
                added.append(cand)
        self.world.motif_bank = self.world.motif_bank[-64:]
        return added

    def _maybe_rotate_style(self, force: bool) -> str:
        if force or random.random() < 0.25:
            self.world.style_index = int((self.world.style_index + 1) % len(STYLE_POOL))
            self.world.prompt_style = STYLE_POOL[self.world.style_index]
            return "style_rotate"
        return "style_keep"

    def _mutate_rules(self, novelty: Optional[float], caption: str) -> Tuple[List[str], str]:
        added: List[str] = []
        interior = likely_interior(caption)
        if interior:
            self.world.interior_strikes += 1
        else:
            self.world.interior_strikes = max(0, self.world.interior_strikes - 1)

        if self.world.interior_strikes >= 2:
            added += self._escape_interior_trap()
            rule_change = "escape_interior_trap+" + self._maybe_rotate_style(force=True)
            self.world.cfg = float(np.clip(self.world.cfg + random.uniform(0.6, 1.2), 5.0, 9.0))
            self.world.steps = int(np.clip(self.world.steps + random.choice([2, 3, 4]), 18, 36))
            return added, rule_change

        if novelty is None:
            rule_change = "bootstrap+" + self._maybe_rotate_style(force=True)
            added += self._inject_novelty()
            return added, rule_change

        target = float(self.world.novelty_target)
        if novelty < (target - 0.08):
            added += self._inject_novelty()
            rule_change = "increase_novelty+inject+" + self._maybe_rotate_style(force=(novelty < 0.12))
            self.world.cfg = float(np.clip(self.world.cfg + random.uniform(0.3, 1.0), 5.0, 9.0))
            self.world.steps = int(np.clip(self.world.steps + random.choice([1,2,3]), 18, 36))
        elif novelty > (target + 0.12):
            rule_change = "increase_coherence+" + self._maybe_rotate_style(force=False)
            self.world.cfg = float(np.clip(self.world.cfg + random.uniform(-0.9, -0.2), 4.8, 7.0))
            self.world.steps = int(np.clip(self.world.steps + random.choice([-2,-1,0]), 18, 32))
        else:
            r = random.random()
            if r < 0.40:
                self.world.cfg = float(np.clip(self.world.cfg + random.uniform(-0.35, 0.35), 4.8, 9.0))
                rule_change = "micro(cfg)"
            elif r < 0.75:
                self.world.steps = int(np.clip(self.world.steps + random.choice([-1,0,1]), 18, 36))
                rule_change = "micro(steps)"
            else:
                rule_change = "micro(none)"
            rule_change += "+" + self._maybe_rotate_style(force=False)

        return added, rule_change

    def step(self) -> None:
        self.world.iteration += 1
        it = self.world.iteration

        prompt = self._make_prompt()
        seed = self._gen_seed()

        img = self._generate_image(prompt, seed)
        cap = self._caption_image(img)
        emb = self._embed_image(img)

        similarity_prev = None
        novelty_prev = None
        if self.prev_embed is not None:
            similarity_prev = cosine(self.prev_embed, emb)
            novelty_prev = 1.0 - similarity_prev

        motifs_added_cap = self._update_motifs_from_caption(cap)
        motifs_added_rules, rule_change = self._mutate_rules(novelty_prev, cap)

        stamp = now_stamp()
        img_path = os.path.join(self.out_dir, f"rwe_{stamp}_iter{it:05d}.png")
        emb_path = os.path.join(self.emb_dir, f"rwe_{stamp}_iter{it:05d}.npy")

        img.save(img_path)
        np.save(emb_path, emb.astype(np.float32))

        if SHOW_IMAGES:
            show_image_fullscreen(img_path)

        rec = IterationRecord(
            iteration=it,
            ts=int(time.time()),
            prompt=prompt,
            negative=self.world.negative,
            width=self.world.width,
            height=self.world.height,
            steps=self.world.steps,
            cfg=self.world.cfg,
            seed=seed,
            image_path=img_path,
            caption=cap,
            motifs_added=(motifs_added_cap + motifs_added_rules),
            similarity_prev=similarity_prev,
            novelty_prev=novelty_prev,
            rule_change=rule_change,
            embedding_path=emb_path,
            interior_strikes=int(self.world.interior_strikes),
            backend=self.backend,
        )

        self._append_log(rec)
        self._save_state()
        self.prev_embed = emb

        print(f"[{it}] {os.path.basename(img_path)} ({self.backend})")
        print(f"    caption: {cap}")
        if novelty_prev is not None:
            print(f"    similarity_prev: {similarity_prev:.3f} | novelty_prev: {novelty_prev:.3f} | target: {self.world.novelty_target:.2f}")
        print(f"    rule_change: {rule_change} | motifs_added: {len(rec.motifs_added)} | interior_strikes: {rec.interior_strikes}")

def read_jsonl(path: str) -> List[Dict[str, Any]]:
    if not os.path.exists(path):
        return []
    out: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out

def load_embeddings(records: List[Dict[str, Any]]) -> np.ndarray:
    embs: List[np.ndarray] = []
    for r in records:
        p = r.get("embedding_path", "")
        if p and os.path.exists(p):
            embs.append(np.load(p))
        else:
            embs.append(np.zeros((512,), dtype=np.float32))
    return np.vstack(embs) if embs else np.zeros((0, 512), dtype=np.float32)

def choose_k_by_silhouette(X: np.ndarray, kmin: int, kmax: int) -> int:
    if X.shape[0] < (kmin + 2):
        return max(2, min(kmin, X.shape[0])) if X.shape[0] >= 2 else 1
    best_k = kmin
    best_s = -1.0
    upper = min(kmax, X.shape[0] - 1)
    for k in range(kmin, upper + 1):
        km = KMeans(n_clusters=k, n_init=10, random_state=42)
        labels = km.fit_predict(X)
        if len(set(labels)) < 2:
            continue
        s = silhouette_score(X, labels, metric="cosine")
        if s > best_s:
            best_s = s
            best_k = k
    return best_k

def cluster_world(out_dir: str, kmin: int = 3, kmax: int = 10) -> str:
    log_path = os.path.join(out_dir, "world_log.jsonl")
    records = read_jsonl(log_path)
    if not records:
        raise RuntimeError("No world_log.jsonl found or empty.")
    X = load_embeddings(records)
    if X.shape[0] < 2:
        raise RuntimeError("Not enough embeddings to cluster.")

    k = choose_k_by_silhouette(X, kmin=kmin, kmax=kmax)
    km = KMeans(n_clusters=max(2, k), n_init=10, random_state=42)
    labels = km.fit_predict(X)

    cluster_path = os.path.join(out_dir, "clusters.json")
    payload = {"k": int(max(2, k)), "method": "kmeans_cosine_silhouette", "items": []}

    for r, lab in zip(records, labels):
        payload["items"].append({
            "iteration": int(r["iteration"]),
            "image_path": r["image_path"],
            "caption": r["caption"],
            "cluster": int(lab),
            "ts": int(r["ts"]),
            "novelty_prev": r.get("novelty_prev", None),
        })

    with open(cluster_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    return cluster_path

def make_contact_sheet(image_paths: List[str], out_path: str, title: str, thumb: int = 320, cols: int = 3) -> None:
    imgs: List[Image.Image] = []
    for p in image_paths:
        try:
            im = Image.open(p).convert("RGB")
            imgs.append(im)
        except Exception:
            continue
    if not imgs:
        raise RuntimeError("No images for contact sheet.")

    rows = int(math.ceil(len(imgs) / cols))
    padding = 18
    header = 96
    w = cols * thumb + (cols + 1) * padding
    h = header + rows * thumb + (rows + 1) * padding

    sheet = Image.new("RGB", (w, h), (245, 245, 245))
    draw = ImageDraw.Draw(sheet)

    try:
        font = ImageFont.truetype("arial.ttf", 28)
        font_small = ImageFont.truetype("arial.ttf", 18)
    except Exception:
        font = ImageFont.load_default()
        font_small = ImageFont.load_default()

    draw.text((padding, 18), title, fill=(0, 0, 0), font=font)
    draw.text((padding, 58), f"n={len(imgs)}", fill=(30, 30, 30), font=font_small)

    x0 = padding
    y0 = header + padding
    i = 0
    for r in range(rows):
        for c in range(cols):
            if i >= len(imgs):
                break
            im = imgs[i].copy()
            im.thumbnail((thumb, thumb))
            x = x0 + c * (thumb + padding)
            y = y0 + r * (thumb + padding)
            bg = Image.new("RGB", (thumb, thumb), (255, 255, 255))
            bx = (thumb - im.size[0]) // 2
            by = (thumb - im.size[1]) // 2
            bg.paste(im, (bx, by))
            sheet.paste(bg, (x, y))
            i += 1

    sheet.save(out_path)

def build_pdf(out_dir: str, clusters: Dict[str, Any], epochs: List[Dict[str, Any]]) -> str:
    items = clusters["items"]
    items = sorted(items, key=lambda x: x["iteration"])

    atlas_dir = os.path.join(out_dir, "atlas")
    sheets_dir = os.path.join(atlas_dir, "sheets")
    ensure_dir(atlas_dir)
    ensure_dir(sheets_dir)

    sample_every = max(1, len(items) // 24)
    timeline_imgs = [x["image_path"] for x in items[::sample_every]]
    timeline_sheet = os.path.join(sheets_dir, "timeline.png")
    make_contact_sheet(timeline_imgs, timeline_sheet, "RWE Atlas - Timeline (sampled)", thumb=320, cols=3)

    by_cluster: Dict[int, List[Dict[str, Any]]] = {}
    for it in items:
        by_cluster.setdefault(int(it["cluster"]), []).append(it)

    cluster_sheets: List[Tuple[str, str]] = []
    for cl in sorted(by_cluster.keys()):
        img_paths = [x["image_path"] for x in by_cluster[cl][:12]]
        p = os.path.join(sheets_dir, f"cluster_{cl:02d}.png")
        make_contact_sheet(img_paths, p, f"Cluster {cl:02d} (top {len(img_paths)})", thumb=320, cols=3)
        cluster_sheets.append((f"Cluster {cl:02d}", p))

    epoch_sheets: List[Tuple[Dict[str, Any], str]] = []
    for e in epochs:
        img_paths = [x["image_path"] for x in e["items"][:12]]
        p = os.path.join(sheets_dir, f"epoch_{e['epoch_id']:02d}.png")
        make_contact_sheet(img_paths, p, f"Epoch {e['epoch_id']:02d} (top {len(img_paths)})", thumb=320, cols=3)
        epoch_sheets.append((e, p))

    cluster_motifs: Dict[int, List[Tuple[str, int]]] = {}
    for cl, arr in by_cluster.items():
        caps = [x["caption"] for x in arr]
        cluster_motifs[cl] = motif_counts_from_captions(caps, topn=12)

    epoch_motifs: Dict[int, List[Tuple[str, int]]] = {}
    for e in epochs:
        caps = [x["caption"] for x in e["items"]]
        epoch_motifs[int(e["epoch_id"])] = motif_counts_from_captions(caps, topn=12)

    pdf_path = os.path.join(atlas_dir, "rwe_atlas_v04.pdf")
    c = canvas.Canvas(pdf_path, pagesize=A4)
    pw, ph = A4
    margin = 15 * mm

    c.setFont("Helvetica-Bold", 22)
    c.drawString(margin, ph - 30*mm, "Reflective World Engine (RWE) - Atlas v0.4")
    c.setFont("Helvetica", 12)
    c.drawString(margin, ph - 40*mm, f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    c.drawString(margin, ph - 48*mm, f"Output dir: {out_dir}")
    cfg_path = os.environ.get("RWE_CONFIG", "").strip()
    if cfg_path:
        c.drawString(margin, ph - 56*mm, f"Config: {cfg_path}")
    c.drawString(margin, ph - 64*mm, f"Clustering: {clusters.get('method','')}, k={clusters.get('k','')}")
    c.drawString(margin, ph - 72*mm, f"Epochs: {len(epochs)}")
    c.showPage()

    c.setFont("Helvetica-Bold", 16)
    c.drawString(margin, ph - margin, "Motif Index - Epochs")
    y = ph - margin - 18
    c.setFont("Helvetica", 11)
    for eid in sorted(epoch_motifs.keys()):
        mot = epoch_motifs[eid]
        line = f"Epoch {eid:02d}: " + ", ".join([f"{m}({n})" for m, n in mot])
        for ln in wrap_lines(line, max_len=95):
            c.drawString(margin, y, ln)
            y -= 14
            if y < 30*mm:
                c.showPage()
                c.setFont("Helvetica", 11)
                y = ph - margin
    c.showPage()

    c.setFont("Helvetica-Bold", 16)
    c.drawString(margin, ph - margin, "Motif Index - Clusters")
    y = ph - margin - 18
    c.setFont("Helvetica", 11)
    for cl in sorted(cluster_motifs.keys()):
        mot = cluster_motifs[cl]
        line = f"Cluster {cl:02d}: " + ", ".join([f"{m}({n})" for m, n in mot])
        for ln in wrap_lines(line, max_len=95):
            c.drawString(margin, y, ln)
            y -= 14
            if y < 30*mm:
                c.showPage()
                c.setFont("Helvetica", 11)
                y = ph - margin
    c.showPage()

    c.setFont("Helvetica-Bold", 14)
    c.drawString(margin, ph - margin, "Timeline (sampled)")
    avail_w = pw - 2 * margin
    avail_h = ph - 2 * margin - 18
    c.drawImage(timeline_sheet, margin, margin, width=avail_w, height=avail_h, preserveAspectRatio=True, anchor="c")
    c.showPage()

    for e, sheet_path in epoch_sheets:
        c.setFont("Helvetica-Bold", 16)
        c.drawString(margin, ph - margin, f"Epoch {e['epoch_id']:02d}: Iter {e['iteration_start']}-{e['iteration_end']} (n={e['size']})")
        y = ph - margin - 22
        c.setFont("Helvetica", 11)
        tc = ", ".join([f"{cl}:{cnt}" for cl, cnt in e["top_clusters"]])
        c.drawString(margin, y, f"Avg novelty: {e['avg_novelty']:.3f} | Top clusters: {tc}")
        y -= 16

        motifs = epoch_motifs[int(e["epoch_id"])]
        motif_line = "Top motifs: " + ", ".join([f"{m}({n})" for m, n in motifs])
        for ln in wrap_lines(motif_line, max_len=95):
            c.drawString(margin, y, ln)
            y -= 14

        c.showPage()

        c.setFont("Helvetica-Bold", 14)
        c.drawString(margin, ph - margin, f"Epoch {e['epoch_id']:02d} contact sheet")
        c.drawImage(sheet_path, margin, margin, width=avail_w, height=avail_h, preserveAspectRatio=True, anchor="c")
        c.showPage()

    for title, sp in cluster_sheets:
        c.setFont("Helvetica-Bold", 14)
        c.drawString(margin, ph - margin, f"{title} contact sheet")
        c.drawImage(sp, margin, margin, width=avail_w, height=avail_h, preserveAspectRatio=True, anchor="c")
        c.showPage()

    c.save()
    return pdf_path

def main() -> None:
    global SHOW_IMAGES
    out_dir = os.environ.get("RWE_OUT", r".\outputs")
    ensure_dir(out_dir)

    hf_token = os.environ.get("HF_TOKEN", "").strip()
    if hf_token:
        try:
            login(token=hf_token, add_to_git_credential=False)
        except Exception:
            pass

    iters_s = os.environ.get("RWE_ITERS", "10").strip()
    iters = int(iters_s) if iters_s.isdigit() else 10

    SHOW_IMAGES = prompt_show_images()

    print("")
    print("RWE v0.4 loop starting (config-driven)")
    backend_pref = os.environ.get("RWE_BACKEND", "auto").strip().lower() or "auto"
    print(f"Backend preference: {backend_pref}")
    print(f"Output: {out_dir}")
    cfg_path = os.environ.get("RWE_CONFIG", "").strip()
    if cfg_path:
        print(f"Config: {cfg_path}")
    print("")

    rwe = RWEv04(out_dir=out_dir)
    print(f"Device: {rwe.device_backend}")
    for _ in range(iters):
        rwe.step()

    print("")
    print("Clustering + PDF...")
    cluster_path = cluster_world(out_dir)
    with open(cluster_path, "r", encoding="utf-8") as f:
        clusters = json.load(f)
    epochs = detect_epochs(clusters["items"], sustain=3, novelty_spike=0.40)
    epochs_path = os.path.join(out_dir, "epochs.json")
    with open(epochs_path, "w", encoding="utf-8") as f:
        json.dump({"epochs": epochs}, f, ensure_ascii=False, indent=2)
    pdf = build_pdf(out_dir, clusters, epochs)
    print(f"Epochs JSON: {epochs_path}")
    print(f"Atlas PDF: {pdf}")
    print("")
    print("Done.")

if __name__ == "__main__":
    main()
'@ | Set-Content -Path $rwePy -Encoding UTF8

    return $rwePy
}

function Write-RWE-ConfigEditor {
    param([string]$AppDir)

    Ensure-Folder $AppDir
    $editorPy = Join-Path $AppDir "rwe_config_editor.py"

@'
import argparse
import copy
import json
import os
import sys
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

LIST_SECTIONS = [
    ("initial_words", "Initiale Motive"),
    ("banned_motifs", "Gesperrte Motive"),
    ("stopwords", "Stoppwörter"),
    ("style_pool", "Stil-Pool"),
    ("novelty_motif_pool", "Neuheits-Motiv-Pool"),
    ("escape_motifs", "Escape-Motive"),
]

def load_json(path: str) -> dict:
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f) or {}

def ensure_section(cfg: dict, key: str) -> dict:
    sec = cfg.get(key)
    if not isinstance(sec, dict):
        sec = {}
        cfg[key] = sec
    if "values" not in sec or not isinstance(sec["values"], list):
        sec["values"] = []
    return sec

def text_to_list(text: str) -> list:
    out = []
    for line in text.splitlines():
        val = line.strip()
        if val:
            out.append(val)
    return out

def list_to_text(values: list) -> str:
    return "\n".join(values)

def get_section_meta(cfg: dict, key: str) -> tuple:
    sec = cfg.get(key, {})
    desc = sec.get("description", "")
    effects = sec.get("effects", [])
    return desc, effects if isinstance(effects, list) else []

def describe_section(cfg: dict, key: str) -> str:
    desc, effects = get_section_meta(cfg, key)
    lines = []
    if desc:
        lines.append(desc)
    if effects:
        lines.append("Wirkung:")
        for e in effects:
            lines.append(f"• {e}")
    return "\n".join(lines)

def build_ui(cfg_path: str, default_cfg: dict, cfg: dict, outputs_dir: str) -> None:
    root = tk.Tk()
    root.title("RWE Konfigurations-Editor")
    root.geometry("900x720")
    root.minsize(820, 620)

    style = ttk.Style(root)
    if "vista" in style.theme_names():
        style.theme_use("vista")
    elif "clam" in style.theme_names():
        style.theme_use("clam")

    main = ttk.Frame(root, padding=12)
    main.pack(fill=tk.BOTH, expand=True)

    header = ttk.Label(
        main,
        text="RWE Konfigurations-Editor",
        font=("Segoe UI", 16, "bold"),
    )
    header.pack(anchor=tk.W, pady=(0, 4))

    path_label = ttk.Label(
        main,
        text=f"Datei: {cfg_path}",
        foreground="#555555",
    )
    path_label.pack(anchor=tk.W, pady=(0, 10))

    notebook = ttk.Notebook(main)
    notebook.pack(fill=tk.BOTH, expand=True)

    list_widgets = {}

    for key, title in LIST_SECTIONS:
        frame = ttk.Frame(notebook, padding=12)
        notebook.add(frame, text=title)

        hint_text = describe_section(cfg if cfg else default_cfg, key)
        hint_label = ttk.Label(frame, text=hint_text, wraplength=820, justify=tk.LEFT)
        hint_label.pack(anchor=tk.W, pady=(0, 8))

        helper = ttk.Label(frame, text="Ein Eintrag pro Zeile. Leerzeilen werden ignoriert.")
        helper.pack(anchor=tk.W, pady=(0, 6))

        text = scrolledtext.ScrolledText(frame, height=16, wrap=tk.WORD)
        text.pack(fill=tk.BOTH, expand=True)
        list_widgets[key] = text

    runtime_frame = ttk.Frame(notebook, padding=12)
    notebook.add(runtime_frame, text="Runtime Defaults")

    runtime_hint = describe_section(cfg if cfg else default_cfg, "runtime_defaults")
    runtime_label = ttk.Label(runtime_frame, text=runtime_hint, wraplength=820, justify=tk.LEFT)
    runtime_label.pack(anchor=tk.W, pady=(0, 8))

    runtime_row = ttk.Frame(runtime_frame)
    runtime_row.pack(anchor=tk.W, pady=(4, 8))

    iter_label = ttk.Label(runtime_row, text="Standard-Iterationen:")
    iter_label.pack(side=tk.LEFT)

    iter_var = tk.StringVar()
    iter_entry = ttk.Entry(runtime_row, textvariable=iter_var, width=10)
    iter_entry.pack(side=tk.LEFT, padx=(8, 0))

    def load_into_fields(source_cfg: dict) -> None:
        for key, _ in LIST_SECTIONS:
            sec = ensure_section(source_cfg, key)
            text = list_widgets[key]
            text.delete("1.0", tk.END)
            text.insert(tk.END, list_to_text(sec.get("values", [])))

        runtime_sec = source_cfg.get("runtime_defaults", {})
        values = runtime_sec.get("values", {}) if isinstance(runtime_sec, dict) else {}
        iter_val = values.get("iterations", 10)
        iter_var.set(str(iter_val))

    def handle_open_outputs() -> None:
        if not outputs_dir:
            messagebox.showinfo("Ausgabeordner", "Kein Ausgabeordner bekannt.")
            return
        if not os.path.exists(outputs_dir):
            messagebox.showwarning("Ausgabeordner", "Der Ausgabeordner existiert noch nicht.")
            return
        try:
            os.startfile(outputs_dir)
        except Exception as exc:
            messagebox.showerror("Ausgabeordner", f"Konnte Ordner nicht öffnen:\n{exc}")

    def handle_restore_defaults() -> None:
        load_into_fields(default_cfg)

    def handle_save() -> None:
        updated = copy.deepcopy(cfg)
        for key, _ in LIST_SECTIONS:
            sec = ensure_section(updated, key)
            values = text_to_list(list_widgets[key].get("1.0", tk.END))
            if not values:
                messagebox.showerror("Fehler", f"'{key}' darf nicht leer sein.")
                return
            sec["values"] = values

        runtime_sec = updated.setdefault("runtime_defaults", {})
        if not isinstance(runtime_sec, dict):
            runtime_sec = {}
            updated["runtime_defaults"] = runtime_sec
        runtime_values = runtime_sec.setdefault("values", {})
        if not isinstance(runtime_values, dict):
            runtime_values = {}
            runtime_sec["values"] = runtime_values

        iter_text = iter_var.get().strip()
        if not iter_text.isdigit() or int(iter_text) < 1:
            messagebox.showerror("Fehler", "Bitte eine gültige positive Zahl für Iterationen eingeben.")
            return
        runtime_values["iterations"] = int(iter_text)

        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(updated, f, ensure_ascii=False, indent=2)

        messagebox.showinfo("Gespeichert", "Konfiguration wurde gespeichert.")
        root.destroy()

    load_into_fields(cfg)

    buttons = ttk.Frame(main)
    buttons.pack(fill=tk.X, pady=(10, 0))

    open_btn = ttk.Button(buttons, text="Ausgabeordner öffnen", command=handle_open_outputs)
    open_btn.pack(side=tk.LEFT)

    restore_btn = ttk.Button(buttons, text="Defaults wiederherstellen", command=handle_restore_defaults)
    restore_btn.pack(side=tk.LEFT, padx=(8, 0))

    cancel_btn = ttk.Button(buttons, text="Abbrechen", command=root.destroy)
    cancel_btn.pack(side=tk.RIGHT, padx=(8, 0))

    save_btn = ttk.Button(buttons, text="Speichern & Schließen", command=handle_save)
    save_btn.pack(side=tk.RIGHT)

    root.mainloop()

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--defaults", required=False)
    parser.add_argument("--outputs", required=False, default="")
    args = parser.parse_args()

    cfg = load_json(args.config)
    default_cfg = load_json(args.defaults) if args.defaults else {}
    if not default_cfg:
        default_cfg = copy.deepcopy(cfg)

    if not cfg:
        cfg = copy.deepcopy(default_cfg)

    build_ui(args.config, default_cfg, cfg, args.outputs or "")
    return 0

if __name__ == "__main__":
    sys.exit(main())
'@ | Set-Content -Path $editorPy -Encoding UTF8

    return $editorPy
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

    Write-Section "Resume mode"
    $doResume = Prompt-YesNo -Label "Resume previous run?" -DefaultNo $true
    $runRoot = $null
    if ($doResume) {
        $latest = Find-LatestRunFolder -ScriptDir $scriptDir
        if ([string]::IsNullOrWhiteSpace($latest)) {
            Write-Host "No previous run folder found. Starting a new run." -ForegroundColor Yellow
            $runRoot = New-RunFolderNextToScript -ScriptDir $scriptDir
        } else {
            $runRoot = Prompt-Path -Label "Run folder to resume" -DefaultValue $latest
        }
    } else {
        $runRoot = New-RunFolderNextToScript -ScriptDir $scriptDir
    }

    Write-Host ("Run folder: {0}" -f $runRoot) -ForegroundColor Cyan

    $appDir   = Join-Path $scriptDir "app"
    $cacheDir = Join-Path $scriptDir "cache"
    $venvDir  = Join-Path $scriptDir "venv"
    $outDir   = Join-Path $runRoot "outputs"

    Ensure-Folder $appDir
    Ensure-Folder $cacheDir
    Ensure-Folder $outDir

    $runConfig = Join-Path $runRoot "rwe_config.json"
    if (-not (Test-Path -LiteralPath $runConfig)) {
        Copy-FileSafe -Src $configPath -Dst $runConfig
    }

    $env:HF_HOME = $cacheDir

    Write-Section "Install prerequisites (Python 3.10, Git)"
    Install-Python310
    Install-Git

    Write-Section "Create venv (Python 3.10)"
    $venvInfo = Ensure-Venv310 -VenvPath $venvDir
    $py  = $venvInfo.Py
    $pip = $venvInfo.Pip

    Write-Section "Install packages"
    Write-DetectedHardwareInfo
    $backend = Get-PreferredBackend
    Write-Host ("Selected backend (pre-check): {0}" -f $backend) -ForegroundColor Cyan

    Install-TorchForBackend -PipPath $pip -Backend $backend

    $verify = Test-BackendInPython -PythonPath $py -Backend $backend
    if ($verify -ne 0) {
        if ($backend -eq "cuda") {
            Write-Host "CUDA verify failed. Falling back to DirectML..." -ForegroundColor Yellow
            $backend = "directml"
            Install-TorchForBackend -PipPath $pip -Backend $backend
            $verify = Test-BackendInPython -PythonPath $py -Backend $backend
        }
        if ($verify -ne 0) {
            Write-Host "DirectML verify failed. Falling back to CPU..." -ForegroundColor Yellow
            $backend = "cpu"
            Install-TorchForBackend -PipPath $pip -Backend $backend
            $verify = Test-BackendInPython -PythonPath $py -Backend $backend
        }
    }

    Write-Host ("Selected backend (verified): {0}" -f $backend) -ForegroundColor Green
    $env:RWE_BACKEND = $backend

    Install-Pip-Packages -PipPath $pip

    Write-Section "Write RWE Python"
    $rwePy = Write-RWE-Python -AppDir $appDir
    $editorPy = Write-RWE-ConfigEditor -AppDir $appDir

    Write-Section "Config editor"
    $editConfig = Prompt-YesNo -Label "Konfiguration jetzt bearbeiten?" -DefaultNo $true
    if ($editConfig) {
        & $py $editorPy --config $runConfig --defaults $configPath --outputs $outDir
        Write-Section "Validate config"
        Validate-Config -ConfigPath $runConfig
        Write-Host "Config OK." -ForegroundColor Green
    }

    Write-Section "Run settings"
    $defaultIters = Read-ConfigDefaultIterations -ConfigPath $runConfig -Fallback 10
    $iters = Prompt-Int -Label "Iterations" -DefaultValue $defaultIters

    $token = Read-Host "Hugging Face token (optional - press Enter to skip)"
    if (-not [string]::IsNullOrWhiteSpace($token)) { $env:HF_TOKEN = $token.Trim() }

    $env:RWE_CONFIG = $runConfig
    $env:RWE_OUT    = $outDir
    $env:RWE_ITERS  = [string]$iters

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

    Wait-ForEnter "Press Enter to exit..."
} catch {
    Show-ErrorAndWait "Fatal error." $_.Exception
}
