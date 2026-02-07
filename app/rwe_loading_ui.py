import argparse
import json
import os
import time
import tkinter as tk
from tkinter import ttk


def safe_read_lines(path: str, offset: int) -> tuple[list[str], int]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            f.seek(offset)
            data = f.read()
            new_offset = f.tell()
        if not data:
            return [], new_offset
        return data.splitlines(), new_offset
    except Exception:
        return [], offset


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--progress", required=True)
    ap.add_argument("--token-file", default="")
    args = ap.parse_args()

    progress_path = os.path.abspath(args.progress)

    root = tk.Tk()
    root.title("RWE Setup")
    # Make the UI the primary visible window.
    try:
        root.state("zoomed")
    except Exception:
        root.geometry("760x520")
    root.minsize(760, 520)
    try:
        root.attributes("-topmost", True)
    except Exception:
        pass

    style = ttk.Style(root)
    if "vista" in style.theme_names():
        style.theme_use("vista")
    elif "clam" in style.theme_names():
        style.theme_use("clam")

    mainf = ttk.Frame(root, padding=14)
    mainf.pack(fill=tk.BOTH, expand=True)

    header = ttk.Label(mainf, text="RWE Setup", font=("Segoe UI", 16, "bold"))
    header.pack(anchor=tk.W)

    sub = ttk.Label(mainf, text="Initialisierung läuft…", foreground="#555555")
    sub.pack(anchor=tk.W, pady=(2, 10))

    bar = ttk.Progressbar(mainf, mode="determinate", maximum=100)
    bar.pack(fill=tk.X)

    msg_var = tk.StringVar(value="")
    msg = ttk.Label(mainf, textvariable=msg_var, wraplength=720, justify=tk.LEFT)
    msg.pack(anchor=tk.W, pady=(10, 6))

    token_path = os.path.abspath(args.token_file) if args.token_file else ""
    token_enabled = tk.BooleanVar(value=False)
    token_value = tk.StringVar(value="")

    token_box = ttk.Labelframe(mainf, text="Hugging Face token (optional)", padding=10)
    token_box.pack(fill=tk.X, pady=(0, 10))

    token_row = ttk.Frame(token_box)
    token_row.pack(fill=tk.X)

    cb = ttk.Checkbutton(token_row, text="Use token", variable=token_enabled)
    cb.pack(side=tk.LEFT)

    entry = ttk.Entry(token_row, textvariable=token_value, show="*")
    entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(10, 0))

    hint = ttk.Label(
        token_box,
        text="Only needed for gated models. Leave unchecked to run without a token.",
        foreground="#555555",
        wraplength=720,
        justify=tk.LEFT,
    )
    hint.pack(anchor=tk.W, pady=(6, 0))

    def write_token_file() -> None:
        if not token_path:
            return
        payload = {
            "use_token": bool(token_enabled.get()),
            "token": token_value.get().strip() if token_enabled.get() else "",
        }
        try:
            os.makedirs(os.path.dirname(token_path), exist_ok=True)
            with open(token_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    def update_entry_state(*_a) -> None:
        st = "normal" if token_enabled.get() else "disabled"
        try:
            entry.configure(state=st)
        except Exception:
            pass
        write_token_file()

    token_enabled.trace_add("write", update_entry_state)
    token_value.trace_add("write", lambda *_a: write_token_file())
    update_entry_state()

    log = tk.Text(mainf, height=16, wrap=tk.WORD)
    log.configure(state=tk.DISABLED)
    log.pack(fill=tk.BOTH, expand=True)

    footer = ttk.Label(mainf, text=progress_path, foreground="#777777")
    footer.pack(anchor=tk.W, pady=(8, 0))

    state = {
        "offset": 0,
        "last_percent": 0,
        "closing": False,
    }

    def on_close() -> None:
        write_token_file()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)

    def append_log(line: str) -> None:
        log.configure(state=tk.NORMAL)
        log.insert(tk.END, line + "\n")
        log.see(tk.END)
        log.configure(state=tk.DISABLED)

    def tick() -> None:
        if state["closing"]:
            try:
                root.destroy()
            except Exception:
                pass
            return

        lines, state["offset"] = safe_read_lines(progress_path, state["offset"])
        for ln in lines:
            ln = ln.strip()
            if not ln:
                continue
            try:
                obj = json.loads(ln)
            except Exception:
                append_log(ln)
                continue

            message = str(obj.get("message", "") or "").strip()
            phase = str(obj.get("phase", "") or "").strip()
            percent = obj.get("percent", None)

            if percent is not None:
                try:
                    p = int(float(percent))
                except Exception:
                    p = state["last_percent"]
                p = max(0, min(100, p))
                state["last_percent"] = p
                bar.configure(value=p)

            if message:
                msg_var.set(message)

            ts = obj.get("ts", None)
            ts_s = ""
            if ts is not None:
                try:
                    ts_s = time.strftime("%H:%M:%S", time.localtime(int(ts))) + " "
                except Exception:
                    ts_s = ""

            line_out = f"{ts_s}{phase}: {message}".strip(": ")
            if line_out:
                append_log(line_out)

            if bool(obj.get("close", False)) or bool(obj.get("done", False)):
                state["closing"] = True

        root.after(250, tick)

    root.after(250, tick)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
