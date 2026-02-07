import argparse
import json
import os
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional, Tuple

try:
    import tkinter as tk
    from tkinter import ttk
except Exception as exc:
    raise SystemExit(f"Tkinter is required: {exc}")

try:
    from PIL import Image, ImageTk
except Exception as exc:
    raise SystemExit(f"Pillow is required: {exc}")

def _safe_read_text(path: str, max_bytes: int = 2_000_000) -> str:
    try:
        if not path or not os.path.exists(path):
            return ""
        with open(path, "rb") as f:
            data = f.read(max_bytes)
        return data.decode("utf-8", errors="replace")
    except Exception:
        return ""

def _safe_read_json(path: str) -> Optional[Dict[str, Any]]:
    try:
        if not path or not os.path.exists(path):
            return None
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def _read_last_jsonl(path: str, max_lines: int = 2000) -> Optional[Dict[str, Any]]:
    try:
        if not path or not os.path.exists(path):
            return None
        with open(path, "rb") as f:
            data = f.read()
        lines = data.splitlines()
        if not lines:
            return None
        start = max(0, len(lines) - max_lines)
        for i in range(len(lines) - 1, start - 1, -1):
            line = lines[i].strip()
            if not line:
                continue
            try:
                return json.loads(line.decode("utf-8", errors="replace"))
            except Exception:
                continue
        return None
    except Exception:
        return None

def _find_latest_image(out_dir: str) -> Optional[str]:
    try:
        if not out_dir or not os.path.isdir(out_dir):
            return None
        best: Tuple[float, str] = (-1.0, "")
        for name in os.listdir(out_dir):
            low = name.lower()
            if not (low.endswith(".png") or low.endswith(".jpg") or low.endswith(".jpeg") or low.endswith(".webp")):
                continue
            if not (low.startswith("rwe_") or low.startswith("genesis_") or "iter" in low):
                continue
            p = os.path.join(out_dir, name)
            try:
                mt = os.path.getmtime(p)
            except Exception:
                continue
            if mt > best[0]:
                best = (mt, p)
        return best[1] if best[0] >= 0 else None
    except Exception:
        return None

@dataclass
class UiState:
    phase: str = ""
    message: str = ""
    percent: int = 0
    last_image_path: str = ""
    last_record: Dict[str, Any] = None
    done: bool = False

