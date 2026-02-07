import argparse
import json
import os
import sys
import time
from typing import List, Tuple

from huggingface_hub import snapshot_download
from huggingface_hub.utils import LocalEntryNotFoundError


def write_progress(path: str, percent: float, message: str, phase: str = "") -> None:
    payload = {
        "ts": int(time.time()),
        "percent": float(max(0.0, min(1.0, percent))),
        "message": str(message),
        "phase": str(phase),
    }
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    # Keep JSON (single object) for simplicity; the UI polls and reads the latest state.
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


def has_incomplete_downloads(hf_home: str) -> bool:
    if not hf_home or not os.path.isdir(hf_home):
        return False
    for root, _dirs, files in os.walk(hf_home):
        for name in files:
            ln = name.lower()
            if ln.endswith(".incomplete") or ln.endswith(".lock"):
                return True
    return False


def try_local_snapshot(repo_id: str) -> bool:
    try:
        snapshot_download(repo_id=repo_id, local_files_only=True)
        return True
    except LocalEntryNotFoundError:
        return False
    except Exception:
        return False


def prefetch_repo(repo_id: str) -> None:
    # resume_download avoids re-downloading completed files
    snapshot_download(repo_id=repo_id, resume_download=True, local_files_only=False)


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--progress", default="", help="Path to a progress JSON file.")
    args, _ = ap.parse_known_args(argv)

    progress = (args.progress or "").strip()
    if not progress:
        progress = os.environ.get("RWE_BOOTSTRAP_PROGRESS", "").strip()
    if not progress:
        progress = os.path.join(os.getcwd(), "bootstrap_progress.json")

    repos: List[Tuple[str, str]] = [
        ("SDXL Base", os.environ.get("RWE_SDXL_MODEL", "stabilityai/stable-diffusion-xl-base-1.0")),
        ("SD1.5", os.environ.get("RWE_SD15_MODEL", "runwayml/stable-diffusion-v1-5")),
        ("BLIP", os.environ.get("RWE_BLIP_MODEL", "Salesforce/blip-image-captioning-base")),
        ("CLIP", os.environ.get("RWE_CLIP_MODEL", "openai/clip-vit-base-patch32")),
    ]

    hf_home = os.environ.get("HF_HOME", "").strip()
    incomplete = has_incomplete_downloads(hf_home)

    write_progress(progress, 0.05, "Checking model cache...", phase="prefetch_check")
    total = max(1, len(repos))

    for i, (name, repo_id) in enumerate(repos, start=1):
        base = 0.10 + (i - 1) * (0.88 / total)
        msg = f"Checking {name}: {repo_id}"
        print(msg, flush=True)
        write_progress(progress, base, msg, phase="prefetch_check")

        if not incomplete and try_local_snapshot(repo_id):
            ok_msg = f"Cache OK: {name}"
            print(ok_msg, flush=True)
            write_progress(progress, min(0.99, base + (0.88 / total) * 0.4), ok_msg, phase="prefetch_ok")
            continue

        dl_msg = f"Downloading {name}: {repo_id}"
        print(dl_msg, flush=True)
        write_progress(progress, min(0.99, base + (0.88 / total) * 0.05), dl_msg, phase="prefetch_dl")
        try:
            prefetch_repo(repo_id)
            ok_msg = f"Prefetch OK: {name}"
            print(ok_msg, flush=True)
            write_progress(progress, min(0.99, base + (0.88 / total) * 0.9), ok_msg, phase="prefetch_ok")
        except Exception as exc:
            warn_msg = f"Prefetch failed for {name}: {exc}"
            print(warn_msg, flush=True)
            write_progress(progress, min(0.99, base + (0.88 / total) * 0.2), warn_msg, phase="prefetch_warn")

    write_progress(progress, 1.0, "Prefetch complete", phase="prefetch_done")
    print("Prefetch complete", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
