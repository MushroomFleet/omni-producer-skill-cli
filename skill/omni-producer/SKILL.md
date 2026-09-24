---
name: omni-producer
description: This skill should be used when the user wants to generate video (.mp4) files from a "video job catalogue" markdown file or JSON manifest — e.g. "generate the videos from demo-videos-omni-prompts.md", "run omni on this catalogue", "batch these video prompts into clips" — or wants Gemini Omni Flash video work of any kind, including text-to-video ("make a video of..."), image-to-video ("animate this image"), reference-to-video ("use these images as the characters"), and video editing ("make this video anime", "change the lighting in this clip", "edit my video"), including chained edits of previous outputs without re-uploading. Also use it to regenerate specific jobs ("redo 03-cat-and-yarn.mp4", "job 2 failed, run it again") and for catalogue files the rigid parser can't read, where Claude extracts a manifest JSON before generating. Mentions of "Omni Producer", Gemini Omni Flash, gemini-omni-flash-preview, any *omni-prompts.md file, or Edit-from chaining always trigger it. It previews extraction with a free dry-run, confirms spend scope with the user, then orchestrates the OmniProducer CLI (native OmniProducer.exe, or the Invoke-OmniProducer.ps1 PowerShell fallback) to deliver .mp4 videos plus interaction-id sidecars straight to disk.
---

# Omni Producer

Turn a "video job catalogue" markdown file (or a Claude-extracted JSON manifest)
into finished `.mp4` videos on disk. This skill is the orchestration layer over the
OmniProducer CLI — a zero-UI tool that parses a catalogue, builds the task-specific
Gemini Omni Flash request (`gemini-omni-flash-preview`, the `/v1beta/interactions`
endpoint), delivers each video (inline base64 or URI polling), and writes
`NN-<slug>.mp4` plus an `NN-<slug>.json` **sidecar** recording the interaction id —
so any output can later be edited conversationally with no re-upload. The CLI ships
as two functionally-identical, flag-compatible implementations: a native
`OmniProducer.exe` (preferred — self-contained, no PowerShell or .NET install
required) and the original `Invoke-OmniProducer.ps1` Windows PowerShell 5.1 script
(fallback when no exe is present). Both were built from, and proven against, the
same specification (`omni-producer-CLI-TINS.md`), so these instructions apply
identically to either.

Video generation is **metered spend** — each video takes ~30 s to several minutes of
paid API time — so the guiding principle is **preview before you spend**: always
dry-run (free, no key, no network), confirm the scope with the user, and prefer
`-Index N` single-job proofs before full batches.

## Prerequisites

- The CLI itself: `OmniProducer.exe` needs nothing else installed. Only the `.ps1`
  fallback needs Windows PowerShell 5.1+ to run. Prefer a project-local copy of
  either; a bundled copy of both ships with this skill.
- A Google Gemini API key with access to the Omni Flash model (an `AIza...`-style
  key used via the `x-goog-api-key` header).

## The four tasks

Each catalogue job resolves to one of four API tasks — explicitly via a `Task:`
directive, or inferred from the media it carries:

| Task | Media | Meaning |
|---|---|---|
| `text_to_video` | none | Generate from the prompt alone. |
| `image_to_video` | `Image:` | Animate / build the video from one image. |
| `reference_to_video` | `Image:` + `Ref:`(s) | First image binds `<FIRST_FRAME>`, refs bind `<IMAGE_REF_0..>` in order (max 6). |
| `edit` | `Source:` video, or `Edit-from:` | Edit an uploaded video (Files API), or chain-edit a previous generation via its sidecar's interaction id. |

Inference rules and directive syntax: `references/catalogue-format.md`.

## Two input modes: markdown vs manifest

- **Markdown mode (`-Path`)** — the CLI parses the file itself. A job is a `###`
  heading + a fenced prompt block + optional directive lines (`Image:`, `Ref:`,
  `Source:`, `Edit-from:`, `Task:`, `Aspect:`, `Delivery:`). Use for uniform
  catalogues; format spec in `references/catalogue-format.md`, copyable template in
  `references/example-catalogue.md`.
