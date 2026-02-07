import argparse
import json
import os
import sys
from typing import List

from PIL import Image, ImageTk
import tkinter as tk


def load_interval(cfg_path: str, default: float = 5.0) -> float:
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f) or {}
    except Exception:
        return default

    slideshow = cfg.get("slideshow", {}) if isinstance(cfg, dict) else {}
    values = slideshow.get("values", {}) if isinstance(slideshow, dict) else {}
    interval = values.get("interval_seconds", default)
    try:
        interval_val = float(interval)
    except (TypeError, ValueError):
        return default
    return interval_val if interval_val > 0 else default


def collect_images(out_dir: str) -> List[str]:
    if not os.path.isdir(out_dir):
        return []
    images = [
        os.path.join(out_dir, name)
        for name in os.listdir(out_dir)
        if name.lower().endswith(".png")
    ]
    return sorted(images)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True)
    args = parser.parse_args()

    run_root = args.run_root
    out_dir = os.path.join(run_root, "outputs")
    cfg_path = os.path.join(run_root, "rwe_config.json")

    interval = load_interval(cfg_path)
    images = collect_images(out_dir)
    if not images:
        print("Keine PNG-Bilder im Ausgabeordner gefunden.")
        return 1

    root = tk.Tk()
    root.configure(background="black")
    root.attributes("-fullscreen", True)
    root.attributes("-topmost", True)
    root.focus_force()

    sw = root.winfo_screenwidth()
    sh = root.winfo_screenheight()

    label = tk.Label(root, bg="black")
    label.pack(expand=True, fill="both")

    state = {"idx": 0}

    def close(_event=None) -> None:
        root.destroy()

    def show_next() -> None:
        path = images[state["idx"]]
        img = Image.open(path).convert("RGB")
        img.thumbnail((sw, sh), Image.LANCZOS)
        photo = ImageTk.PhotoImage(img)
        label.configure(image=photo)
        label.image = photo
        state["idx"] = (state["idx"] + 1) % len(images)
        root.after(int(interval * 1000), show_next)

    root.bind("<Escape>", close)
    root.bind("<Return>", close)
    root.bind("<space>", close)
    root.bind("<Button-1>", close)

    show_next()
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
