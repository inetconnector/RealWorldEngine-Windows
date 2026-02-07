# RealWorldEngine-Windows - RWE v0.4

# ➜ Deutsche Version: [README.de.md](README.de.md)

[English](#english) | [Licenses](#licenses)

## English

RealWorldEngine is a **Windows PowerShell 5.1** runner that bootstraps a Python 3.10 virtual environment, auto-detects the best PyTorch backend (CUDA / DirectML / CPU), writes a self-contained `rwe_v04.py`, runs the generation loop, produces an **atlas PDF**, and opens it automatically.

The behavior of the series (seed motifs, stopwords, anti-hallway filters, style rotation, novelty injection, escape motifs) is configured via a single JSON file: **`rwe_config.json`**.

### What this system does – explained clearly

The system does not create isolated AI images, but a connected image development over time.

Think of it like a series that evolves image by image — each new image is influenced by the previous sequence.

#### The core difference vs normal AI image generation

**Normally:**

- Prompt → image
- Next prompt → completely new image
- No memory, no development

**Here:**

- Image 1 is created
- Image 2 reacts to image 1
- Image 3 reacts to image 1 and 2
- and so on

The system “knows” what it has already done and aligns itself accordingly.

#### How the system “knows” what it has already done

After each image is generated, the image is analyzed:

- What is visible? (objects, spaces, moods, typical elements)
- How similar is it to previous images? (not visually, but semantically)
- Is the image familiar or new? (does it fit the pattern or break it?)

This information is stored and influences the next images.

#### What happens with this information

The system self-regulates:

- Things that appear too often are weakened
- Things that are rare or new can be strengthened
- If it gets stuck, a new impulse is introduced on purpose

This prevents an endless loop of similar images.

#### What an “epoch” means in this system

An epoch is a phase in which the images:

- are thematically similar
- share similar motifs and structures
- have a recognizable visual language

An epoch ends when:

- the visual language changes clearly, or
- something new dominates over time

Epochs emerge automatically, not because someone defines them.

#### Why multiple epochs matter

Multiple epochs mean:

- different image phases
- thematic or formal turning points
- recognizable development instead of variation

In the atlas you can see:

- early phases
- transitions
- later states

This makes the series legible and curatable.

#### What the atlas actually is

The atlas is not a gallery, but a documentation:

- chronological sequence
- groupings of similar images
- phases (epochs)
- typical motifs per phase

It shows not just results, but the process.

#### Artistically relevant because

- The work emerges over time
- Meaning comes from sequence
- Breaks are visible, not smoothed over
- Authorship lies in the rules, not in the single image

You don’t work with “prompts”, but with conditions of development.

### What you get

- A repeatable **run folder** created next to the script:
  - `YYYY-MM-DD\run-YYYYMMDD-HHMMSS\...`
- **Config validation** with clear errors if required fields are missing
- **Resume mode**: continue an existing run using its existing `world_state.json` / `world_log.jsonl`
- **Backend auto-detection** (CUDA → DirectML → CPU) with verification + fallback
- Outputs:
  - PNG images for each iteration
  - embeddings `.npy`
  - `world_state.json`, `world_log.jsonl`
  - `clusters.json`, `epochs.json`
  - `outputs\atlas\rwe_atlas_v04.pdf` (opened automatically)
  - atlas pages with **epoch summaries**, motif indices, and contact sheets

### Quick start (Windows)

1. Place these files in a folder:
   - `rwe_runner.ps1`
   - `rwe_config.json`
2. Right-click **PowerShell** → “Run as Administrator” (or just run the script; it self-elevates).
3. Run:
   ```powershell
   .\rwe_runner.ps1
   ```
4. Choose:
   - iterations (default from config)
   - Hugging Face token (optional; needed for gated models like SDXL base on Hugging Face)

When finished, the script opens the generated PDF.

### Config format

The config file stores both **values** and **explanations** in JSON.

Each main section is an object with:

- `description`: what it is
- `effects`: how it affects images/series
- `values`: the actual data used by the generator

#### `initial_words.values`
Seed motifs for the first prompts. These influence early images and bias the long series because the motif bank grows from caption keywords.

#### `banned_motifs.values`
Hard blacklist of keywords that should never enter the motif bank. This is the anti-hallway / anti-interior filter.

#### `stopwords.values`
Filtered keywords during caption tokenization. Keeps learned motifs meaningful and removes grammar + generic image words.

#### `style_pool.values`
Style clauses appended to prompts. The loop occasionally rotates styles to avoid getting stuck in a local aesthetic minimum.

#### `novelty_motif_pool.values`
Injected motifs when novelty drops (images become too similar). Forces exploration.

#### `escape_motifs.values`
Injected when the loop detects repeated interior cues (“interior trap”). Pushes composition outdoors and open.

#### `runtime_defaults.values.iterations`
Default iteration count used as prompt default.

### Resume mode

On startup, you can choose resume mode:

- If you resume, you select a run folder (default is the latest run folder found).
- The script continues using that folder’s existing state/logs.
- The existing `rwe_config.json` inside the run folder is kept as the active config for that run.

### Backend selection

On startup, the runner detects the GPU(s), verifies CUDA availability, and selects the best backend:

1. **CUDA** if an NVIDIA GPU and `nvidia-smi` are available (then verified in Python).
2. **DirectML** for AMD/Intel (or NVIDIA without CUDA), then verified in Python.
3. **CPU** fallback if the GPU backends fail verification.

The verified backend is exposed to Python via `RWE_BACKEND` and used by the embedded runner.

### Notes

- Default backend preference is SDXL; if SDXL load fails, it falls back to SD 1.5.
- CPU-only is supported but will be slow.
- This is a research/prototyping runner. Expect to customize models, GPU settings, and prompt logic over time.

### Files

- `rwe_runner.ps1` – complete runner/installer (PowerShell 5.1 compatible)
- `rwe_config.json` – config + explanations
- `LICENSE` – Unlicense (public domain dedication, where permitted)
- `LICENSE-ARTWORK-EN.md` – license for artwork (English)
- `LICENSE-ARTWORK-DE.md` – license for artwork (German)

### Licenses

- [LICENSE](LICENSE)
- [LICENSE-ARTWORK-EN.md](LICENSE-ARTWORK-EN.md)
- [LICENSE-ARTWORK-DE.md](LICENSE-ARTWORK-DE.md)
