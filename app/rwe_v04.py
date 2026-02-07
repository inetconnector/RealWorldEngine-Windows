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
import urllib.request
from dataclasses import dataclass, asdict
from typing import List, Dict, Any, Optional, Tuple

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont

from huggingface_hub import login
from diffusers import (
    StableDiffusionXLPipeline,
    StableDiffusionPipeline,
)
try:
    from diffusers import StableDiffusionXLImg2ImgPipeline
except Exception:
    StableDiffusionXLImg2ImgPipeline = None
try:
    from diffusers import StableDiffusionImg2ImgPipeline
except Exception:
    StableDiffusionImg2ImgPipeline = None

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

def _read_runtime_int(cfg: Dict[str, Any], key: str, default: int) -> int:
    try:
        sec = cfg.get("runtime_defaults", {})
        values = sec.get("values", {}) if isinstance(sec, dict) else {}
        raw = values.get(key, default)
        val = int(raw)
        return val if val > 0 else default
    except Exception:
        return default

def _has_runtime_key(cfg: Dict[str, Any], key: str) -> bool:
    try:
        sec = cfg.get("runtime_defaults", {})
        values = sec.get("values", {}) if isinstance(sec, dict) else {}
        return key in values
    except Exception:
        return False

CFG_RUNTIME_SIZE_EXPLICIT = _has_runtime_key(CFG, "width") or _has_runtime_key(CFG, "height")
DEFAULT_WIDTH = _read_runtime_int(CFG, "width", 1024)
DEFAULT_HEIGHT = _read_runtime_int(CFG, "height", 1024)


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

def _get_genesis_config(cfg: Dict[str, Any]) -> Tuple[str, int, bool, float, int]:
    sec = cfg.get("genesis_image", {})
    if not isinstance(sec, dict):
        return "", 12, False, 0.55, 3

    values = sec.get("values", {}) if isinstance(sec.get("values", {}), dict) else {}
    enabled_raw = values.get("enabled", False)
    enabled = bool(enabled_raw) if isinstance(enabled_raw, bool) else str(enabled_raw).strip().lower() in {"1","true","yes","y","on"}

    url = str(values.get("url", "") or "").strip() if enabled else ""

    kw_raw = values.get("analysis_keywords", 12)
    try:
        kw = int(kw_raw)
    except (TypeError, ValueError):
        kw = 12
    if kw < 1:
        kw = 12

    use_style_raw = values.get("use_style", False)
    use_style = bool(use_style_raw) if isinstance(use_style_raw, bool) else str(use_style_raw).strip().lower() in {"1","true","yes","y","on"}

    strength_raw = values.get("style_strength", 0.55)
    try:
        strength = float(str(strength_raw).replace(",", "."))
    except (TypeError, ValueError):
        strength = 0.55
    if strength <= 0.0 or strength > 1.0:
        strength = 0.55

    iters_raw = values.get("style_iterations", 3)
    try:
        iters = int(iters_raw)
    except (TypeError, ValueError):
        iters = 3
    iters = max(1, min(12, iters))

    return url, kw, use_style, strength, iters

GENESIS_URL, GENESIS_KEYWORDS, GENESIS_USE_STYLE, GENESIS_STYLE_STRENGTH, GENESIS_STYLE_ITERS = _get_genesis_config(CFG)

def ensure_dir(path: str) -> None:
    os.makedirs(path, exist_ok=True)

def now_stamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")

IMAGE_VIEWER_PROC: Optional[subprocess.Popen] = None

def env_flag(name: str, default: bool = False) -> bool:
    v = os.environ.get(name, "").strip().lower()
    if not v:
        return default
    return v in {"1", "true", "yes", "y", "on"}

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
root.bind("<Escape>", close)

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
    for t in ("room", "hallway", "corridor", "wall", "ceiling", "floor", "interior", "inside", "door", "window"):
        if t in c:
            hits += 1
    return hits >= 2

@dataclass
class WorldState:
    iteration: int = 0
    motif_bank: List[str] = None
    prompt_style: str = STYLE_POOL[0]
    negative: str = "lowres, blurry, artifacts, text, watermark, logo, signature, deformed"
    width: int = DEFAULT_WIDTH
    height: int = DEFAULT_HEIGHT
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
    used_img2img: bool = False
    img2img_strength: float = 0.0

