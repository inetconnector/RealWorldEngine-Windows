import argparse
import datetime
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox


def _win_hidden_subprocess_kwargs() -> dict:
    if os.name != "nt":
        return {}
    kwargs: dict = {}
    try:
        kwargs["creationflags"] = int(getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except Exception:
        pass
    try:
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 0
        kwargs["startupinfo"] = si
    except Exception:
        pass
    return kwargs


def _now_ts() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S")


def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def load_json(path: str) -> dict:
    try:
        if not path or not os.path.exists(path):
            return {}
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}


def save_json(path: str, data: dict) -> None:
    ensure_dir(os.path.dirname(path))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def read_progress_state(progress_file: str) -> dict:
    """Read the last valid JSON object from a .jsonl progress file.

    Never raises. Returns {} when the file is missing, empty, or contains no
    parseable JSON lines yet.
    """
    try:
        if not progress_file or not os.path.exists(progress_file):
            return {}
        # Read from the end to avoid loading huge log files.
        with open(progress_file, "rb") as f:
            try:
                f.seek(0, os.SEEK_END)
                end = f.tell()
            except Exception:
                end = 0

            # Read the last up to 64 KB.
            chunk = 64 * 1024
            start = max(0, end - chunk)
            if start:
                f.seek(start, os.SEEK_SET)
            data = f.read(end - start)

        text = data.decode("utf-8", errors="replace")
        lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
        for ln in reversed(lines):
            try:
                obj = json.loads(ln)
                if isinstance(obj, dict):
                    return obj
            except Exception:
                continue
        return {}
    except Exception:
        return {}


def find_latest_run_folder(script_dir: str) -> str:
    try:
        date_dirs = []
        for name in os.listdir(script_dir):
            p = os.path.join(script_dir, name)
            if os.path.isdir(p) and len(name) == 10 and name[4] == "-" and name[7] == "-":
                date_dirs.append(p)
        date_dirs.sort(reverse=True)
        for d in date_dirs:
            runs = []
            for name in os.listdir(d):
                p = os.path.join(d, name)
                if os.path.isdir(p) and name.startswith("run-") and len(name) == 19:
                    runs.append(p)
            runs.sort(reverse=True)
            for r in runs:
                out_dir = os.path.join(r, "outputs")
                if os.path.exists(os.path.join(out_dir, "world_state.json")) or os.path.exists(os.path.join(out_dir, "world_log.jsonl")):
                    return r
    except Exception:
        pass
    return ""


def new_run_folder(script_dir: str) -> str:
    ds = datetime.datetime.now().strftime("%Y-%m-%d")
    base = os.path.join(script_dir, ds)
    ensure_dir(base)
    rs = datetime.datetime.now().strftime("run-%Y%m%d-%H%M%S")
    run = os.path.join(base, rs)
    ensure_dir(run)
    return run


def write_run_slideshow_starter(run_root: str, app_dir: str) -> str:
    starter_path = os.path.join(run_root, "start_slideshow.ps1")
    slideshow_py = os.path.join(app_dir, "rwe_slideshow.py").replace('"', '""')

    content = """Set-StrictMode -Version 2
$ErrorActionPreference = \"Stop\"

function Resolve-PythonExe {
    param([string]$RunRoot)
    $scriptDir = Split-Path -Parent (Split-Path -Parent $RunRoot)
    $venvPy = Join-Path $scriptDir \"venv\\Scripts\\python.exe\"
    if (Test-Path -LiteralPath $venvPy) { return $venvPy }
    $cmd = Get-Command \"python\" -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

$runRoot = $PSScriptRoot
$py = Resolve-PythonExe -RunRoot $runRoot
if (-not $py) {
    Write-Host \"Python nicht gefunden. Bitte zuerst rwe_runner.ps1 ausführen.\" -ForegroundColor Red
    Read-Host \"Enter drücken zum Beenden\"
    exit 1
}

$slideshowPy = \"__SLIDESHOW_PY__\"
if (-not (Test-Path -LiteralPath $slideshowPy)) {
    Write-Host \"rwe_slideshow.py nicht gefunden: $slideshowPy\" -ForegroundColor Red
    Read-Host \"Enter drücken zum Beenden\"
    exit 1
}

& $py $slideshowPy --run-root $runRoot
"""

    content = content.replace("__SLIDESHOW_PY__", slideshow_py)

    with open(starter_path, "w", encoding="utf-8") as f:
        f.write(content)
    return starter_path