class RweRunUi(tk.Tk):
    def __init__(self, run_root: str, out_dir: str, progress_file: str, log_file: str, world_log_jsonl: str, done_flag: str):
        super().__init__()
        self.title("RealWorldEngine — Run")
        self.geometry("1200x780")
        self.minsize(1100, 700)

        self.run_root = run_root
        self.out_dir = out_dir
        self.progress_file = progress_file
        self.log_file = log_file
        self.world_log_jsonl = world_log_jsonl
        self.done_flag = done_flag

        self.state = UiState(last_record={})

        self._img_tk = None
        self._last_img_loaded = ""

        self._build_ui()
        self._stop = threading.Event()
        self._poll()

        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self) -> None:
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)

        top = ttk.Frame(self, padding=12)
        top.grid(row=0, column=0, sticky="nsew")
        top.columnconfigure(1, weight=1)

        self.lbl_phase = ttk.Label(top, text="Initializing…", font=("Segoe UI", 14, "bold"))
        self.lbl_phase.grid(row=0, column=0, sticky="w")

        self.lbl_msg = ttk.Label(top, text="", font=("Segoe UI", 10))
        self.lbl_msg.grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 0))

        self.pbar = ttk.Progressbar(top, orient="horizontal", length=400, mode="determinate")
        self.pbar.grid(row=0, column=1, sticky="e")
        self.pbar["maximum"] = 100

        body = ttk.Frame(self, padding=(12, 0, 12, 12))
        body.grid(row=1, column=0, sticky="nsew")
        body.columnconfigure(0, weight=3)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)

        left = ttk.Frame(body)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        left.rowconfigure(1, weight=1)
        left.columnconfigure(0, weight=1)

        title = ttk.Label(left, text="Latest image", font=("Segoe UI", 12, "bold"))
        title.grid(row=0, column=0, sticky="w", pady=(0, 6))

        self.canvas = tk.Canvas(left, highlightthickness=1)
        self.canvas.grid(row=1, column=0, sticky="nsew")

        right = ttk.Frame(body)
        right.grid(row=0, column=1, sticky="nsew")
        right.rowconfigure(3, weight=1)
        right.columnconfigure(0, weight=1)

        info_title = ttk.Label(right, text="Details", font=("Segoe UI", 12, "bold"))
        info_title.grid(row=0, column=0, sticky="w", pady=(0, 6))

        self.txt_details = tk.Text(right, height=10, wrap="word")
        self.txt_details.grid(row=1, column=0, sticky="nsew")
        self.txt_details.configure(state="disabled")

        log_title = ttk.Label(right, text="Live log", font=("Segoe UI", 12, "bold"))
        log_title.grid(row=2, column=0, sticky="w", pady=(10, 6))

        self.txt_log = tk.Text(right, wrap="none")
        self.txt_log.grid(row=3, column=0, sticky="nsew")
        self.txt_log.configure(state="disabled")

        bottom = ttk.Frame(self, padding=(12, 0, 12, 12))
        bottom.grid(row=2, column=0, sticky="nsew")
        bottom.columnconfigure(0, weight=1)

        self.lbl_path = ttk.Label(bottom, text="")
        self.lbl_path.grid(row=0, column=0, sticky="w")

    def _on_close(self) -> None:
        if self.state.done:
            self._stop.set()
            self.destroy()
            return
        self.lbl_msg.configure(text="Run is still active. This window will close automatically when the run is finished.")

    def _set_text(self, widget: tk.Text, text: str) -> None:
        widget.configure(state="normal")
        widget.delete("1.0", "end")
        widget.insert("1.0", text)
        widget.configure(state="disabled")

    def _update_details(self) -> None:
        rec = self.state.last_record or {}
        lines = []
        if rec.get("iteration") is not None:
            lines.append(f"Iteration: {rec.get('iteration')}")
        if rec.get("backend"):
            lines.append(f"Backend: {rec.get('backend')}")
        if rec.get("prompt"):
            p = str(rec.get("prompt"))
            lines.append("")
            lines.append("Prompt:")
            lines.append(p)
        if rec.get("negative"):
            lines.append("")
            lines.append("Negative:")
            lines.append(str(rec.get("negative")))
        for k in ("width", "height", "steps", "cfg", "seed", "img2img_strength"):
            if rec.get(k) is not None:
                lines.append(f"{k}: {rec.get(k)}")
        if rec.get("caption"):
            lines.append("")
            lines.append("Caption:")
            lines.append(str(rec.get("caption")))
        if rec.get("image_path"):
            lines.append("")
            lines.append(f"File: {rec.get('image_path')}")
        self._set_text(self.txt_details, "\n".join(lines).strip())

    def _load_image(self, path: str) -> None:
        try:
            if not path or not os.path.exists(path):
                return
            if path == self._last_img_loaded:
                return
            img = Image.open(path).convert("RGB")
            self.lbl_path.configure(text=os.path.relpath(path, self.run_root) if self.run_root else path)

            cw = max(1, self.canvas.winfo_width())
            ch = max(1, self.canvas.winfo_height())
            iw, ih = img.size
            scale = min(cw / iw, ch / ih)
            nw = max(1, int(iw * scale))
            nh = max(1, int(ih * scale))
            img2 = img.resize((nw, nh), Image.LANCZOS)

            self._img_tk = ImageTk.PhotoImage(img2)
            self.canvas.delete("all")
            self.canvas.create_image(cw // 2, ch // 2, image=self._img_tk, anchor="center")
            self._last_img_loaded = path
        except Exception:
            return

    def _read_progress(self) -> None:
        ev = _read_last_jsonl(self.progress_file)
        if not ev:
            return
        self.state.phase = str(ev.get("phase") or "")
        self.state.message = str(ev.get("message") or "")
        try:
            self.state.percent = int(ev.get("percent") or 0)
        except Exception:
            self.state.percent = 0

    def _read_last_record(self) -> None:
        rec = _read_last_jsonl(self.world_log_jsonl)
        if rec:
            self.state.last_record = rec

    def _read_log_tail(self, max_chars: int = 40_000) -> str:
        txt = _safe_read_text(self.log_file, max_bytes=2_000_000)
        if not txt:
            return ""
        if len(txt) > max_chars:
            return txt[-max_chars:]
        return txt

    def _poll(self) -> None:
        if self._stop.is_set():
            return

        self._read_progress()
        self._read_last_record()

        latest_img = _find_latest_image(self.out_dir)
        if latest_img:
            self.state.last_image_path = latest_img

        self.lbl_phase.configure(text=(self.state.phase or "Running").strip() or "Running")
        msg = self.state.message.strip()
        if self.state.done:
            msg = "Done. You can close this window."
        self.lbl_msg.configure(text=msg)
        self.pbar["value"] = max(0, min(100, self.state.percent))

        self._update_details()
        self._load_image(self.state.last_image_path)

        log_tail = self._read_log_tail()
        self._set_text(self.txt_log, log_tail)

        if self.done_flag and os.path.exists(self.done_flag):
            self.state.done = True

        self.after(700, self._poll)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-root", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--progress-file", required=True)
    ap.add_argument("--log-file", required=True)
    ap.add_argument("--world-log", required=True)
    ap.add_argument("--done-flag", required=True)
    args = ap.parse_args()

    ui = RweRunUi(
        run_root=args.run_root,
        out_dir=args.out_dir,
        progress_file=args.progress_file,
        log_file=args.log_file,
        world_log_jsonl=args.world_log,
        done_flag=args.done_flag,
    )
    ui.mainloop()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
