import argparse
import json
import os
import sys
import subprocess
from pathlib import Path
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

DEFAULT_GENESIS_URL = "https://upload.wikimedia.org/wikipedia/commons/4/40/The_Kiss_-_Gustav_Klimt_-_Google_Cultural_Institute.jpg"

def load_json(path: str) -> dict:
    try:
        if not path or not os.path.exists(path):
            return {}
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f) or {}
    except Exception:
        return {}

def save_json(path: str, data: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

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

def list_run_folders(script_dir: str) -> list[str]:
    runs: list[str] = []
    try:
        date_dirs = []
        for name in os.listdir(script_dir):
            p = os.path.join(script_dir, name)
            if os.path.isdir(p) and len(name) == 10 and name[4] == "-" and name[7] == "-":
                date_dirs.append(p)
        date_dirs.sort(reverse=True)
        for d in date_dirs:
            sub_runs = []
            for name in os.listdir(d):
                p = os.path.join(d, name)
                if os.path.isdir(p) and name.startswith("run-") and len(name) == 19:
                    sub_runs.append(p)
            sub_runs.sort(reverse=True)
            for r in sub_runs:
                out_dir = os.path.join(r, "outputs")
                if os.path.exists(os.path.join(out_dir, "world_state.json")) or os.path.exists(os.path.join(out_dir, "world_log.jsonl")):
                    runs.append(r)
    except Exception:
        pass
    return runs

def new_run_folder(script_dir: str) -> str:
    import datetime
    ds = datetime.datetime.now().strftime("%Y-%m-%d")
    base = os.path.join(script_dir, ds)
    ensure_dir(base)
    rs = datetime.datetime.now().strftime("run-%Y%m%d-%H%M%S")
    run = os.path.join(base, rs)
    ensure_dir(run)
    return run

def try_fullscreen(root: tk.Tk) -> None:
    try:
        root.attributes("-fullscreen", True)
    except Exception:
        pass
    try:
        root.state("zoomed")
    except Exception:
        pass
    try:
        root.attributes("-topmost", True)
    except Exception:
        pass

def read_cfg_value(cfg: dict, path: str, default=None):
    cur = cfg
    for key in path.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur if cur is not None else default

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--config-default", required=True)
    parser.add_argument("--config-run", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--launch-out", default="")
    args = parser.parse_args()

    script_dir = os.path.abspath(args.script_dir)
    config_default = os.path.abspath(args.config_default)
    config_run = os.path.abspath(args.config_run)
    py = os.path.abspath(args.python)

    default_cfg = load_json(config_default)
    run_cfg = load_json(config_run) or default_cfg

    root = tk.Tk()
    root.title("RWE Launcher")
    try_fullscreen(root)

    style = ttk.Style(root)
    if "vista" in style.theme_names():
        style.theme_use("vista")
    elif "clam" in style.theme_names():
        style.theme_use("clam")

    outer = ttk.Frame(root, padding=18)
    outer.pack(fill=tk.BOTH, expand=True)

    title = ttk.Label(outer, text="Reflective World Engine (RWE) v0.4", font=("Segoe UI", 22, "bold"))
    title.pack(anchor=tk.W, pady=(0, 8))

    sub = ttk.Label(outer, text="Konfiguration eingeben und Start drücken. ESC beendet.", foreground="#555555")
    sub.pack(anchor=tk.W, pady=(0, 16))

    form = ttk.Frame(outer)
    form.pack(fill=tk.BOTH, expand=True)

    def row(parent, r: int, label: str):
        lbl = ttk.Label(parent, text=label)
        lbl.grid(row=r, column=0, sticky="w", pady=6, padx=(0, 12))
        return lbl

    run_folders = list_run_folders(script_dir)
    resume_var = tk.BooleanVar(value=False)
    runfolder_var = tk.StringVar(value=run_folders[0] if run_folders else "")
    iters_default = int(read_cfg_value(run_cfg, "runtime_defaults.values.iterations", 10) or 10)
    iters_var = tk.StringVar(value=str(iters_default))
    hf_var = tk.StringVar(value="")
    backend_var = tk.StringVar(value="auto")
    show_images_var = tk.BooleanVar(value=False)

    genesis_enabled_var = tk.BooleanVar(value=bool(read_cfg_value(run_cfg, "genesis_image.values.enabled", False)))
    genesis_url_var = tk.StringVar(value=str(read_cfg_value(run_cfg, "genesis_image.values.url", DEFAULT_GENESIS_URL) or DEFAULT_GENESIS_URL))
    initial_words_val = read_cfg_value(run_cfg, "initial_words.values", [])
    if not isinstance(initial_words_val, list):
        initial_words_val = []
    genesis_words_var = tk.StringVar(value=", ".join(str(w).strip() for w in initial_words_val if str(w).strip()))
    use_style_var = tk.BooleanVar(value=bool(read_cfg_value(run_cfg, "genesis_image.values.use_style", True)))
    style_strength_var = tk.StringVar(value=str(read_cfg_value(run_cfg, "genesis_image.values.style_strength", 0.55)))
    style_iters_var = tk.StringVar(value=str(read_cfg_value(run_cfg, "genesis_image.values.style_iterations", 3)))

    r = 0
    row(form, r, "Resume previous run")
    resume_cb = ttk.Checkbutton(form, variable=resume_var)
    resume_cb.grid(row=r, column=1, sticky="w")
    r += 1

    runfolder_label = row(form, r, "Run folder")
    run_entry = ttk.Combobox(form, textvariable=runfolder_var, width=88, values=run_folders, state="readonly")
    run_entry.grid(row=r, column=1, sticky="we")
    r += 1

    row(form, r, "Iterations")
    ttk.Entry(form, textvariable=iters_var, width=10).grid(row=r, column=1, sticky="w")
    r += 1

    row(form, r, "Hugging Face token (optional)")
    ttk.Entry(form, textvariable=hf_var, width=60, show="*").grid(row=r, column=1, sticky="w")
    r += 1

    row(form, r, "Backend")
    ttk.Combobox(form, textvariable=backend_var, values=["auto", "cuda", "directml", "cpu"], state="readonly", width=12).grid(row=r, column=1, sticky="w")
    r += 1

    row(form, r, "Show images fullscreen during run")
    ttk.Checkbutton(form, variable=show_images_var).grid(row=r, column=1, sticky="w")
    r += 1

    sep = ttk.Separator(form, orient="horizontal")
    sep.grid(row=r, column=0, columnspan=3, sticky="we", pady=14)
    r += 1

    row(form, r, "Use genesis image")
    ttk.Checkbutton(form, variable=genesis_enabled_var).grid(row=r, column=1, sticky="w")
    r += 1

    row(form, r, "Genesis image URL (optional)")
    genesis_url_entry = ttk.Entry(form, textvariable=genesis_url_var, width=86)
    genesis_url_entry.grid(row=r, column=1, sticky="we")

    def browse_genesis_image():
        path = filedialog.askopenfilename(
            title="Select genesis image",
            filetypes=[("Image files", "*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp;*.tiff"), ("All files", "*.*")],
        )
        if not path:
            return
        try:
            file_url = Path(path).resolve().as_uri()
        except Exception:
            file_url = path
        genesis_url_var.set(file_url)
        genesis_enabled_var.set(True)

    genesis_btns = ttk.Frame(form)
    genesis_btns.grid(row=r, column=2, sticky="e", padx=(12, 0))
    ttk.Button(genesis_btns, text="Local…", command=browse_genesis_image).pack(side=tk.LEFT)
    r += 1

    row(form, r, "Genesis words (comma-separated)")
    genesis_words_entry = ttk.Entry(form, textvariable=genesis_words_var, width=90)
    genesis_words_entry.grid(row=r, column=1, sticky="we")
    r += 1

    row(form, r, "Use genesis as style (Img2Img)")
    use_style_cb = ttk.Checkbutton(form, variable=use_style_var)
    use_style_cb.grid(row=r, column=1, sticky="w")
    r += 1

    row(form, r, "Style strength (0.0 - 1.0)")
    style_strength_entry = ttk.Entry(form, textvariable=style_strength_var, width=10)
    style_strength_entry.grid(row=r, column=1, sticky="w")
    r += 1

    row(form, r, "Style iterations (count)")
    style_iters_entry = ttk.Entry(form, textvariable=style_iters_var, width=10)
    style_iters_entry.grid(row=r, column=1, sticky="w")
    r += 1

    def update_genesis_state() -> None:
        enabled = bool(genesis_enabled_var.get())
        state = "normal" if enabled else "disabled"
        genesis_url_entry.configure(state=state)
        use_style_cb.configure(state=state)
        style_state = "normal" if (enabled and use_style_var.get()) else "disabled"
        genesis_words_entry.configure(state="disabled" if enabled else "normal")
        if enabled and not genesis_url_var.get().strip():
            genesis_url_var.set(DEFAULT_GENESIS_URL)
        style_strength_entry.configure(state=style_state)
        style_iters_entry.configure(state=style_state)

    genesis_enabled_var.trace_add("write", lambda *_: update_genesis_state())
    use_style_var.trace_add("write", lambda *_: update_genesis_state())

    form.columnconfigure(1, weight=1)

    footer = ttk.Frame(outer)
    footer.pack(fill=tk.X, pady=(16, 0))

    def open_settings():
        out_dir = ""
        rf = runfolder_var.get().strip()
        if rf:
            out_dir = os.path.join(rf, "outputs")
        editor = os.path.join(os.path.dirname(__file__), "rwe_config_editor.py")
        try:
            subprocess.run([py, editor, "--config", config_run, "--defaults", config_default, "--outputs", out_dir], check=False)
        except Exception as exc:
            messagebox.showerror("Settings", f"Could not open settings:\n{exc}")

    ttk.Button(footer, text="Settings…", command=open_settings).pack(side=tk.LEFT)

    def cancel():
        root.destroy()

    def start():
        # Validate
        try:
            iters = int(iters_var.get().strip())
            if iters < 1 or iters > 100000:
                raise ValueError()
        except Exception:
            messagebox.showerror("Error", "Iterations must be a positive integer (1..100000).")
            return

        rf = runfolder_var.get().strip()
        if resume_var.get():
            if not rf:
                latest = find_latest_run_folder(script_dir)
                if not latest:
                    messagebox.showerror("Resume", "No previous run found. Disable resume or choose a run folder.")
                    return
                rf = latest
        else:
            rf = new_run_folder(script_dir)

        # Update run config genesis fields
        cfg = load_json(config_run) or load_json(config_default) or {}
        gi = cfg.setdefault("genesis_image", {})
        if not isinstance(gi, dict):
            gi = {}
            cfg["genesis_image"] = gi
        values = gi.setdefault("values", {})
        if not isinstance(values, dict):
            values = {}
            gi["values"] = values
        values["enabled"] = bool(genesis_enabled_var.get())
        values["url"] = genesis_url_var.get().strip() if values["enabled"] else ""
        try:
            values["analysis_keywords"] = int(read_cfg_value(cfg, "genesis_image.values.analysis_keywords", 12) or 12)
        except Exception:
            values["analysis_keywords"] = 12
        values["use_style"] = bool(use_style_var.get())
        try:
            st = float(style_strength_var.get().strip().replace(",", "."))
        except Exception:
            st = 0.55
        st = max(0.0, min(1.0, st))
        values["style_strength"] = st
        try:
            si = int(style_iters_var.get().strip())
        except Exception:
            si = 3
        si = max(1, min(9999, si))
        values["style_iterations"] = si

        words_raw = genesis_words_var.get().strip()
        words_list = [w.strip() for w in words_raw.split(",") if w.strip()]
        initial_sec = cfg.setdefault("initial_words", {})
        if not isinstance(initial_sec, dict):
            initial_sec = {}
            cfg["initial_words"] = initial_sec
        initial_sec["values"] = words_list

        save_json(config_run, cfg)

        opts = {
            "resume": bool(resume_var.get()),
            "run_root": rf,
            "iterations": iters,
            "hf_token": hf_var.get().strip(),
            "backend": backend_var.get().strip().lower() or "auto",
            "show_images": bool(show_images_var.get()),
        }

        ensure_dir(os.path.join(rf, "outputs"))
        opts_path = os.path.join(rf, "launch_options.json")
        save_json(opts_path, opts)
        if args.launch_out:
            save_json(os.path.abspath(args.launch_out), opts)

        root.destroy()

    ttk.Button(footer, text="Cancel", command=cancel).pack(side=tk.RIGHT, padx=(8, 0))
    ttk.Button(footer, text="Start", command=start).pack(side=tk.RIGHT)

    def on_esc(_ev=None):
        cancel()

    if not run_folders:
        run_entry.grid_remove()
        runfolder_label.grid_remove()
        resume_cb.configure(state="disabled")
    root.bind("<Escape>", on_esc)
    update_genesis_state()
    root.mainloop()
    return 0

if __name__ == "__main__":
    sys.exit(main())