def run_subprocess(args: list[str], env: dict | None, cwd: str | None, on_line, check: bool = True) -> int:
    p = subprocess.Popen(
        args,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        universal_newlines=True,
        **_win_hidden_subprocess_kwargs(),
    )
    assert p.stdout is not None
    for line in p.stdout:
        on_line(line.rstrip("\n"))
    p.wait()
    if check and p.returncode != 0:
        raise RuntimeError(f"Process failed: {' '.join(args)} (ExitCode={p.returncode})")
    return int(p.returncode or 0)


def detect_gpu_names() -> list[str]:
    names: list[str] = []
    try:
        p = subprocess.run(
            ["cmd.exe", "/c", "wmic path win32_VideoController get name"],
            capture_output=True,
            text=True,
            check=False,
            **_win_hidden_subprocess_kwargs(),
        )
        for line in (p.stdout or "").splitlines():
            s = line.strip()
            if not s or s.lower() == "name":
                continue
            names.append(s)
    except Exception:
        pass
    return names


def vulkan_present() -> bool:
    sysroot = os.environ.get("WINDIR", r"C:\\Windows")
    return os.path.exists(os.path.join(sysroot, "System32", "vulkan-1.dll")) or os.path.exists(os.path.join(sysroot, "SysWOW64", "vulkan-1.dll"))


def choose_backend(gpu_names: list[str]) -> str:
    joined = " | ".join(gpu_names).lower()
    has_nvidia = "nvidia" in joined
    has_amd = ("amd" in joined) or ("radeon" in joined)
    has_intel = ("intel" in joined) or ("uhd" in joined) or ("iris" in joined)

    if has_nvidia:
        try:
            r = subprocess.run(["nvidia-smi"], capture_output=True, text=True, check=False, **_win_hidden_subprocess_kwargs())
            if r.returncode == 0:
                return "cuda"
        except Exception:
            pass

    if has_amd or has_intel or has_nvidia:
        return "directml"
    return "cpu"


def venv_paths(repo_root: str) -> tuple[str, str, str]:
    venv_dir = os.path.join(repo_root, "venv")
    py = os.path.join(venv_dir, "Scripts", "python.exe")
    pyw = os.path.join(venv_dir, "Scripts", "pythonw.exe")
    pip = os.path.join(venv_dir, "Scripts", "pip.exe")
    return py, pyw, pip


def ensure_venv(repo_root: str, ui_log) -> tuple[str, str, str]:
    venv_dir = os.path.join(repo_root, "venv")
    py, pyw, pip = venv_paths(repo_root)

    if os.path.exists(py) and os.path.exists(pip):
        ui_log(f"venv: Venv exists: {venv_dir}")
        return py, pyw, pip

    ui_log(f"venv: Creating venv: {venv_dir}")
    ensure_dir(venv_dir)

    run_subprocess([sys.executable, "-m", "venv", venv_dir], env=None, cwd=repo_root, on_line=lambda s: ui_log(f"venv: {s}"), check=True)

    if not os.path.exists(py) or not os.path.exists(pip):
        raise RuntimeError("Venv creation failed (python.exe / pip.exe not found).")

    return py, pyw, pip


def get_pkg_version(venv_py: str, name: str) -> str | None:
    code = r"""import sys
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
"""
    try:
        p = subprocess.run([venv_py, "-c", code, name], capture_output=True, text=True, check=False, **_win_hidden_subprocess_kwargs())
        if p.returncode == 0:
            v = (p.stdout or "").strip()
            return v or None
    except Exception:
        return None
    return None


def ensure_pip_stack(venv_py: str, ui_log) -> None:
    ui_log("packages: Upgrading pip/setuptools/wheel ...")
    run_subprocess([venv_py, "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel", "--no-warn-script-location"], env=None, cwd=None, on_line=lambda s: ui_log(f"pip: {s}"), check=True)

    for tool in ["pip", "setuptools", "wheel"]:
        v = get_pkg_version(venv_py, tool)
        if not v:
            raise RuntimeError(f"Core tool missing after upgrade: {tool}")
        ui_log(f"packages: OK: {tool} {v}")

    pinned = [
        "diffusers==0.30.3",
        "transformers==4.44.2",
        "accelerate==0.33.0",
        "safetensors==0.4.5",
        "huggingface_hub==0.24.7",
        "pillow",
        "numpy",
        "sentencepiece",
        "protobuf",
        "scikit-learn",
        "pandas",
        "reportlab",
        "matplotlib",
    ]

    for spec in pinned:
        ui_log(f"packages: Ensuring {spec} ...")
        run_subprocess([venv_py, "-m", "pip", "install", spec], env=None, cwd=None, on_line=lambda s: ui_log(f"pip: {s}"), check=True)


