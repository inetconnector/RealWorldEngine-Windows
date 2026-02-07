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

    slideshow_frame = ttk.Frame(notebook, padding=12)
    notebook.add(slideshow_frame, text="Slideshow")

    slideshow_hint = describe_section(cfg if cfg else default_cfg, "slideshow")
    slideshow_label = ttk.Label(slideshow_frame, text=slideshow_hint, wraplength=820, justify=tk.LEFT)
    slideshow_label.pack(anchor=tk.W, pady=(0, 8))

    slideshow_row = ttk.Frame(slideshow_frame)
    slideshow_row.pack(anchor=tk.W, pady=(4, 8))

    interval_label = ttk.Label(slideshow_row, text="Umschaltzeit (Sekunden):")
    interval_label.pack(side=tk.LEFT)

    interval_var = tk.StringVar()
    interval_entry = ttk.Entry(slideshow_row, textvariable=interval_var, width=10)
    interval_entry.pack(side=tk.LEFT, padx=(8, 0))

    genesis_frame = ttk.Frame(notebook, padding=12)
    notebook.add(genesis_frame, text="Genesis")

    genesis_hint = describe_section(cfg if cfg else default_cfg, "genesis_image")
    genesis_label = ttk.Label(genesis_frame, text=genesis_hint, wraplength=820, justify=tk.LEFT)
    genesis_label.pack(anchor=tk.W, pady=(0, 8))

    genesis_row = ttk.Frame(genesis_frame)
    genesis_row.pack(anchor=tk.W, pady=(4, 8), fill=tk.X)

    genesis_url_label = ttk.Label(genesis_row, text="Genesis-Bild URL:")
    genesis_url_label.pack(side=tk.LEFT)

    genesis_url_var = tk.StringVar()
    genesis_url_entry = ttk.Entry(genesis_row, textvariable=genesis_url_var, width=60)
    genesis_url_entry.pack(side=tk.LEFT, padx=(8, 0), fill=tk.X, expand=True)

    genesis_kw_row = ttk.Frame(genesis_frame)
    genesis_kw_row.pack(anchor=tk.W, pady=(4, 8))

    genesis_kw_label = ttk.Label(genesis_kw_row, text="Max. Analyse-Keywords:")
    genesis_kw_label.pack(side=tk.LEFT)

    genesis_kw_var = tk.StringVar()
    genesis_kw_entry = ttk.Entry(genesis_kw_row, textvariable=genesis_kw_var, width=10)
    genesis_kw_entry.pack(side=tk.LEFT, padx=(8, 0))

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

        slideshow_sec = source_cfg.get("slideshow", {})
        slideshow_values = slideshow_sec.get("values", {}) if isinstance(slideshow_sec, dict) else {}
        interval_val = slideshow_values.get("interval_seconds", 5)
        interval_var.set(str(interval_val))

        genesis_sec = source_cfg.get("genesis_image", {})
        genesis_values = genesis_sec.get("values", {}) if isinstance(genesis_sec, dict) else {}
        genesis_url = genesis_values.get("url", "")
        genesis_kw = genesis_values.get("analysis_keywords", 12)
        genesis_url_var.set("" if genesis_url is None else str(genesis_url))
        genesis_kw_var.set(str(genesis_kw))

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
            messagebox.showerror("Fehler", "Bitte eine gültige Zahl für die Umschaltzeit eingeben.")
            return
        if interval_val <= 0:
            messagebox.showerror("Fehler", "Die Umschaltzeit muss größer als 0 sein.")
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

        genesis_values["url"] = genesis_url_var.get().strip()

        genesis_kw_text = genesis_kw_var.get().strip()
        if genesis_kw_text:
            if not genesis_kw_text.isdigit() or int(genesis_kw_text) < 1:
                messagebox.showerror("Fehler", "Bitte eine gültige positive Zahl für Analyse-Keywords eingeben.")
                return
            genesis_values["analysis_keywords"] = int(genesis_kw_text)

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