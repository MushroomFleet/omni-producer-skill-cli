---
name: omni-producer
description: This skill should be used when the user wants to generate video (.mp4) files from a "video job catalogue" markdown file or JSON manifest — e.g. "generate the videos from demo-videos-omni-prompts.md", "run omni on this catalogue", "batch these video prompts into clips" — or wants Gemini Omni Flash video work of any kind, including text-to-video ("make a video of..."), image-to-video ("animate this image"), reference-to-video ("use these images as the characters"), and video editing ("make this video anime", "change the lighting in this clip", "edit my video"), including chained edits of previous outputs without re-uploading. Also covers splitting and walking a long input video through a continuity-aware sequence of edits ("split this long video into segments and edit each one", "walk through this whole take") and keeping a job's own input-clip audio instead of the model's generated audio ("keep the original audio", "don't change the sound"). Also use it to regenerate specific jobs ("redo 03-cat-and-yarn.mp4", "job 2 failed, run it again") and for catalogue files the rigid parser can't read, where Claude extracts a manifest JSON before generating. Mentions of "Omni Producer", Gemini Omni Flash, gemini-omni-flash-preview, any *omni-prompts.md file, or Edit-from chaining always trigger it. It previews extraction with a free dry-run, confirms spend scope with the user, then orchestrates the OmniProducer CLI (native OmniProducer.exe, or the Invoke-OmniProducer.ps1 PowerShell fallback) to deliver .mp4 videos plus interaction-id sidecars straight to disk.
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

## Installation

- Place this whole skill folder in the user's skills directory as `omni-producer/`.
- Download `OmniProducer.exe` from the same release this skill shipped with and
  put it at `omni-producer/scripts/OmniProducer.exe`. Without it, the skill falls
  back to the bundled `scripts/Invoke-OmniProducer.ps1` (Windows PowerShell
  5.1+ — nothing else to install).
- Copy `scripts/config.example.cfg` to `scripts/config.cfg` and add the user's
  Gemini API key (`apiKey`). Everything else in it already has a sensible
  default.

## Prerequisites

- The CLI itself: `OmniProducer.exe` needs nothing else installed. Only the `.ps1`
  fallback needs Windows PowerShell 5.1+ to run. Prefer a project-local copy of
  either; the `.ps1` ships bundled with this skill, and the exe joins it once
  installed (see Installation).
- A Google Gemini API key with access to the Omni Flash model (an `AIza...`-style
  key used via the `x-goog-api-key` header).
- `ffmpeg`/`ffprobe` on `PATH` (or `ffmpegPath`/`ffprobePath` set in `config.cfg`) —
  only needed for **sequence mode** (`Split:` jobs, below) and
  **`--preserve-input-audio`** (below); every other task needs neither.

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

## Sequence mode (long-input splitting)

Reach for this when the user hands over a video **longer than one generation**
and wants it processed end-to-end (a long take, a full scene, a whole
walkthrough) rather than edited in one pass. A `Split:` directive names that
source; the CLI probes it with `ffprobe`, splits it into segment-length clips
with `ffmpeg`, and queues one `edit` job per segment (each segment is that
job's uploaded source video).

| Directive | Value | Meaning |
|---|---|---|
| `Split:` | file path | The source video to split. Cannot combine with `Image`/`Ref`/`Source`/`Edit-from`. |
| `Segment:` | whole seconds | Segment length; requires `Split:`. Default 8s (`config.generationSeconds`). |
| `Walk:` | `on` \| `off` | Carry the previous segment's last frame forward as a driving image, for continuity. Default `on`. |
| `Vision:` | `on` \| `off` | Describe that carried-forward frame and fold the description into the next segment's prompt. Default `on` while walking. |

Manifest mode carries the same four as `split`, `segmentSeconds`, `walk`
(boolean), `vision` (boolean) — see `references/manifest-schema.md`.

Each segment gets its own sidecar (with a `sequence` object recording its
position and, when walked, the continuity frame) and skips/resumes exactly
like an ordinary job, so an interrupted or re-run sequence picks up where it
left off. Dry-run lists every planned segment after probing the input — free,
no `ffmpeg` call, no API call. Details: `references/catalogue-format.md`.

## Preserving input audio

By default, an `edit` job's output carries audio the **model** generated,
replacing whatever the input clip had. Add `-PreserveInputAudio` (script) /
`--preserve-input-audio` (exe, also accepts `-PreserveInputAudio`) to keep the
**input clip's own audio** instead, after that job finishes. Off by default —
without the flag, nothing changes.

- Applies to any job with a local input clip: a `Source:` edit, or each
  segment of a `Split:` job. Jobs with no local input clip (text, image,
  reference, `Edit-from`) are unaffected — their line reads
  `audio: generated (no input clip)`.
- If the input clip itself has no audio track, the output keeps the video
  with no audio at all rather than inventing any —
  `audio: input (silent input; generated audio removed)`.
- The input's audio is trimmed or padded with silence to match the generated
  video's length, so turning this on never changes a job's output duration.
- Needs `ffmpeg`/`ffprobe` (see Prerequisites) — checked once, up front,
  before any job runs, so a run never spends generation only to fail at the
  merge step.
- A merge failure fails that job without discarding the generated video (kept
  as `<name>.generated.mp4` for salvage) and without writing a sidecar.

This changes the output's audio track, which is easy to miss until playback —
state that it's on for a batch alongside the usual spend-scope confirmation.

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
| `-PreserveInputAudio` | Keep each affected job's input-clip audio instead of the model's generated audio (exe: `--preserve-input-audio`). See *Preserving input audio*. |

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
  boundaries, all eleven directives, task-inference rules, output layout, and the
  sidecar schema. Read it when a dry-run looks wrong or a file's structure is
  unusual.
- **`references/example-catalogue.md`** — a copyable catalogue template showing all
  four tasks and the chaining syntax.
- **`references/manifest-schema.md`** — the JSON schema + worked example for
  manifest mode. Read it before writing a manifest for a file the parser can't read.

## Bundled tools

- **`scripts/OmniProducer.exe`** — **not** shipped in the skill package; the
  user downloads it from the release and places it here themselves (see
  Installation). Preferred over the `.ps1` fallback once present.
- **`scripts/Invoke-OmniProducer.ps1`** — the portable Windows PowerShell 5.1
  fallback, ships with the skill and used only when no exe is present.
- **`scripts/config.example.cfg`** — the annotated, keyless template with
  proven defaults. Copy it to `scripts/config.cfg` beside the CLI and add the
  key (see Installation) — `config.cfg` itself is never shipped, so a fresh
  install always starts keyless.