def test_backend_in_venv(venv_py: str, backend: str, ui_log) -> bool:
    code = r"""import importlib.util
import sys
import traceback

backend = sys.argv[1]

if backend == "cuda":
    try:
        import torch
        ok = bool(torch.cuda.is_available())
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
"""
    p = subprocess.run([venv_py, "-c", code, backend], capture_output=True, text=True, check=False, **_win_hidden_subprocess_kwargs())
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.splitlines():
        s = line.strip()
        if s:
            ui_log(f"backend-check: {s}")
    return p.returncode == 0


def install_torch_for_backend(venv_py: str, backend: str, ui_log) -> None:
    ui_log(f"packages: Installing torch for backend: {backend}")
    if backend == "cuda":
        run_subprocess([venv_py, "-m", "pip", "install", "--upgrade", "torch", "torchvision", "--index-url", "https://download.pytorch.org/whl/cu121"], env=None, cwd=None, on_line=lambda s: ui_log(f"pip: {s}"), check=True)
        return
    if backend == "directml":
        run_subprocess([venv_py, "-m", "pip", "install", "--upgrade", "torch-directml"], env=None, cwd=None, on_line=lambda s: ui_log(f"pip: {s}"), check=True)
        return
    run_subprocess([venv_py, "-m", "pip", "install", "--upgrade", "torch", "torchvision", "--index-url", "https://download.pytorch.org/whl/cpu"], env=None, cwd=None, on_line=lambda s: ui_log(f"pip: {s}"), check=True)


def copy_if_missing(src: str, dst: str) -> None:
    if os.path.exists(dst):
        return
    ensure_dir(os.path.dirname(dst))
    shutil.copy2(src, dst)


