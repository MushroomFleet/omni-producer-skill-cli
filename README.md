# Omni Producer

**Batch-generate and edit AI videos from a simple markdown file — powered by the Gemini Omni Flash API.**

Write your video ideas as prompts in a plain `.md` file. Preview the whole batch for free. Then let Omni Producer generate every video straight to your disk — and when you want changes, just add an edit job ("Make this video anime. Keep everything else the same.") and it reworks any previous video without re-uploading anything.

```
Omni Producer
Model: gemini-omni-flash-preview   Aspect: 16:9   Delivery: uri   Mode: MARKDOWN   GENERATE

=== demo-videos-omni-prompts.md ===
Jobs: 5   ->   output: .\demo-videos-omni-prompts
  [01] Neon City Flyover                  [t2v]
        generating...
        polling files/zlbn0jgixnic...
        ACTIVE after 5s, downloading...
        OK  01-neon-city-flyover.mp4  (2,568 KB, 46.6s)

Done. Generated: 1  Skipped: 0  Failed: 0
```

## What you can make

| You write | You get |
|---|---|
| A prompt | A generated video, with audio |
| A prompt + an image | Your image brought to life |
| A prompt + a first-frame + reference images | A video starring your characters, products, or style (up to 6 references) |
| An edit prompt + any previous video | That video re-worked — restyled, relit, objects added or removed |

Videos can be landscape (`16:9`) or portrait (`9:16`) for shorts/reels.

## Get started in 4 steps

