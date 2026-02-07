import argparse
import copy
import json
import os
import sys
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

DEFAULT_GENESIS_URL = "https://upload.wikimedia.org/wikipedia/commons/4/40/The_Kiss_-_Gustav_Klimt_-_Google_Cultural_Institute.jpg"

LIST_SECTIONS = [
    ("initial_words", "Initial Motifs"),
    ("banned_motifs", "Blocked Motifs"),
    ("stopwords", "Stopwords"),
    ("style_pool", "Style Pool"),
    ("novelty_motif_pool", "Novelty Motif Pool"),
    ("escape_motifs", "Escape Motifs"),
]


SIZE_PRESETS = [
    ("standard_square", "Standard (1024×1024)", 1024, 1024),
    ("tshirt_square", "T‑Shirt / Sticker (1536×1536)", 1536, 1536),
    ("portrait_3_4", "Poster Portrait 3:4 (832×1216)", 832, 1216),
    ("landscape_4_3", "Poster Landscape 4:3 (1216×832)", 1216, 832),
    ("portrait_2_3", "Art Print Portrait 2:3 (1024×1536)", 1024, 1536),
    ("landscape_3_2", "Art Print Landscape 3:2 (1536×1024)", 1536, 1024),
]


def load_json(path: str) -> dict:
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f) or {}


def load_license_text(path: str) -> str:
    if not path or not os.path.exists(path):
        return "License file not found."
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip() or "License file is empty."


def ensure_section(cfg: dict, key: str) -> dict:
    sec = cfg.get(key)
    if not isinstance(sec, dict):
        sec = {}
        cfg[key] = sec
    if "values" not in sec:
        sec["values"] = {}
    if not isinstance(sec["values"], dict):
        sec["values"] = {}
    return sec


def ensure_list_section(cfg: dict, key: str) -> dict:
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
        lines.append("Effects:")
        for e in effects:
            lines.append(f"• {e}")
    return "\n".join(lines)


