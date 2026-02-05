# RealWorldEngine (Windows Runner)

Ein kompakter **Windows‑PowerShell‑Runner (PowerShell 5.1)**, der eine Python‑3.10‑Umgebung aufsetzt, einen passenden PyTorch‑Backend (CUDA/DirectML/CPU) ermittelt und anschließend eine konfigurierbare Bild‑Serie generiert. Die Ergebnisse landen in einem Run‑Ordner inklusive **PNG‑Outputs**, **State/Log‑Dateien** und einem automatisch geöffneten **Atlas‑PDF**.

Die gesamte Steuerung der Serie passiert über eine einzige JSON‑Datei: **`rwe_config.json`**.

## Was ist das hier?

**RealWorldEngine** ist ein prototypischer Runner für lange Bildserien. Er kombiniert:

- einen **zustandsbasierten Generations‑Loop** (mit `world_state.json`/`world_log.jsonl`),
- **Motif‑ und Style‑Steuerung** (Startmotive, Stopwords, Stilrotation),
- **Exploration/Anti‑Monotonie‑Mechanismen** (Novelty‑ und Escape‑Motive),
- eine **einheitliche Ergebnisstruktur** pro Run.

Kurz: Du definierst das „Vokabular“ der Serie in der Config, startest den Runner – und bekommst eine lange, nachvollziehbare Bild‑Abfolge mit klarer Struktur und Logs.

## Wie funktioniert es? (Kurzfassung)

1. **PowerShell‑Runner** startet, richtet venv ein und prüft/installiert benötigte Python‑Pakete.
2. Der Runner **erkennt das beste Backend** (CUDA → DirectML → CPU) und übergibt es an Python.
3. Ein **eingebettetes Python‑Script** erzeugt die Serie Iteration für Iteration, schreibt Logs/State und baut am Ende den **Atlas‑PDF**.

## Quick Start (Windows)

1. Lege diese Dateien in einen Ordner:
   - `rwe_runner.ps1`
   - `rwe_config.json`
2. PowerShell öffnen (Administrator empfohlen, funktioniert meist auch ohne).
3. Starten:
   ```powershell
   .\rwe_runner.ps1
   ```
4. Optional wirst du nach **Iterationszahl** und **Hugging‑Face‑Token** gefragt (für gated Modelle wie SDXL).

Wenn der Run fertig ist, wird der **Atlas‑PDF** automatisch geöffnet.

## Ergebnisstruktur

Für jeden Lauf wird ein Run‑Ordner neben dem Script erstellt:

```
YYYY-MM-DD\run-YYYYMMDD-HHMMSS\...
```

Darin findest du u. a.:

- PNGs pro Iteration
- `world_state.json`, `world_log.jsonl`
- `clusters.json`
- `outputs\atlas\rwe_atlas_v04.pdf`
- gespeicherte Embeddings (`.npy`)

## Konfiguration (`rwe_config.json`)

Die Config enthält **Werte + Erklärungen**. Jede Hauptsektion besitzt:

- `description`: was es ist
- `effects`: wie es die Serie beeinflusst
- `values`: die eigentlichen Daten

Wichtige Bereiche:

### `initial_words.values`
Start‑Motive für die ersten Prompts. Diese prägen frühe Bilder und beeinflussen langfristig die Motif‑Bank.

### `banned_motifs.values`
Harter Ausschluss bestimmter Begriffe (z. B. Anti‑Hallway/Anti‑Interior).

### `stopwords.values`
Filtert Wörter aus Captions, damit nur semantisch relevante Motive gelernt werden.

### `style_pool.values`
Stil‑Zusätze, die gelegentlich rotiert werden, um das Bild‑„lokale Minimum“ zu verlassen.

### `novelty_motif_pool.values`
Motive, die bei sinkender Vielfalt injiziert werden, um neue Themen zu erzwingen.

### `escape_motifs.values`
Notfall‑Motive, wenn der Loop in Innenräumen „festhängt“.

### `runtime_defaults.values.iterations`
Standard‑Iterationsanzahl, die beim Start angeboten wird.

## Resume‑Modus

Beim Start kannst du **Resume** wählen:

- Wähle einen bestehenden Run‑Ordner (Standard: letzter Run).
- Der Runner setzt dort mit den vorhandenen State/Log‑Dateien fort.
- Die im Run‑Ordner gespeicherte Config bleibt verbindlich.

## Backend‑Auswahl

Der Runner testet verfügbare Backends in dieser Reihenfolge:

1. **CUDA** (NVIDIA + `nvidia-smi`), danach Verifikation im Python‑Code
2. **DirectML** (AMD/Intel oder NVIDIA ohne CUDA), danach Verifikation
3. **CPU** als Fallback

Das bestätigte Backend wird über `RWE_BACKEND` an Python übergeben.

## Hinweise

- Standard‑Backend‑Priorität ist **SDXL**, mit Fallback auf **SD 1.5**, falls SDXL fehlschlägt.
- CPU‑Only funktioniert, ist aber sehr langsam.
- Das Projekt ist ein **Research/Prototype‑Runner** – Anpassungen an Modelle, Prompts und GPU‑Settings sind ausdrücklich vorgesehen.

## Dateien

- `rwe_runner.ps1` – Runner/Installer (PowerShell 5.1 kompatibel)
- `rwe_config.json` – Konfiguration + Erklärungen
- `LICENSE` – Unlicense (Public Domain, wo möglich)