**1. Download** `OmniProducer.exe` from the [latest release](https://github.com/MushroomFleet/omni-producer-skill-cli/releases/latest). It's a single self-contained Windows exe — nothing else to install.

**2. Add your API key.** Copy [`omni-producer/template-config.cfg.txt`](omni-producer/template-config.cfg.txt) to `config.cfg` next to the exe, and replace `ADD API KEY HERE` with your free [Google Gemini API key](https://aistudio.google.com/apikey). Done — every other setting already has a sensible default.

**3. Write your videos** in a markdown file. Each `###` heading is one video; the fenced block is its prompt:

````markdown
### Neon City Flyover
**Aspect:** 9:16
```
A futuristic city with neon lights and flying cars, cyberpunk style,
continuous unbroken aerial shot. Include a high energy techno beat. No dialogue.
```

### Anime Pass On The Flyover
**Edit-from:** #1
```
Make this video anime. Keep everything else the same.
```
````

**4. Preview free, then generate:**

```
OmniProducer.exe -Path .\my-videos-omni-prompts.md -DryRun    # free preview — checks everything, spends nothing
OmniProducer.exe -Path .\my-videos-omni-prompts.md -Index 1   # try one video first
OmniProducer.exe -Path .\my-videos-omni-prompts.md            # run the whole batch
```

Videos land in a folder next to your markdown file as `01-neon-city-flyover.mp4`, `02-...` — numbered and named from your headings.

## Editing is where it gets fun

Every video Omni Producer makes gets a small `.json` sidecar next to it — its memory. Point a new job at any previous video and the API edits it **server-side, with full context of what it made before**:

```markdown
### Golden Hour Version
**Edit-from:** .\demo-videos-omni-prompts\01-neon-city-flyover.json
```
Change the lighting to golden hour sunset. Keep everything else the same.
```
```

Works in the same file (`Edit-from: #1`), across runs, or weeks later. Simple edit prompts work best — say what to change, then "Keep everything else the same."

You can also edit **your own footage**: `**Source:** .\my-clip.mp4` uploads it (up to 2 GB) and applies your prompt.

## Job options (one line each, under the heading)

| Directive | What it does |
|---|---|
| `**Aspect:** 9:16` | Portrait video (default is `16:9`) |
| `**Image:** .\art.png` | Animate this image (PNG/JPG/WEBP) |
| `**Ref:** .\cat.png` | Add a reference image (repeat up to 6; needs an `Image:` first-frame). Reference them in your prompt as `<IMAGE_REF_0>`, `<IMAGE_REF_1>`... |
| `**Source:** .\clip.mp4` | Upload and edit your own video |
| `**Edit-from:** #1` | Edit a previous generation (job number, sidecar path, or .mp4 path) |
| `**Task:** edit` | Force the task type (normally auto-detected) |
| `**Delivery:** inline` | Advanced: inline delivery for small videos (default `uri`) |

## Useful flags

| Flag | What it does |
|---|---|
| `-DryRun` | Free preview + validation (missing files, bad references) — no key needed |
| `-Index N` | Generate only video N |
| `-Limit N` | Generate at most N videos |
| `-Force` | Regenerate videos that already exist (default: skip them — re-running a file is free) |
| `-AspectRatio 9:16` | Default aspect for the run |
| `-Manifest jobs.json` | Advanced: run from a JSON job list instead of markdown |

## Good to know

- **Video generation costs money** — each video is ~30 seconds to a few minutes of metered Gemini API time. That's why the workflow is dry-run → one video → batch, and why re-runs skip everything already on disk.
- **Prompting tips:** ask for "a single continuous shot, no scene cuts" if you don't want the model to edit-cut your scene; describe the audio you want ("calm background music", "No dialogue"); put text you want rendered in quotes.
- **Region note:** editing *uploaded* videos isn't available in the EEA/Switzerland/UK (Google restriction — it surfaces as a generic "Input blocked" message no matter your prompt). Editing videos *generated by the model* works everywhere.
- If a job fails, the API's real error message is shown verbatim — transient errors retry automatically.
- All generated videos carry Google's invisible SynthID watermark.

## Install the skill

Prefer to have Claude drive Omni Producer for you? The [latest release](https://github.com/MushroomFleet/omni-producer-skill-cli/releases/latest) also
ships `omni-producer.skill` — a Claude skill package (no exe inside it):

1. Unzip `omni-producer.skill` into your skills directory as `omni-producer/`.
2. Download `OmniProducer.exe` from the same release and place it at
   `omni-producer/scripts/OmniProducer.exe`. Without it, the skill falls back
   to the bundled `scripts/Invoke-OmniProducer.ps1` (Windows PowerShell 5.1+ —
   nothing else to install).
3. Copy `scripts/config.example.cfg` to `scripts/config.cfg` and add your
   Gemini API key.

## For developers

- **PowerShell fallback:** [`omni-producer/Invoke-OmniProducer.ps1`](omni-producer/Invoke-OmniProducer.ps1) is flag-identical to the exe and runs on stock Windows PowerShell 5.1 — no download needed, just this repo.
- **Build from source:** `cd omni-producer/OmniProducer && dotnet publish -c Release` (.NET 8) reproduces the exe. Verify releases against the SHA256 in the release notes.
- **The spec:** [`omni-producer-CLI-TINS.md`](omni-producer-CLI-TINS.md) is a complete [TINS](https://thereisnosource.com) specification — both implementations were generated from it and proven against the live API through a 10-scenario quality gate. It documents four live-API behaviors Google's public docs don't (chained-edit and aspect-ratio request rules, the correct upload reference shape, and deterministic safety blocks).
- **Test fixtures:** `omni-producer/tests/` holds the proven catalogue, a validation-error catalogue, and the manifest-mode equivalent.

## 📚 Citation

### Academic Citation

If you use this codebase in your research or project, please cite:

```bibtex
@software{omni_producer,
  title = {Omni Producer: a zero-UI CLI for batch video generation and stateful video editing via the Gemini Omni Flash API},
  author = {Drift Johnson},
  year = {2026},
  url = {https://github.com/MushroomFleet/omni-producer-skill-cli},
  version = {1.0.0}
}
```

### Donate:

[![Ko-Fi](https://cdn.ko-fi.com/cdn/kofi3.png?v=3)](https://ko-fi.com/driftjohnson)