def build_ui(cfg_path: str, default_cfg: dict, cfg: dict, outputs_dir: str) -> None:
    root = tk.Tk()
    root.title("RWE Configuration Editor")
    root.geometry("920x760")
    root.minsize(840, 660)

    style = ttk.Style(root)
    if "vista" in style.theme_names():
        style.theme_use("vista")
    elif "clam" in style.theme_names():
        style.theme_use("clam")

    main = ttk.Frame(root, padding=12)
    main.pack(fill=tk.BOTH, expand=True)

    header = ttk.Label(main, text="RWE Configuration Editor", font=("Segoe UI", 16, "bold"))
    header.pack(anchor=tk.W, pady=(0, 4))

    path_label = ttk.Label(main, text=f"File: {cfg_path}", foreground="#555555")
    path_label.pack(anchor=tk.W, pady=(0, 10))

    notebook = ttk.Notebook(main)
    notebook.pack(fill=tk.BOTH, expand=True)

    list_widgets = {}

    # Genesis tab MUST be first
    genesis_frame = ttk.Frame(notebook, padding=12)
    notebook.add(genesis_frame, text="Genesis")

    genesis_hint = describe_section(cfg if cfg else default_cfg, "genesis_image")
    genesis_label = ttk.Label(genesis_frame, text=genesis_hint, wraplength=860, justify=tk.LEFT)
    genesis_label.pack(anchor=tk.W, pady=(0, 8))

    genesis_enabled_var = tk.BooleanVar(value=False)

    enabled_row = ttk.Frame(genesis_frame)
    enabled_row.pack(anchor=tk.W, pady=(4, 8), fill=tk.X)

    enabled_cb = ttk.Checkbutton(enabled_row, text="Use genesis image", variable=genesis_enabled_var)
    enabled_cb.pack(side=tk.LEFT)

    genesis_row = ttk.Frame(genesis_frame)
    genesis_row.pack(anchor=tk.W, pady=(4, 8), fill=tk.X)

    genesis_url_label = ttk.Label(genesis_row, text="Genesis image URL:")
    genesis_url_label.pack(side=tk.LEFT)

    genesis_url_var = tk.StringVar()
    genesis_url_entry = ttk.Entry(genesis_row, textvariable=genesis_url_var, width=70)
    genesis_url_entry.pack(side=tk.LEFT, padx=(8, 0), fill=tk.X, expand=True)

    genesis_kw_row = ttk.Frame(genesis_frame)
    genesis_kw_row.pack(anchor=tk.W, pady=(4, 8))

    genesis_kw_label = ttk.Label(genesis_kw_row, text="Max analysis keywords:")
    genesis_kw_label.pack(side=tk.LEFT)

    genesis_kw_var = tk.StringVar()
    genesis_kw_entry = ttk.Entry(genesis_kw_row, textvariable=genesis_kw_var, width=10)
    genesis_kw_entry.pack(side=tk.LEFT, padx=(8, 0))

    genesis_style_row = ttk.Frame(genesis_frame)
    genesis_style_row.pack(anchor=tk.W, pady=(4, 8))

    genesis_style_var = tk.BooleanVar(value=False)
    genesis_style_cb = ttk.Checkbutton(genesis_style_row, text="Use genesis as style reference (img2img)", variable=genesis_style_var)
    genesis_style_cb.pack(side=tk.LEFT)

    genesis_strength_row = ttk.Frame(genesis_frame)
    genesis_strength_row.pack(anchor=tk.W, pady=(4, 8))

    genesis_strength_label = ttk.Label(genesis_strength_row, text="Strength (img2img, 0.0 - 1.0):")
    genesis_strength_label.pack(side=tk.LEFT)

    genesis_strength_var = tk.StringVar()
    genesis_strength_entry = ttk.Entry(genesis_strength_row, textvariable=genesis_strength_var, width=10)
    genesis_strength_entry.pack(side=tk.LEFT, padx=(8, 0))

    genesis_iters_row = ttk.Frame(genesis_frame)
    genesis_iters_row.pack(anchor=tk.W, pady=(4, 8))

    genesis_iters_label = ttk.Label(genesis_iters_row, text="Genesis iterations (img2img):")
    genesis_iters_label.pack(side=tk.LEFT)

    genesis_iters_var = tk.StringVar()
    genesis_iters_entry = ttk.Entry(genesis_iters_row, textvariable=genesis_iters_var, width=10)
    genesis_iters_entry.pack(side=tk.LEFT, padx=(8, 0))

    def update_genesis_enabled_state() -> None:
        enabled = bool(genesis_enabled_var.get())
        state = "normal" if enabled else "disabled"
        try:
            genesis_url_entry.configure(state=state)
        except tk.TclError:
            pass
        if enabled and not genesis_url_var.get().strip():
            genesis_url_var.set(DEFAULT_GENESIS_URL)

    genesis_enabled_var.trace_add("write", lambda *_: update_genesis_enabled_state())

    # List tabs
    for key, title in LIST_SECTIONS:
        frame = ttk.Frame(notebook, padding=12)
        notebook.add(frame, text=title)

        hint_text = describe_section(cfg if cfg else default_cfg, key)
        hint_label = ttk.Label(frame, text=hint_text, wraplength=860, justify=tk.LEFT)
        hint_label.pack(anchor=tk.W, pady=(0, 8))

        helper = ttk.Label(frame, text="One entry per line. Blank lines are ignored.")
        helper.pack(anchor=tk.W, pady=(0, 6))

        text = scrolledtext.ScrolledText(frame, height=16, wrap=tk.WORD)
        text.pack(fill=tk.BOTH, expand=True)
        list_widgets[key] = text

    runtime_frame = ttk.Frame(notebook, padding=12)
    notebook.add(runtime_frame, text="Runtime Defaults")

    runtime_hint = describe_section(cfg if cfg else default_cfg, "runtime_defaults")
    runtime_label = ttk.Label(runtime_frame, text=runtime_hint, wraplength=860, justify=tk.LEFT)
    runtime_label.pack(anchor=tk.W, pady=(0, 8))

    runtime_row = ttk.Frame(runtime_frame)
    runtime_row.pack(anchor=tk.W, pady=(4, 8))

    iter_label = ttk.Label(runtime_row, text="Default iterations:")
    iter_label.pack(side=tk.LEFT)

    iter_var = tk.StringVar()
    iter_entry = ttk.Entry(runtime_row, textvariable=iter_var, width=10)
    iter_entry.pack(side=tk.LEFT, padx=(8, 0))

    size_row = ttk.Frame(runtime_frame)
    size_row.pack(anchor=tk.W, pady=(2, 8), fill=tk.X)

    ttk.Label(size_row, text="Image size:").pack(side=tk.LEFT)

    size_preset_var = tk.StringVar()
    size_options = ttk.Frame(size_row)
    size_options.pack(side=tk.LEFT, padx=(12, 0), fill=tk.X, expand=True)

    for pid, label, w, h in SIZE_PRESETS:
        ttk.Radiobutton(size_options, text=label, value=pid, variable=size_preset_var).pack(anchor=tk.W)

    slideshow_frame = ttk.Frame(notebook, padding=12)
    notebook.add(slideshow_frame, text="Slideshow")

    slideshow_hint = describe_section(cfg if cfg else default_cfg, "slideshow")
    slideshow_label = ttk.Label(slideshow_frame, text=slideshow_hint, wraplength=860, justify=tk.LEFT)
    slideshow_label.pack(anchor=tk.W, pady=(0, 8))

    slideshow_row = ttk.Frame(slideshow_frame)
    slideshow_row.pack(anchor=tk.W, pady=(4, 8))

    interval_label = ttk.Label(slideshow_row, text="Interval (seconds):")
    interval_label.pack(side=tk.LEFT)

    interval_var = tk.StringVar()
    interval_entry = ttk.Entry(slideshow_row, textvariable=interval_var, width=10)
    interval_entry.pack(side=tk.LEFT, padx=(8, 0))

    license_frame = ttk.Frame(notebook, padding=12)
    notebook.add(license_frame, text="License")

    license_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "LICENSE-stable-diffusion.txt"))
    license_content = load_license_text(license_path)
    license_text = scrolledtext.ScrolledText(license_frame, wrap=tk.WORD, height=28)
    license_text.pack(fill=tk.BOTH, expand=True)
    license_text.insert(tk.END, license_content)
    license_text.configure(state=tk.DISABLED)

    def load_into_fields(source_cfg: dict) -> None:
        for key, _ in LIST_SECTIONS:
            sec = ensure_list_section(source_cfg, key)
            text = list_widgets[key]
            text.delete("1.0", tk.END)
            text.insert(tk.END, list_to_text(sec.get("values", [])))

        runtime_sec = source_cfg.get("runtime_defaults", {})
        values = runtime_sec.get("values", {}) if isinstance(runtime_sec, dict) else {}
        iter_val = values.get("iterations", 10)
        iter_var.set(str(iter_val))

        w_val = values.get("width", 1024)
        h_val = values.get("height", 1024)
        preset_val = values.get("size_preset", "")
        if not preset_val:
            for pid, _, pw, ph in SIZE_PRESETS:
                if int(pw) == int(w_val) and int(ph) == int(h_val):
                    preset_val = pid
                    break
        if not preset_val:
            preset_val = "standard_square"
        size_preset_var.set(preset_val)


        slideshow_sec = source_cfg.get("slideshow", {})
        slideshow_values = slideshow_sec.get("values", {}) if isinstance(slideshow_sec, dict) else {}
        interval_val = slideshow_values.get("interval_seconds", 5)
        interval_var.set(str(interval_val))

        genesis_sec = source_cfg.get("genesis_image", {})
        genesis_values = genesis_sec.get("values", {}) if isinstance(genesis_sec, dict) else {}

        enabled = bool(genesis_values.get("enabled", False))
        genesis_enabled_var.set(enabled)

        genesis_url = genesis_values.get("url", "")
        genesis_url_var.set("" if genesis_url is None else str(genesis_url))

        genesis_kw = genesis_values.get("analysis_keywords", 12)
        genesis_kw_var.set(str(genesis_kw))

        use_style = bool(genesis_values.get("use_style", True))
        genesis_style_var.set(use_style)

        strength = genesis_values.get("style_strength", 0.55)
        genesis_strength_var.set(str(strength))

        iters = genesis_values.get("style_iterations", 4)
        genesis_iters_var.set(str(iters))

        update_genesis_enabled_state()

    def handle_open_outputs() -> None:
        if not outputs_dir:
            messagebox.showinfo("Output folder", "No output folder known.")
            return
        if not os.path.exists(outputs_dir):
            messagebox.showwarning("Output folder", "The output folder does not exist yet.")
            return
        try:
            os.startfile(outputs_dir)
        except Exception as exc:
            messagebox.showerror("Output folder", f"Could not open folder:\n{exc}")

    def handle_restore_defaults() -> None:
        load_into_fields(default_cfg)

    def handle_save() -> None:
        updated = copy.deepcopy(cfg)

        for key, _ in LIST_SECTIONS:
            sec = ensure_list_section(updated, key)
            values = text_to_list(list_widgets[key].get("1.0", tk.END))
            if not values:
                messagebox.showerror("Error", f"'{key}' must not be empty.")
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
            messagebox.showerror("Error", "Please enter a valid positive number for iterations.")
            return
        runtime_values["iterations"] = int(iter_text)

        sel_preset = (size_preset_var.get() or "").strip()
        if not sel_preset:
            messagebox.showerror("Error", "Please select an image size.")
            return

        match = None
        for pid, _, w, h in SIZE_PRESETS:
            if pid == sel_preset:
                match = (w, h)
                break
        if match is None:
            messagebox.showerror("Error", "Invalid image size selected.")
            return

        runtime_values["size_preset"] = sel_preset
        runtime_values["width"] = int(match[0])
        runtime_values["height"] = int(match[1])


        slideshow_sec = updated.setdefault("slideshow", {})
        if not isinstance(slideshow_sec, dict):
            slideshow_sec = {}
            updated["slideshow"] = slideshow_sec
        slideshow_values = slideshow_sec.setdefault("values", {})
        if not isinstance(slideshow_values, dict):
            slideshow_values = {}
            slideshow_sec["values"] = slideshow_values

        interval_text = interval_var.get().strip().replace(",", ".")
        try:
            interval_val = float(interval_text)
        except ValueError:
            messagebox.showerror("Error", "Please enter a valid number for the interval.")
            return
        if interval_val <= 0:
            messagebox.showerror("Error", "The interval must be greater than 0.")
            return
        slideshow_values["interval_seconds"] = interval_val

        genesis_sec = updated.setdefault("genesis_image", {})
        if not isinstance(genesis_sec, dict):
            genesis_sec = {}
            updated["genesis_image"] = genesis_sec
        genesis_values = genesis_sec.setdefault("values", {})
        if not isinstance(genesis_values, dict):
            genesis_values = {}
            genesis_sec["values"] = genesis_values

        genesis_values["enabled"] = bool(genesis_enabled_var.get())

        url = genesis_url_var.get().strip()
        if genesis_values["enabled"]:
            genesis_values["url"] = url if url else DEFAULT_GENESIS_URL
        else:
            genesis_values["url"] = ""

        kw_text = genesis_kw_var.get().strip()
        if kw_text:
            if not kw_text.isdigit() or int(kw_text) < 1:
                messagebox.showerror("Error", "Please enter a valid positive number for analysis keywords.")
                return
            genesis_values["analysis_keywords"] = int(kw_text)

        genesis_values["use_style"] = bool(genesis_style_var.get())

        strength_text = genesis_strength_var.get().strip().replace(",", ".")
        try:
            strength_val = float(strength_text)
        except ValueError:
            messagebox.showerror("Error", "Please enter a valid number for strength.")
            return
        if strength_val < 0.0 or strength_val > 1.0:
            messagebox.showerror("Error", "Strength must be between 0.0 and 1.0.")
            return
        genesis_values["style_strength"] = strength_val

        iters_text = genesis_iters_var.get().strip()
        if not iters_text.isdigit() or int(iters_text) < 0:
            messagebox.showerror("Error", "Please enter a valid number for genesis iterations.")
            return
        genesis_values["style_iterations"] = int(iters_text)

        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(updated, f, ensure_ascii=False, indent=2)

        messagebox.showinfo("Saved", "Configuration saved.")
        root.destroy()

    load_into_fields(cfg)

    buttons = ttk.Frame(main)
    buttons.pack(fill=tk.X, pady=(10, 0))

    open_btn = ttk.Button(buttons, text="Open output folder", command=handle_open_outputs)
    open_btn.pack(side=tk.LEFT)

    restore_btn = ttk.Button(buttons, text="Restore defaults", command=handle_restore_defaults)
    restore_btn.pack(side=tk.LEFT, padx=(8, 0))

    cancel_btn = ttk.Button(buttons, text="Cancel", command=root.destroy)
    cancel_btn.pack(side=tk.RIGHT, padx=(8, 0))

    save_btn = ttk.Button(buttons, text="Save & Close", command=handle_save)
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
