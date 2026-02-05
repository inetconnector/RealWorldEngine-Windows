# RealWorldEngine-Windows - RWE v0.4  
[Deutsch](#deutsch) | [English](#english) | [Lizenzen](#lizenzen)

## English

RealWorldEngine is a **Windows PowerShell 5.1** runner that bootstraps a Python 3.10 virtual environment, auto-detects the best PyTorch backend (CUDA / DirectML / CPU), writes a self-contained `rwe_v04.py`, runs the generation loop, produces an **atlas PDF**, and opens it automatically.

The behavior of the series (seed motifs, stopwords, anti-hallway filters, style rotation, novelty injection, escape motifs) is configured via a single JSON file: **`rwe_config.json`**.

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

---

## Deutsch

RealWorldEngine ist ein **Windows-PowerShell-Runner (PowerShell 5.1)**, der eine Python-3.10-Umgebung aufsetzt, das beste PyTorch-Backend (CUDA / DirectML / CPU) automatisch auswählt, ein eigenständiges `rwe_v04.py` schreibt, den Generations-Loop startet, einen **Atlas-PDF** erzeugt und ihn automatisch öffnet.

Die gesamte Steuerung der Serie (Startmotive, Stopwords, Anti-Hallway-Filter, Stilrotation, Novelty-Injektion, Escape-Motive) passiert über eine einzige JSON-Datei: **`rwe_config.json`**.

### Was dieses System macht – verständlich erklärt

Das System erzeugt keine einzelnen KI-Bilder, sondern eine zusammenhängende Bildentwicklung über Zeit.

Man kann es sich vorstellen wie eine Serie, die sich Bild für Bild weiterentwickelt – wobei jedes neue Bild vom bisherigen Verlauf beeinflusst wird.

#### Der zentrale Unterschied zu normaler KI-Bildgenerierung

**Normalerweise:**

- Prompt → Bild
- Nächster Prompt → völlig neues Bild
- Keine Erinnerung, keine Entwicklung

**Hier:**

- Bild 1 entsteht
- Bild 2 reagiert auf Bild 1
- Bild 3 reagiert auf Bild 1 und 2
- usw.

Das System „weiß“, was es schon gemacht hat, und richtet sich danach.

#### Wie das System „weiß“, was es schon gemacht hat

Nach jedem erzeugten Bild wird das Bild ausgewertet:

- Was ist darauf zu sehen? (Objekte, Räume, Stimmungen, typische Elemente)
- Wie ähnlich ist es zu den vorherigen Bildern? (nicht optisch, sondern inhaltlich / semantisch)
- Ist das Bild eher vertraut oder neu? (passt es in das bisherige Muster oder bricht es aus?)

Diese Informationen werden gespeichert und beeinflussen die nächsten Bilder.

#### Was mit diesen Informationen passiert

Das System steuert sich selbst:

- Dinge, die zu häufig vorkommen, werden abgeschwächt
- Dinge, die selten oder neu sind, können verstärkt werden
- Wenn sich alles festfährt, wird bewusst ein neuer Impuls gesetzt

So entsteht keine Endlosschleife aus ähnlichen Bildern.

#### Was eine „Epoch“ in diesem System ist

Eine Epoch ist eine Phase, in der die Bilder:

- sich inhaltlich ähneln
- ähnliche Motive und Strukturen haben
- eine erkennbare Bildsprache teilen

Eine Epoch endet, wenn:

- sich die Bildsprache deutlich ändert oder
- etwas Neues dauerhaft dominiert

Die Epochs entstehen automatisch, nicht weil jemand sie vorgibt.

#### Warum mehrere Epochs wichtig sind

Mehrere Epochs bedeuten:

- unterschiedliche Bildphasen
- thematische oder formale Wendepunkte
- erkennbare Entwicklung statt Variation

Im Atlas sieht man dann:

- frühe Phasen
- Übergänge
- spätere Zustände

Das macht die Serie lesbar und kuratierbar.

#### Was der Atlas eigentlich ist

Der Atlas ist keine Galerie, sondern eine Dokumentation:

- zeitliche Abfolge
- Gruppierungen ähnlicher Bilder
- Phasen (Epochs)
- typische Motive pro Phase

Er zeigt nicht nur Ergebnisse, sondern den Prozess.

#### Künstlerisch relevant, weil

- Das Werk entsteht über Zeit
- Bedeutung entsteht durch Abfolge
- Brüche sind sichtbar, nicht geglättet
- Autorschaft liegt in den Regeln, nicht im Einzelbild

Du arbeitest nicht mit „Prompts“, sondern mit Entwicklungsbedingungen.

### Was du bekommst

- Einen wiederholbaren **Run-Ordner** neben dem Script:
  - `YYYY-MM-DD\run-YYYYMMDD-HHMMSS\...`
- **Config-Validierung** mit klaren Fehlern bei fehlenden Feldern
- **Resume-Modus**: bestehende Runs mit `world_state.json` / `world_log.jsonl` fortsetzen
- **Backend-Auto-Detection** (CUDA → DirectML → CPU) mit Verifikation + Fallback
- Outputs:
  - PNGs pro Iteration
  - Embeddings `.npy`
  - `world_state.json`, `world_log.jsonl`
  - `clusters.json`, `epochs.json`
  - `outputs\atlas\rwe_atlas_v04.pdf` (wird automatisch geöffnet)
  - Atlas-Seiten mit **Epochen-Zusammenfassungen**, Motiv-Index und Kontaktbögen

### Quick Start (Windows)

1. Lege diese Dateien in einen Ordner:
   - `rwe_runner.ps1`
   - `rwe_config.json`
2. Rechtsklick auf **PowerShell** → „Als Administrator ausführen“ (oder einfach starten; das Script erhöht sich selbst).
3. Starten:
   ```powershell
   .\rwe_runner.ps1
   ```
4. Eingeben:
   - Iterationszahl (Standardwert aus der Config)
   - Hugging-Face-Token (optional; nötig für gated Modelle wie SDXL)

Nach Abschluss öffnet das Script den erzeugten PDF-Atlas automatisch.

### Config-Format

Die Config speichert **Werte** und **Erklärungen** als JSON.

Jeder Hauptbereich ist ein Objekt mit:

- `description`: was es ist
- `effects`: wie es die Serie beeinflusst
- `values`: die eigentlichen Daten

#### `initial_words.values`
Start-Motive für die ersten Prompts. Sie beeinflussen frühe Bilder und prägen die langfristige Motiv-Bank.

#### `banned_motifs.values`
Harte Blacklist für Begriffe, die nie in die Motiv-Bank gelangen dürfen (Anti-Hallway / Anti-Interior).

#### `stopwords.values`
Filtert Wörter aus Captions, damit nur semantisch relevante Motive gelernt werden.

#### `style_pool.values`
Stil-Zusätze, die gelegentlich rotiert werden, um das Bild-„lokale Minimum“ zu verlassen.

#### `novelty_motif_pool.values`
Motive, die bei sinkender Vielfalt injiziert werden und Exploration erzwingen.

#### `escape_motifs.values`
Notfall-Motive, wenn der Loop in Innenräumen „festhängt“.

#### `runtime_defaults.values.iterations`
Standard-Iterationsanzahl, die beim Start vorgeschlagen wird.

### Resume-Modus

Beim Start kannst du **Resume** wählen:

- Wähle einen bestehenden Run-Ordner (Standard: letzter Run).
- Der Runner setzt dort mit den vorhandenen State-/Log-Dateien fort.
- Die im Run-Ordner gespeicherte Config bleibt verbindlich.

### Backend-Auswahl

Beim Start erkennt der Runner die GPU(s), verifiziert CUDA-Verfügbarkeit und wählt das beste Backend:

1. **CUDA** bei NVIDIA + `nvidia-smi` (danach Verifikation in Python).
2. **DirectML** für AMD/Intel (oder NVIDIA ohne CUDA), danach Verifikation.
3. **CPU** als Fallback, wenn GPU-Backends fehlschlagen.

Das bestätigte Backend wird über `RWE_BACKEND` an Python übergeben und dort genutzt.

### Hinweise

- Standard-Backend-Priorität ist SDXL; bei Fehlschlag wird auf SD 1.5 zurückgefallen.
- CPU-only funktioniert, ist aber sehr langsam.
- Das Projekt ist ein Research/Prototype-Runner – Anpassungen an Modelle, Prompts und GPU-Settings sind ausdrücklich vorgesehen.

### Dateien

- `rwe_runner.ps1` – kompletter Runner/Installer (PowerShell 5.1 kompatibel)
- `rwe_config.json` – Config + Erklärungen
- `LICENSE` – Unlicense (Public Domain, wo möglich)
- `LICENSE-ARTWORK-DE.md` – Lizenz für Artwork (Deutsch)
- `LICENSE-ARTWORK-EN.md` – License for artwork (English)

### Lizenzen

- [LICENSE](LICENSE)
- [LICENSE-ARTWORK-DE.md](LICENSE-ARTWORK-DE.md)
- [LICENSE-ARTWORK-EN.md](LICENSE-ARTWORK-EN.md)