- **Manifest mode (`-Manifest`)** — **Claude reads, understands, and extracts** each
  job (title, prompt, task, media paths, edit chain) into a small JSON, and the CLI
  just runs inference over it. Use it for any material the markdown parser can't
  reliably read — prose briefs, storyboard docs, `##`-header files, or jobs that
  need programmatic assembly. Schema + worked example: `references/manifest-schema.md`.

A dry-run decides which (step 4): preview `-Path` first; if it reads the file
correctly, stay in markdown mode; otherwise extract a manifest.

## Workflow

### 1. Identify the target

Determine which catalogue/media the user means. If they named a file, resolve it.
If they described a one-off ("animate this image", "edit this clip"), author a small
catalogue or manifest for it — a single-job markdown file is fine. If they were
vague, glob for `*omni-prompts.md` and confirm.

### 2. Locate the CLI

Prefer, in order: (1) the project's own `OmniProducer.exe` (commonly
`./omni-producer/OmniProducer.exe`); (2) the project's own
`Invoke-OmniProducer.ps1`; (3) this skill's bundled copy, again preferring
`scripts/OmniProducer.exe` over `scripts/Invoke-OmniProducer.ps1`. Invocation flags
are identical — only the prefix changes:

```powershell
# Native exe (no PowerShell required):
<exe-path> -Path <markdown-path> -DryRun

# PowerShell script:
& <ps1-path> -Path <markdown-path> -DryRun
```

### 3. Ensure an API key is configured

The CLI reads its key from, in order: `-ApiKey`, then `apiKey` in the `config.cfg`
beside the executable (or script), then `$env:GEMINI_API_KEY`, then
`$env:OMNI_API_KEY`. A dry-run needs no key; generating does.

If the project CLI's `config.cfg` has a non-empty `apiKey`, use it. If using the
bundled CLI (whose config has no key), pass `-ConfigPath` pointing at the project
config, or `-ApiKey`, or rely on the env var — and if none is set, ask the user to
add their key rather than guessing. The model id also lives in `config.cfg`
(`model`), so a future model rename is a config edit, never a code change.

### 4. Dry-run, and choose the input mode (always)

Preview extraction first — free, no key, no network:

```powershell
<cli-path> -Path <markdown-path> -DryRun
```

Review with the user: job count, task tags (`[t2v]`/`[i2v]`/`[r2v]`/`[edit]`),
media notes, and target filenames. The dry-run also **validates** — missing media
files, task/media contradictions, and bad `Edit-from` references are flagged `!!`
(and exit code 1). Fix flags before spending. If the file's shape defeats the
parser, switch to manifest mode: extract the jobs yourself, write the manifest
(`references/manifest-schema.md`), and dry-run that instead:

```powershell
<cli-path> -Manifest <manifest-path> -DryRun
```

### 5. Confirm scope before generating

Generation is metered — each video is real money and ~30 s to several minutes.
Agree with the user on how much to produce **before** any wet run:

- One job (proof / spot-check): `-Index N`
- First few: `-Limit N`
- A whole file: no selection flags
- A whole folder of catalogues: point `-Path` at the folder

State the scope plainly (how many videos, which tasks) and get an explicit yes.
Prefer proving one job before a batch.

### 6. Generate and report

Drop `-DryRun` from whichever mode you settled on:

```powershell
<cli-path> -Path <markdown-path>      [-Index N | -Limit N]   # markdown mode
<cli-path> -Manifest <manifest-path>  [-Index N | -Limit N]   # manifest mode
```

Both modes share the same engine: sequential, skips outputs already on disk (unless
`-Force`), retries transient failures with backoff (but never retries deterministic
safety blocks), and prints per-job OK/SKIP/FAILED plus a totals line. Report the
output folder and files produced, and surface any failures verbatim rather than
smoothing over them. Re-running the same catalogue is free — completed jobs skip.

## Edit chaining (the sidecar system)

Every generated video gets a sidecar `NN-<slug>.json` recording its
`interactionId` (all jobs send `store: true`). A later job — same run or any future
run — can edit that output server-side with **no re-upload**:

- `Edit-from: #N` — job N of the same catalogue (earlier position only).
- `Edit-from: path\to\NN-slug.json` — any sidecar on disk.
- `Edit-from: path\to\NN-slug.mp4` — resolves to the sidecar beside it.
- `Edit-from: v1_...` — a literal interaction id.

Editing prompts work best simple: "Make this video anime. Keep everything else the
same." An edit inherits the source video's aspect ratio.

## Command reference

| Flag | Meaning |
|---|---|
| `-Path` | Markdown mode: a `.md` file, or a folder of `.md` files (CLI parses it). |
| `-Manifest` | Manifest mode: a Claude-extracted JSON of jobs (CLI just infers). |
| `-DryRun` | Preview + validate; no API call, no key. Exit 1 if validation flags. |
| `-Index N` | Generate only job N (1-based catalogue position). |
| `-Limit N` | Generate at most N jobs (applied after `-Index`). |
| `-Force` | Regenerate outputs that already exist. |
| `-Model` | Override model id (default from config: `gemini-omni-flash-preview`). |
| `-AspectRatio` | `16:9` (default) or `9:16`, for jobs without their own `Aspect:`. |
| `-Delivery` | `uri` (default) or `inline`, for jobs without their own `Delivery:`. |
| `-ApiKey` | Provide the key inline. |
| `-ConfigPath` | Use a specific `config.cfg` (e.g. the project's). |
| `-Recurse` | Recurse into subfolders when `-Path` is a folder. |

## Troubleshooting (live-API verified)

- **"Input blocked … sensitive words" on an upload-edit with an innocuous prompt:**
  almost certainly NOT the prompt. Uploaded-video editing is unavailable in the
  EEA/Switzerland/UK, and the restriction surfaces as this generic policy block —
  it fires even on Google's own canonical edit prompts. Chained edits of
  model-generated videos (`Edit-from:`) keep working in those regions; suggest that
  path instead. Don't rephrase-and-retry: the CLI treats input blocks as
  non-retryable by design.
- **`Deadline expired before operation could complete.`** — a transient server-side
  timeout, common with large reference images (multi-MB PNGs inflate the request).
  The CLI's automatic retry usually clears it; persistent cases → downscale images.
- **"Gemini's response didn't include a video — raw response saved to …"** — the
  response shape was unrecognized; read the saved `NN-<slug>-response.json` and
  inspect rather than guessing.
- **`That output has no interaction id to chain from.`** — the referenced sidecar
  predates chaining or was generated with `store: false`; regenerate the source.
- **Auth errors (`API key not valid`)** — confirm the key is an `AIza...` Gemini
  API key and check which config the CLI is reading (project vs bundled).
- **Uploads:** sources must be MP4/MOV/WEBM/M4V and ≤ 2 GB (Files API cap); files
  live server-side for 48 h, so the CLI re-uploads fresh each run by design.
- **Interrupted runs:** nothing partial persists (atomic writes) — just re-run;
  completed jobs skip, unfinished ones regenerate.

## Reference files

- **`references/catalogue-format.md`** — the markdown catalogue format: job
  boundaries, all seven directives, task-inference rules, output layout, and the
  sidecar schema. Read it when a dry-run looks wrong or a file's structure is
  unusual.
- **`references/example-catalogue.md`** — a copyable catalogue template showing all
  four tasks and the chaining syntax.
- **`references/manifest-schema.md`** — the JSON schema + worked example for
  manifest mode. Read it before writing a manifest for a file the parser can't read.

## Bundled tools

- **`scripts/OmniProducer.exe`** — the portable, self-contained native CLI, used
  when a project has no local copy. Preferred over the `.ps1` when both are present.
- **`scripts/Invoke-OmniProducer.ps1`** — the portable Windows PowerShell 5.1
  fallback, used only when no exe is available.
- **`scripts/config.cfg`** — keyless config with proven defaults (the bundled CLI
  reads this; supply the key via `-ApiKey`, env var, or `-ConfigPath` to a project
  config). **`scripts/config.example.cfg`** — the annotated template to copy beside
  a project CLI and fill in.