class RWEv04:
    def __init__(self, out_dir: str, genesis_url: str = "", genesis_keywords: int = 12,
                 genesis_use_style: bool = False, genesis_style_strength: float = 0.55, genesis_style_iters: int = 3):
        self.out_dir = out_dir
        self.state_path = os.path.join(out_dir, "world_state.json")
        self.log_path = os.path.join(out_dir, "world_log.jsonl")
        self.emb_dir = os.path.join(out_dir, "embeddings")
        ensure_dir(out_dir)
        ensure_dir(self.emb_dir)

        self.genesis_url = genesis_url.strip()
        self.genesis_keywords = max(1, int(genesis_keywords))

        self.genesis_use_style = bool(genesis_use_style)
        self.genesis_style_strength = float(max(0.0, min(1.0, genesis_style_strength)))
        self.genesis_style_iters = int(max(1, min(9999, genesis_style_iters)))
        self.genesis_img: Optional[Image.Image] = None

        self.device_backend, self.device = resolve_backend()
        self.dtype = torch.float16 if self.device_backend == "cuda" else torch.float32

        self.world = self._load_state()

        self.pipe_txt, self.pipe_img, self.backend = self._load_generation_backend()
        self.blip_processor, self.blip = self._load_blip()
        self.clip_processor, self.clip = self._load_clip()
        self.prev_embed: Optional[np.ndarray] = None

        self.show_images = env_flag("RWE_SHOW_IMAGES", default=False)

        self._bootstrap_genesis()

    def _load_state(self) -> WorldState:
        if os.path.exists(self.state_path):
            with open(self.state_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for k, default in (("interior_strikes", 0), ("style_index", 0), ("backend", "auto")):
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
            return self._load_sd15(sd15_id), self._load_sd15_img2img(sd15_id), "sd15"
        if self.world.backend == "sdxl":
            return self._load_sdxl(sdxl_id), self._load_sdxl_img2img(sdxl_id), "sdxl"

        try:
            p = self._load_sdxl(sdxl_id)
            pi = self._load_sdxl_img2img(sdxl_id)
            self.world.backend = "sdxl"
            return p, pi, "sdxl"
        except Exception as e:
            print("SDXL load failed. Falling back to SD 1.5.")
            print(str(e))
            p = self._load_sd15(sd15_id)
            pi = self._load_sd15_img2img(sd15_id)
            self.world.backend = "sd15"
            if not CFG_RUNTIME_SIZE_EXPLICIT:
                self.world.width = 512  # fallback size for very low VRAM
                self.world.height = 512  # fallback size for very low VRAM
            self.world.steps = min(28, max(18, int(self.world.steps)))
            return p, pi, "sd15"

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

    def _load_sdxl_img2img(self, model_id: str):
        if StableDiffusionXLImg2ImgPipeline is None:
            return None
        try:
            pipe = StableDiffusionXLImg2ImgPipeline.from_pretrained(
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
        except Exception:
            return None

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

    def _load_sd15_img2img(self, model_id: str):
        if StableDiffusionImg2ImgPipeline is None:
            return None
        try:
            pipe = StableDiffusionImg2ImgPipeline.from_pretrained(
                model_id,
                torch_dtype=self.dtype,
                safety_checker=None,
            )
            pipe = pipe.to(self.device)
            if self.device == "cuda":
                pipe.enable_attention_slicing()
            return pipe
        except Exception:
            return None

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
    def _generate_image(self, prompt: str, seed: int, init_img: Optional[Image.Image] = None,
                        strength: float = 0.55) -> Tuple[Image.Image, bool, float]:
        gen = torch.Generator(device=self.device).manual_seed(seed) if self.device_backend == "cuda" else None

        if init_img is not None and self.pipe_img is not None:
            try:
                if self.backend == "sdxl":
                    r = self.pipe_img(
                        prompt=prompt,
                        negative_prompt=self.world.negative,
                        image=init_img,
                        strength=float(strength),
                        num_inference_steps=int(self.world.steps),
                        guidance_scale=float(self.world.cfg),
                        generator=gen,
                    )
                    return r.images[0], True, float(strength)
                r = self.pipe_img(
                    prompt=prompt,
                    negative_prompt=self.world.negative,
                    image=init_img,
                    strength=float(strength),
                    num_inference_steps=int(self.world.steps),
                    guidance_scale=float(self.world.cfg),
                    generator=gen,
                )
                return r.images[0], True, float(strength)
            except Exception:
                pass

        if self.backend == "sdxl":
            r = self.pipe_txt(
                prompt=prompt,
                negative_prompt=self.world.negative,
                num_inference_steps=int(self.world.steps),
                guidance_scale=float(self.world.cfg),
                width=int(self.world.width),
                height=int(self.world.height),
                generator=gen,
            )
            return r.images[0], False, 0.0

        r = self.pipe_txt(
            prompt=prompt,
            negative_prompt=self.world.negative,
            num_inference_steps=int(self.world.steps),
            guidance_scale=float(self.world.cfg),
            generator=gen,
        )
        return r.images[0], False, 0.0

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

    def _update_motifs_from_keywords(self, keywords: List[str]) -> List[str]:
        added: List[str] = []
        for k in keywords:
            if k in BANNED_MOTIFS:
                continue
            if k not in self.world.motif_bank:
                self.world.motif_bank.append(k)
                added.append(k)
        self.world.motif_bank = self.world.motif_bank[-64:]
        return added
    def _download_genesis(self, url: str) -> Optional[str]:
        if not url:
            return None

        def _guess_ext(u: str, content_type: str) -> str:
            ct = (content_type or "").lower()
            if ct.startswith("image/"):
                ext = ct.split("/", 1)[1].split(";", 1)[0].strip()
                if ext == "jpeg":
                    return ".jpg"
                if ext in ("png", "jpg", "gif", "webp", "bmp", "tiff"):
                    return "." + ext
            m = re.search(r"\.(png|jpg|jpeg|gif|webp|bmp|tiff)(?:\?|#|$)", u.lower())
            if m:
                ext = m.group(1)
                return ".jpg" if ext == "jpeg" else "." + ext
            return ".jpg"

        def _extract_image_url_from_html(html: str) -> str:
            m = re.search(r'property=["\']og:image["\']\s+content=["\']([^"\']+)', html, re.IGNORECASE)
            if m:
                return m.group(1).strip()

            m = re.search(r'https?://upload\.wikimedia\.org/[^"\'\s>]+', html, re.IGNORECASE)
            if m:
                return m.group(0).strip()

            m = re.search(r'srcset=["\']([^"\']+)', html, re.IGNORECASE)
            if m:
                parts = [p.strip().split(" ")[0] for p in m.group(1).split(",") if p.strip()]
                if parts:
                    return parts[-1]
            return ""

        def _fetch(u: str, depth: int = 0) -> Optional[str]:
            if depth > 2:
                return None
            try:
                req = urllib.request.Request(u, headers={"User-Agent": "RWE/0.4"})
                with urllib.request.urlopen(req, timeout=30) as resp:
                    ct = resp.headers.get("Content-Type", "") or ""
                    data = resp.read()

                ct_low = ct.lower()
                if ct_low.startswith("text/html") or ct_low.startswith("application/xhtml"):
                    try:
                        html = data.decode("utf-8", errors="ignore")
                    except Exception:
                        html = str(data)
                    img_url = _extract_image_url_from_html(html)
                    if img_url:
                        return _fetch(img_url, depth + 1)
                    raise RuntimeError("Genesis URL did not resolve to an image.")

                ext = _guess_ext(u, ct)
                out_path = os.path.join(self.out_dir, "genesis_source" + ext)
                with open(out_path, "wb") as f:
                    f.write(data)
                return out_path
            except Exception as exc:
                print(f"Genesis download failed: {exc}")
                return None

        return _fetch(url, 0)


    def _dominant_colors(self, img: Image.Image, k: int = 5) -> List[Dict[str, Any]]:
        arr = np.array(img.convert("RGB").resize((128, 128)))
        flat = arr.reshape(-1, 3).astype(np.float32)
        if flat.shape[0] > 8000:
            idx = np.random.choice(flat.shape[0], size=8000, replace=False)
            flat = flat[idx]
        k = max(1, min(k, flat.shape[0]))
        if k == 1:
            mean = flat.mean(axis=0).astype(int)
            hexv = "#{:02x}{:02x}{:02x}".format(int(mean[0]), int(mean[1]), int(mean[2]))
            return [{"rgb": [int(mean[0]), int(mean[1]), int(mean[2])], "hex": hexv, "count": int(flat.shape[0])}]
        km = KMeans(n_clusters=k, n_init=5, random_state=42)
        labels = km.fit_predict(flat)
        counts = np.bincount(labels)
        centers = km.cluster_centers_.astype(int)
        order = np.argsort(-counts)
        palette: List[Dict[str, Any]] = []
        for i in order:
            rgb = centers[i]
            hexv = "#{:02x}{:02x}{:02x}".format(int(rgb[0]), int(rgb[1]), int(rgb[2]))
            palette.append({"rgb": [int(rgb[0]), int(rgb[1]), int(rgb[2])], "hex": hexv, "count": int(counts[i])})
        return palette

    def _analyze_genesis(self, img: Image.Image, caption: str, keywords: List[str], img_path: str) -> Dict[str, Any]:
        arr = np.array(img.convert("RGB"))
        h, w = arr.shape[:2]
        luma = 0.2126 * arr[..., 0] + 0.7152 * arr[..., 1] + 0.0722 * arr[..., 2]
        brightness = float(luma.mean() / 255.0)
        contrast = float(luma.std() / 255.0)
        mean_color = [float(x) for x in arr.mean(axis=(0, 1))]
        palette = self._dominant_colors(img, k=5)
        return {
            "source_url": self.genesis_url,
            "local_path": img_path,
            "size": {"width": int(w), "height": int(h)},
            "aspect_ratio": float(w / max(1, h)),
            "caption": caption,
            "keywords": keywords,
            "mean_color": mean_color,
            "brightness": brightness,
            "contrast": contrast,
            "dominant_colors": palette,
            "use_as_style": bool(self.genesis_use_style),
            "style_strength": float(self.genesis_style_strength),
            "style_iterations": int(self.genesis_style_iters),
        }

    def _bootstrap_genesis(self) -> None:
        if not self.genesis_url:
            return
        if self.world.iteration > 0:
            return
        if os.path.exists(self.log_path) and os.path.getsize(self.log_path) > 0:
            return

        print(f"Genesis: loading {self.genesis_url}")
        img_path = self._download_genesis(self.genesis_url)
        if not img_path:
            print("Genesis: download failed, continuing without genesis.")
            return
        try:
            img = Image.open(img_path).convert("RGB")
        except Exception as exc:
            print(f"Genesis: failed to open image: {exc}")
            return

        self.genesis_img = img

        cap = self._caption_image(img)
        emb = self._embed_image(img)
        keywords = tokenize_keywords(cap, max_words=self.genesis_keywords)
        motifs_added = self._update_motifs_from_keywords(keywords)

        emb_path = os.path.join(self.emb_dir, "genesis.npy")
        np.save(emb_path, emb.astype(np.float32))

        analysis = self._analyze_genesis(img, cap, keywords, img_path)
        analysis_path = os.path.join(self.out_dir, "genesis_analysis.json")
        with open(analysis_path, "w", encoding="utf-8") as f:
            json.dump(analysis, f, ensure_ascii=False, indent=2)

        rec = IterationRecord(
            iteration=0,
            ts=int(time.time()),
            prompt=f"GENESIS_URL: {self.genesis_url}",
            negative=self.world.negative,
            width=int(img.width),
            height=int(img.height),
            steps=0,
            cfg=0.0,
            seed=-1,
            image_path=img_path,
            caption=cap,
            motifs_added=motifs_added,
            similarity_prev=None,
            novelty_prev=None,
            rule_change="genesis_bootstrap",
            embedding_path=emb_path,
            interior_strikes=int(self.world.interior_strikes),
            backend="genesis",
            used_img2img=False,
            img2img_strength=0.0,
        )
        self._append_log(rec)
        self._save_state()
        self.prev_embed = emb

        print("Genesis analysis:")
        print(f"    caption: {cap}")
        print(f"    keywords: {', '.join(keywords) if keywords else '(none)'}")
        print(f"    brightness: {analysis['brightness']:.3f} | contrast: {analysis['contrast']:.3f}")
        print(f"    dominant_colors: {[c['hex'] for c in analysis['dominant_colors']]}")
        print(f"    analysis saved: {analysis_path}")

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
            self.world.steps = int(np.clip(self.world.steps + random.choice([1, 2, 3]), 18, 36))
        elif novelty > (target + 0.12):
            rule_change = "increase_coherence+" + self._maybe_rotate_style(force=False)
            self.world.cfg = float(np.clip(self.world.cfg + random.uniform(-0.9, -0.2), 4.8, 7.0))
            self.world.steps = int(np.clip(self.world.steps + random.choice([-2, -1, 0]), 18, 32))
        else:
            r = random.random()
            if r < 0.40:
                self.world.cfg = float(np.clip(self.world.cfg + random.uniform(-0.35, 0.35), 4.8, 9.0))
                rule_change = "micro(cfg)"
            elif r < 0.75:
                self.world.steps = int(np.clip(self.world.steps + random.choice([-1, 0, 1]), 18, 36))
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

        init_img = None
        use_img2img = False
        strength = 0.0
        if self.genesis_use_style and self.genesis_img is not None and it <= self.genesis_style_iters:
            init_img = self.genesis_img
            use_img2img = True
            strength = float(self.genesis_style_strength)

        img, used_img2img, used_strength = self._generate_image(prompt, seed, init_img=init_img, strength=strength)
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

        if self.show_images:
            show_image_fullscreen(img_path)

        rec = IterationRecord(
            iteration=it,
            ts=int(time.time()),
            prompt=prompt,
            negative=self.world.negative,
            width=int(self.world.width),
            height=int(self.world.height),
            steps=int(self.world.steps),
            cfg=float(self.world.cfg),
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
            used_img2img=bool(used_img2img),
            img2img_strength=float(used_strength),
        )

        self._append_log(rec)
        self._save_state()
        self.prev_embed = emb

        print(f"[{it}] {os.path.basename(img_path)} ({self.backend})")
        print(f"    caption: {cap}")
        if novelty_prev is not None:
            print(f"    similarity_prev: {similarity_prev:.3f} | novelty_prev: {novelty_prev:.3f} | target: {self.world.novelty_target:.2f}")
        print(f"    rule_change: {rule_change} | motifs_added: {len(rec.motifs_added)} | interior_strikes: {rec.interior_strikes} | img2img: {rec.used_img2img}")

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
    c.drawString(margin, ph - 30 * mm, "Reflective World Engine (RWE) - Atlas v0.4")
    c.setFont("Helvetica", 12)
    c.drawString(margin, ph - 40 * mm, f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    c.drawString(margin, ph - 48 * mm, f"Output dir: {out_dir}")
    cfg_path = os.environ.get("RWE_CONFIG", "").strip()
    if cfg_path:
        c.drawString(margin, ph - 56 * mm, f"Config: {cfg_path}")
    c.drawString(margin, ph - 64 * mm, f"Clustering: {clusters.get('method','')}, k={clusters.get('k','')}")
    c.drawString(margin, ph - 72 * mm, f"Epochs: {len(epochs)}")
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
            if y < 30 * mm:
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
            if y < 30 * mm:
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

    print("")
    print("RWE v0.4 loop starting (GUI-driven)")
    backend_pref = os.environ.get("RWE_BACKEND", "auto").strip().lower() or "auto"
    print(f"Backend preference: {backend_pref}")
    print(f"Output: {out_dir}")
    cfg_path = os.environ.get("RWE_CONFIG", "").strip()
    if cfg_path:
        print(f"Config: {cfg_path}")
    print("")

    rwe = RWEv04(
        out_dir=out_dir,
        genesis_url=GENESIS_URL,
        genesis_keywords=GENESIS_KEYWORDS,
        genesis_use_style=GENESIS_USE_STYLE,
        genesis_style_strength=GENESIS_STYLE_STRENGTH,
        genesis_style_iters=GENESIS_STYLE_ITERS,
    )
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