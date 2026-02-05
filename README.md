# RWE v0.4 (config-driven runner)

This repository contains a **Windows PowerShell 5.1** runner that bootstraps a Python 3.10 virtual environment, writes a self-contained `rwe_v04.py`, runs the generation loop, produces an **atlas PDF**, and opens it automatically.

The behavior of the series (seed motifs, stopwords, anti-hallway filters, style rotation, novelty injection, escape motifs) is configured via a single JSON file: **`rwe_config.json`**.

## What you get

- A repeatable **run folder** created next to the script:
  - `YYYY-MM-DD\run-YYYYMMDD-HHMMSS\...`
- Automatic **backup** of existing config/script files into `bak\YYYYMMDD-HHMMSS\...`
- **Config validation** with clear errors if required fields are missing
- **Resume mode**: continue an existing run using its existing `world_state.json` / `world_log.jsonl`
- Outputs:
  - PNG images for each iteration
  - embeddings `.npy`
  - `world_state.json`, `world_log.jsonl`
  - `clusters.json`
  - `outputs\atlas\rwe_atlas_v04.pdf` (opened automatically)

## Quick start (Windows)

1. Place these files in a folder:
   - `run_rwe.ps1`
   - `rwe_config.json`
2. Right-click **PowerShell** → “Run as Administrator” (or just run the script; it self-elevates).
3. Run:
   ```powershell
   .\run_rwe.ps1
   ```
4. Choose:
   - iterations (default from config)
   - Hugging Face token (optional; needed for gated models like SDXL base on Hugging Face)

When finished, the script opens the generated PDF.

## Config format

The config file stores both **values** and **explanations** in JSON.

Each main section is an object with:

- `description`: what it is
- `effects`: how it affects images/series
- `values`: the actual data used by the generator

### `initial_words.values`
Seed motifs for the first prompts. These influence early images and bias the long series because the motif bank grows from caption keywords.

### `banned_motifs.values`
Hard blacklist of keywords that should never enter the motif bank. This is the anti-hallway / anti-interior filter.

### `stopwords.values`
Filtered keywords during caption tokenization. Keeps learned motifs meaningful and removes grammar + generic image words.

### `style_pool.values`
Style clauses appended to prompts. The loop occasionally rotates styles to avoid getting stuck in a local aesthetic minimum.

### `novelty_motif_pool.values`
Injected motifs when novelty drops (images become too similar). Forces exploration.

### `escape_motifs.values`
Injected when the loop detects repeated interior cues (“interior trap”). Pushes composition outdoors and open.

### `runtime_defaults.values.iterations`
Default iteration count used as prompt default.

## Resume mode

On startup, you can choose resume mode:

- If you resume, you select a run folder (default is the latest run folder found).
- The script continues using that folder’s existing state/logs.
- The existing `rwe_config.json` inside the run folder is kept as the active config for that run.

## Notes

- Default backend preference is SDXL; if SDXL load fails, it falls back to SD 1.5.
- CPU-only is supported but will be slow.
- This is a research/prototyping runner. Expect to customize models, GPU settings, and prompt logic over time.

## Files

- `run_rwe.ps1` – complete runner/installer (PowerShell 5.1 compatible)
- `rwe_config.json` – config + explanations
- `LICENSE` – Unlicense (public domain dedication, where permitted)