class BootstrapUI:
    def __init__(self, repo_root: str):
        self.repo_root = os.path.abspath(repo_root)
        self.app_dir = os.path.join(self.repo_root, "app")
        self.cache_dir = os.path.join(self.repo_root, "cache")
        self.config_defaults = os.path.join(self.repo_root, "rwe_config.json")

        self.venv_py = ""
        self.venv_pyw = ""
        self.backend = "cpu"
        self.run_root = ""
        self.out_dir = ""
        self.run_config = ""
        self.progress_file = ""
        self.token_file = ""

        self._dots_i = 0

        self.q: "queue.Queue[tuple[str, str]]" = queue.Queue()
        self.worker: threading.Thread | None = None

        self.root = tk.Tk()
        self.root.title("RWE Setup")
        try:
            self.root.state("zoomed")
        except Exception:
            self.root.geometry("950x700")
        self.root.minsize(950, 700)

        style = ttk.Style(self.root)
        if "vista" in style.theme_names():
            style.theme_use("vista")
        elif "clam" in style.theme_names():
            style.theme_use("clam")

        self._build_ui()
        self._tick()

        # Auto-start on launch.
        try:
            self.root.after(250, self.start)
        except Exception:
            pass

    def _build_ui(self) -> None:
        mainf = ttk.Frame(self.root, padding=14)
        mainf.pack(fill=tk.BOTH, expand=True)

        ttk.Label(mainf, text="RWE Setup", font=("Segoe UI", 16, "bold")).pack(anchor=tk.W)
        self.status_var = tk.StringVar(value="Ready.")
        ttk.Label(mainf, textvariable=self.status_var, foreground="#555555").pack(anchor=tk.W, pady=(2, 10))

        self.bar = ttk.Progressbar(mainf, mode="determinate", maximum=100)
        self.bar.pack(fill=tk.X)

        top = ttk.Frame(mainf)
        top.pack(fill=tk.X, pady=(10, 8))

        self.resume_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(top, text="Resume latest run (if available)", variable=self.resume_var).pack(side=tk.LEFT)

        ttk.Label(top, text="Backend:").pack(side=tk.LEFT, padx=(16, 6))
        self.backend_var = tk.StringVar(value="auto")
        self.backend_cb = ttk.Combobox(top, textvariable=self.backend_var, width=10, values=["auto", "cuda", "directml", "cpu"], state="readonly")
        self.backend_cb.pack(side=tk.LEFT)

        ttk.Label(top, text="HF token:").pack(side=tk.LEFT, padx=(16, 6))
        self.token_var = tk.StringVar(value="")
        self.token_entry = ttk.Entry(top, textvariable=self.token_var, width=46)
        self.token_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        self.start_btn = ttk.Button(top, text="Start", command=self.start)
        self.start_btn.pack(side=tk.RIGHT)
        self.quit_btn = ttk.Button(top, text="Quit", command=self._quit)
        self.quit_btn.pack(side=tk.RIGHT, padx=(0, 8))

        self.msg_var = tk.StringVar(value="")
        ttk.Label(mainf, textvariable=self.msg_var, wraplength=1200, justify=tk.LEFT).pack(anchor=tk.W, pady=(6, 8))

        lf = ttk.Labelframe(mainf, text="Log", padding=10)
        lf.pack(fill=tk.BOTH, expand=True)

        self.log = tk.Text(lf, height=18, wrap="word")
        self.log.pack(fill=tk.BOTH, expand=True)
        self.log.configure(state="disabled")

        self.root.protocol("WM_DELETE_WINDOW", self._quit)

    def _quit(self) -> None:
        if self.worker and self.worker.is_alive():
            if not messagebox.askyesno("Quit", "Setup is still running. Quit anyway?"):
                return
        self.root.destroy()

    def ui_log(self, line: str) -> None:
        self.q.put(("log", line))

    def ui_progress(self, percent: float, msg: str) -> None:
        self.q.put(("progress", f"{percent}|{msg}"))

    def _append_log(self, line: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", f"{_now_ts()} {line}\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _tick(self) -> None:
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "log":
                    self._append_log(payload)
                elif kind == "progress":
                    try:
                        p_str, m = payload.split("|", 1)
                        p = float(p_str)
                    except Exception:
                        p, m = 0.0, payload
                    self.bar["value"] = max(0.0, min(100.0, p))
                    self.msg_var.set(m)
                    self.status_var.set(m)
        except queue.Empty:
            pass
        self.root.after(120, self._tick)

    def start(self) -> None:
        if self.worker and self.worker.is_alive():
            return

        self.start_btn.configure(state="disabled")
        self.backend_cb.configure(state="disabled")
        self.token_entry.configure(state="disabled")

        self.worker = threading.Thread(target=self._run_all, daemon=True)
        self.worker.start()

    def _run_prefetch(self, prefetch_py: str, env_prefetch: dict, prefetch_log: str, on_line) -> None:
        # Run prefetch while continuously reflecting progress from the progress JSON file.
        hidden = _win_hidden_subprocess_kwargs()
        # Force UTF-8 so logs don't get mojibake when subprocesses print umlauts etc.
        env_prefetch = dict(env_prefetch or {})
        env_prefetch.setdefault("PYTHONIOENCODING", "utf-8")

        p = subprocess.Popen(
            [self.venv_py, prefetch_py, "--progress", self.progress_file],
            cwd=self.repo_root,
            env=env_prefetch,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            universal_newlines=True,
            **hidden,
        )

        last_state_msg = ""
        last_state_ts = 0.0
        last_anim_ts = 0.0

        def reader() -> None:
            try:
                assert p.stdout is not None
                for line in p.stdout:
                    s = line.rstrip("\r\n")
                    if not s:
                        continue
                    on_line(s)
            except Exception:
                pass

        t = threading.Thread(target=reader, daemon=True)
        t.start()

        while True:
            rc = p.poll()
            st = read_progress_state(self.progress_file)
            try:
                pct = float(st.get("percent", 0.0))
            except Exception:
                pct = 0.0
            msg = str(st.get("message", "") or "").strip()
            phase = str(st.get("phase", "") or "").strip()

            # Map 0..1 prefetch progress to the overall UI percent span
            mapped = 60.0 + (min(1.0, max(0.0, pct)) * 18.0)

            # Some long downloads keep repeating the same message (or stop emitting output).
            # Animate a dot suffix when there is no *new* message to avoid looking frozen.
            now = time.time()
            if msg and (msg != last_state_msg):
                self.ui_progress(mapped, msg)
                last_state_msg = msg
                last_state_ts = now
                self._dots_i = 0
            else:
                if (now - last_state_ts) > 0.9 and (now - last_anim_ts) > 0.6:
                    base = msg or last_state_msg or "Prefetching models (downloads happen here)"
                    dots = "." * (self._dots_i % 4)
                    hb = f"{base}{dots}"
                    if phase:
                        hb = f"{hb} [{phase}]"
                    self.ui_progress(mapped, hb)
                    self._dots_i += 1
                    last_anim_ts = now

            if rc is not None:
                break
            time.sleep(0.25)

        try:
            p.wait(timeout=2.0)
        except Exception:
            pass

        if p.returncode != 0:
            raise RuntimeError(f"Prefetch failed (ExitCode={p.returncode})")

    def _run_all(self) -> None:
        try:
            ensure_dir(self.cache_dir)
            ensure_dir(self.app_dir)

            self.ui_progress(2, "Preparing run folder...")
            latest = find_latest_run_folder(self.repo_root)
            if self.resume_var.get() and latest:
                self.run_root = latest
                self.ui_log(f"resume: Resuming latest run: {self.run_root}")
            else:
                self.run_root = new_run_folder(self.repo_root)
                self.ui_log(f"resume: New run folder: {self.run_root}")

            self.out_dir = os.path.join(self.run_root, "outputs")
            ensure_dir(self.out_dir)

            self.run_config = os.path.join(self.run_root, "rwe_config.json")
            copy_if_missing(self.config_defaults, self.run_config)

            write_run_slideshow_starter(self.run_root, self.app_dir)

            self.progress_file = os.path.join(self.run_root, "bootstrap_progress.jsonl")
            try:
                if os.path.exists(self.progress_file):
                    os.remove(self.progress_file)
            except Exception:
                pass

            self.token_file = os.path.join(self.run_root, "hf_token.json")
            token = self.token_var.get().strip()
            save_json(self.token_file, {"use": bool(token), "token": token})

            env_base = os.environ.copy()
            env_base["HF_HOME"] = self.cache_dir

            self.ui_progress(10, "Creating or validating venv...")
            self.venv_py, self.venv_pyw, _pip = ensure_venv(self.repo_root, self.ui_log)

            self.ui_progress(18, "Detecting hardware...")
            gpus = detect_gpu_names()
            self.ui_log("Detected GPUs:")
            if not gpus:
                self.ui_log("  (none found via WMI)")
            for g in gpus:
                self.ui_log(f"  - {g}")
            self.ui_log(f"Vulkan runtime detected: {'yes' if vulkan_present() else 'no'}")

            requested = self.backend_var.get().strip().lower() or "auto"
            preferred = choose_backend(gpus) if requested == "auto" else requested
            self.ui_log(f"Selected backend (requested): {requested}")
            self.ui_log(f"Selected backend (pre-check): {preferred}")

            self.ui_progress(25, "Installing Python packages...")
            ensure_pip_stack(self.venv_py, self.ui_log)

            backend = preferred if preferred in ["cuda", "directml", "cpu"] else "cpu"
            self.ui_progress(42, f"Installing torch backend: {backend} ...")
            install_torch_for_backend(self.venv_py, backend, self.ui_log)

            self.ui_progress(50, f"Verifying backend: {backend} ...")
            ok = test_backend_in_venv(self.venv_py, backend, self.ui_log)
            if not ok and backend == "cuda":
                self.ui_log("CUDA verify failed. Falling back to DirectML...")
                backend = "directml"
                install_torch_for_backend(self.venv_py, backend, self.ui_log)
                ok = test_backend_in_venv(self.venv_py, backend, self.ui_log)
            if not ok and backend == "directml":
                self.ui_log("DirectML verify failed. Falling back to CPU...")
                backend = "cpu"
                install_torch_for_backend(self.venv_py, backend, self.ui_log)
                ok = test_backend_in_venv(self.venv_py, backend, self.ui_log)
            if not ok:
                self.ui_log("Backend verify failed. Using CPU.")
                backend = "cpu"

            self.backend = backend
            self.ui_log(f"Selected backend (verified): {self.backend}")

            self.ui_progress(60, "Prefetching models (downloads happen here)...")
            prefetch_py = os.path.join(self.app_dir, "rwe_prefetch_models.py")
            if os.path.exists(prefetch_py):
                prefetch_log = os.path.join(self.run_root, "prefetch_output.log")
                try:
                    if os.path.exists(prefetch_log):
                        os.remove(prefetch_log)
                except Exception:
                    pass

                env_prefetch = env_base.copy()
                env_prefetch["RWE_PROGRESS"] = self.progress_file
                env_prefetch["RWE_BOOTSTRAP_PROGRESS"] = self.progress_file
                env_prefetch["RWE_BACKEND"] = self.backend
                if token:
                    env_prefetch["HF_TOKEN"] = token

                def on_prefetch_line(s: str) -> None:
                    self.ui_log(f"prefetch: {s}")
                    try:
                        with open(prefetch_log, "a", encoding="utf-8") as f:
                            f.write(s + "\n")
                    except Exception:
                        pass

                self._run_prefetch(prefetch_py=prefetch_py, env_prefetch=env_prefetch, prefetch_log=prefetch_log, on_line=on_prefetch_line)
            else:
                self.ui_log("prefetch: rwe_prefetch_models.py not found, skipping.")

            self.ui_progress(78, "Opening config editor...")
            editor_py = os.path.join(self.app_dir, "rwe_config_editor.py")
            if os.path.exists(editor_py):
                env_editor = env_base.copy()
                env_editor["RWE_BACKEND"] = self.backend
                if token:
                    env_editor["HF_TOKEN"] = token

                env_editor = dict(env_editor or {})
                env_editor.setdefault("PYTHONIOENCODING", "utf-8")
                code = subprocess.call([self.venv_py, editor_py, "--config", self.run_config, "--defaults", self.config_defaults, "--outputs", self.out_dir], cwd=self.repo_root, env=env_editor, **_win_hidden_subprocess_kwargs())
                if code != 0:
                    self.ui_log("Config editor was closed. Continuing with the current config.")
            else:
                self.ui_log("Config editor missing. Continuing.")

            self.ui_progress(88, "Starting generation...")
            run_ui_py = os.path.join(self.app_dir, "rwe_run_ui.py")
            rwe_py = os.path.join(self.app_dir, "rwe_v04.py")

            env_run = env_base.copy()
            env_run["RWE_CONFIG"] = self.run_config
            env_run["RWE_OUT"] = self.out_dir
            env_run["RWE_BACKEND"] = self.backend

            cfg = load_json(self.run_config)
            iters = 30
            try:
                iters = int(cfg.get("runtime_defaults", {}).get("values", {}).get("iterations", 30))
            except Exception:
                iters = 30
            env_run["RWE_ITERS"] = str(max(1, iters))
            if token:
                env_run["HF_TOKEN"] = token

            ui_proc = None
            if os.path.exists(run_ui_py):
                try:
                    ui_proc = subprocess.Popen([self.venv_py, run_ui_py, "--run-root", self.run_root], cwd=self.repo_root, env=env_run)
                    self.ui_log("run-ui: started")
                except Exception as ex:
                    self.ui_log(f"run-ui: failed to start: {ex}")

            if not os.path.exists(rwe_py):
                raise RuntimeError(f"Missing generator: {rwe_py}")

            run_subprocess([self.venv_py, rwe_py], env=env_run, cwd=self.repo_root, on_line=lambda s: self.ui_log(f"run: {s}"), check=True)

            self.ui_progress(100, "Done.")
            self.ui_log("Generation finished.")

            pdf_path = os.path.join(self.out_dir, "atlas", "rwe_atlas_v04.pdf")
            if os.path.exists(pdf_path):
                try:
                    os.startfile(pdf_path)
                except Exception:
                    pass

            if ui_proc is not None:
                try:
                    ui_proc.terminate()
                except Exception:
                    pass

        except Exception as ex:
            self.ui_log(f"[ERROR] {ex}")
            self.ui_progress(0, "Failed.")
            try:
                messagebox.showerror("Error", str(ex))
            except Exception:
                pass
        finally:
            self.ui_log("Bootstrap finished. You can close this window.")

    def run(self) -> None:
        self.root.mainloop()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="Path to the RWE repo root")
    args = ap.parse_args()

    ui = BootstrapUI(args.repo)
    ui.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())