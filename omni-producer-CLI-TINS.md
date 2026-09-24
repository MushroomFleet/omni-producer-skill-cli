# Omni Producer CLI

<!-- TINS Specification v1.0 -->
<!-- ZS:COMPLEXITY:HIGH -->
<!-- ZS:PRIORITY:HIGH -->
<!-- ZS:PLATFORM:WINDOWS -->
<!-- ZS:LANGUAGE:POWERSHELL -->

## Description

Omni Producer is a zero-UI Windows PowerShell 5.1 CLI (`Invoke-OmniProducer.ps1`) that
turns "video job catalogue" files into finished `.mp4` videos on disk by orchestrating
the **Gemini Omni Flash** video generation/editing API (the `/v1beta/interactions`
endpoint). It is the video sibling of the proven Lyra Producer music CLI and follows
the same architecture: a config file beside the script, two input modes (a parseable
markdown catalogue and a Claude-extracted JSON manifest), a dry-run preview that costs
nothing, and a sequential generation engine with skip-existing, retry, and a totals
summary.

It supports all four Omni Flash tasks — `text_to_video`, `image_to_video`,
`reference_to_video`, and `edit` (both chained edits of previous generations and
uploads of the user's own videos via the Files API) — and both delivery paths (inline
base64 and URI polling). Every completed video gets a **sidecar JSON** recording its
`interaction_id`, so a later run can edit any previous output conversationally without
re-uploading anything.

The intended workflow has a human quality gate: prove this script end-to-end first,
then port it to a flag-compatible native EXE, and only then write the orchestration
skill — so the skill describes final, proven behavior.

Every API shape in this document is grounded twice: in Google's published Omni Flash
and Files API documentation, and in the working Rust implementation
(`omnotation-dev/src-tauri/src/gemini.rs` + `jobs.rs`), which is a proven,
shipping client of exactly this API. Where the docs and the proven code differ, the
proven code wins (differences are called out inline).

## Functionality

### Core behavior

1. Load config (`config.cfg` beside the script, JSON content), apply CLI overrides.
2. Resolve the job list from `-Path` (markdown mode) or `-Manifest` (manifest mode).
3. `-DryRun`: print the numbered job plan (task, media, output filename), validate
   that every referenced media file exists, and exit without any network call.
4. Otherwise: for each selected job, sequentially — skip if the output `.mp4` already
   exists (unless `-Force`), build the task-specific request, POST it, deliver the
   video (decode inline base64 or poll-then-download for URI delivery), write
   `NN-<slug>.mp4` plus the `NN-<slug>.json` sidecar, print per-job
   `OK / SKIP / FAILED`, and finish with a totals line.

### CLI parameters

| Parameter | Type | Meaning |
|---|---|---|
| `-Path` | string, position 0 | Markdown mode: one `.md` file, or a folder of `.md` files. |
| `-Manifest` | string | Manifest mode: a JSON job list (see schema below). Mutually exclusive with `-Path`; one of the two is required. |
| `-ConfigPath` | string | Explicit config file. Default: `config.cfg` next to the script. |
| `-Index N` | int | Run only job N (1-based catalogue position). 0 = all. |
| `-Limit N` | int | Run at most N jobs (applied after `-Index`). 0 = no limit. |
| `-Model` | string | Override the model id from config. |
| `-AspectRatio` | `16:9` \| `9:16` | Override the default aspect ratio for jobs that don't set their own. |
| `-Delivery` | `inline` \| `uri` | Override the default delivery for jobs that don't set their own. |
| `-ApiKey` | string | Inline API key override. |
| `-Force` | switch | Regenerate even when the output `.mp4` already exists. |
| `-DryRun` | switch | Preview only — no API call, no key required. |
| `-Recurse` | switch | When `-Path` is a folder, include subfolders. |
| `-PreserveInputAudio` | switch | Stage 5 — see *Preserve input audio* below. EXE: `--preserve-input-audio` (also `-PreserveInputAudio`). |

Validation: providing neither `-Path` nor `-Manifest` is a hard error with the usage
hint `Provide -Path <markdown-or-folder> or -Manifest <json>.`

### API key resolution order

1. `-ApiKey` parameter
2. `apiKey` in the resolved config file
3. `$env:GEMINI_API_KEY`
4. `$env:OMNI_API_KEY`

A dry-run needs no key. Generating without a key is a hard error naming all four
sources.

### Input mode A — markdown catalogue

A job is a level-3 heading (`### Title`) followed by a fenced ``` code block holding
the prompt. Identical to the Lyra catalogue rule: fenced blocks not under a `###`
heading are ignored, and a `#`/`##` heading closes the current job (so template/
how-to sections never leak in). Sections without a prompt block are dropped.

Between the heading and/or after the prompt block, a job may carry **directive
lines**. A directive is a labelled line, tolerant of bold and colon placement
(`**Task:** edit`, `Task: edit`, and `**Task**: edit` are all accepted;
labels are case-insensitive):

| Directive | Value | Meaning |
|---|---|---|
| `Task:` | `text_to_video` \| `image_to_video` \| `reference_to_video` \| `edit` | Explicit task (else inferred — see below). |
| `Aspect:` | `16:9` \| `9:16` | Per-job aspect ratio. |
| `Delivery:` | `inline` \| `uri` | Per-job delivery override. |
| `Image:` | file path | The driving image (`image_to_video`), or the first-frame image (`reference_to_video`). |
| `Ref:` | file path | A reference image. Repeatable; order of appearance = `IMAGE_REF_0..N`. Maximum 6 (proven with 3). |
| `Source:` | file path (`.mp4`/`.mov`/`.webm`/`.m4v`) | The user's own video to upload and edit. |
| `Edit-from:` | see *Edit chaining* | Chain an edit from a previous generation. |
| `Split:` | file path (`.mp4`/`.mov`/`.webm`/`.m4v`) | Sequence mode (Stage 3) - see *Sequence mode* below. Cannot combine with `Image`/`Ref`/`Source`/`Edit-from`. |
| `Segment:` | whole seconds | Sequence mode: segment length. Requires `Split`. Default: `config.generationSeconds` (8). |
| `Walk:` | `on` \| `off` | Sequence mode: prompt walking. Requires `Split`. Default `on`. |
| `Vision:` | `on` \| `off` | Sequence mode: last-frame vision description. Requires `Split`. Default `on` when `Walk` resolves on. |

Relative paths resolve against the markdown file's directory.

Example catalogue:

```markdown
# demo-videos-omni-prompts.md

### Neon City Flyover
**Aspect:** 9:16
```
A futuristic city with neon lights and flying cars, cyberpunk style,
continuous unbroken aerial shot. Include a high energy techno beat. No dialogue.
```

### Fish Drawing Comes Alive
**Image:** ./images/fish-drawing.png
```
turn this into realistic footage, using the drawing only as a guide for movement,
do not show the drawing in the final video
```

### Cat And Yarn
**Image:** ./images/first-frame.png
**Ref:** ./images/cat.png
**Ref:** ./images/yarn.png
```
<FIRST_FRAME> A cat <IMAGE_REF_0> playfully batting at a ball of yarn <IMAGE_REF_1>.
```

### Mirror Ripple Edit
**Source:** ./clips/mirror.mp4
```
When the person touches the mirror, make the mirror ripple beautifully like liquid.
Keep everything else the same.
```

### Anime Pass On The Flyover
**Edit-from:** #1
```
Make this video anime. Keep everything else the same.
```
```

### Sequence mode (Stage 3)

> Grounded in `omnotation-dev/stage3-ffmpeg-sequence-plan.md`. New ground -
> unverified against the live API (the original four tasks above were proven
> through the "Testing Scenarios" human quality gate; sequence mode has not).
> The vision text-interaction shape in particular is best-effort, modeled on
> the proven video-interaction shapes rather than confirmed against Gemini.

A `Split:` job names an input video longer than one generation. The CLI splits
it with `ffmpeg` into segments matching the generation duration, queues one
`edit` job per segment (the segment as the uploaded source video), and - when
walking is on - carries scene state forward by extracting the last frame of
each completed segment's output and using it as the next segment's driving
image, optionally described by the model and appended to the next prompt.

```markdown
### Long Take Walkthrough
**Split:** ./clips/long-take.mp4
**Segment:** 8
```
Walk through the scene, continuous unbroken motion, no cuts, natural lighting throughout.
```
```

Execution, in order:

1. **Probe** - `ffprobe` reads the input duration. Segment count =
   `ceil(duration / segmentSeconds)`. A missing/unreadable input or a missing
   `ffmpeg`/`ffprobe` executable fails that job (naming `ffmpegPath`/
   `ffprobePath`) without aborting the rest of the run.
2. **Split** - `ffmpeg -i <input> -c copy -map 0 -segment_time <s> -f segment
   -reset_timestamps 1 <outDir>/segments/NN-<slug>-%03d.mp4`. If stream copy
   exits non-zero (a keyframe-boundary failure), retried once with `-c:v
   libx264 -preset veryfast -c:a aac`. Segments already present are reused
   unless `-Force`.
3. **Queue** - each segment becomes job `NN-<slug>-kkk`, task `edit`,
   inheriting the parent's aspect/delivery/model. `NN` is the parent's
   catalogue position (stable regardless of expansion - `Edit-from #N`
   elsewhere in the same catalogue is unaffected); `kkk` is the segment's
   1-based position, zero-padded to `max(2, digits(segmentCount))`.
   `-Index N` selects every segment of catalogue job `N`; `-Limit` counts
   flattened work items (segments included) after that selection.
4. **Walk** (default on) - before segment `k > 1` runs, the last frame of the
   nearest earlier segment that has actually completed (this run's cache, or
   a disk scan on resume) is extracted with `ffmpeg -sseof -0.05 -i <prev.mp4>
   -frames:v 1 -update 1 <outDir>/frames/NN-<slug>-kkk-first.png` and sent as
   an additional driving image alongside the uploaded segment video. When
   **Vision** is on (default on while walking), that frame is described by
   the model in <=60 words (a `text`-response interaction with the image
   inline, no video) and `Continue from this scene: <description>` is
   appended to the segment's prompt. A segment with no earlier successful
   output (including segment 1) runs independently, image-less. `Walk: off`
   makes every segment independent.
5. **Sidecars** - each segment's sidecar adds a `sequence` object: `{parent,
   index, count, segmentPath, firstFramePath, visionText}` (the last two
   `null` when walking is off or this is segment 1), so a later run can
   resume mid-sequence via the existing skip-existing mechanism.
6. **Dry-run** - lists every planned segment job after probing the input
   (`ffprobe` only; `ffmpeg` and the API are never called), including whether
   its first frame comes from a previous output.

**Known limitation:** `Edit-from #N` referencing a catalogue job that turns
out to be a `Split` job cannot find that job's sidecar (segment filenames
carry a `-kkk` suffix the `#N` lookup doesn't know about) - it fails with
"has not completed in this run", the same message an unresolvable `#N`
produces today.

Manifest mode carries the same fields as `split`, `segmentSeconds`, `walk`,
`vision` (see *Input mode B* below).

### Preserve input audio (Stage 5)

> Grounded in `omnotation-dev/stage5-preserve-input-audio-plan.md`.

An `edit` job sends a local input clip to the model and receives a new video whose
audio the model generates. `-PreserveInputAudio` (EXE: `--preserve-input-audio`,
also `-PreserveInputAudio`; config: `preserveInputAudio`, default `false`) replaces
the returned video's audio with the input clip's own audio, so the output keeps the
picture the model made and the sound the operator supplied. Off by default; without
it nothing changes.

Applies to any job with a local input clip: a `Source:` edit job, or each segment of
a `Split:` job (the segment file is that segment's input clip). Jobs without a local
input clip (text, image, reference, and `Edit-from` jobs) are unaffected; their job
line says `audio: generated (no input clip)`.

The merge runs after a job's output is written, before its sidecar:

1. **Probe** — `ffprobe -v error -select_streams a:0 -show_entries
   stream=codec_type -of csv=p=0 <input>` — has the input clip got an audio stream?
2. **Input has audio** — `ffmpeg -y -i <output.mp4> -i <input> -map 0:v:0 -map 1:a:0
   -c:v copy -c:a aac -b:a 192k -af apad -shortest <output.tmp.mp4>`, then replace
   `<output.mp4>` with it. The video stream is copied untouched; the input's audio is
   trimmed to the video's length if longer, or padded with silence if shorter
   (`apad` with `-shortest`), so the output keeps the generated video's duration.
3. **Input has no audio** — the output keeps the video and drops the generated audio
   (`-map 0:v:0 -c:v copy -an`); the job line says `audio: input (silent input;
   generated audio removed)`.
4. **A failed merge fails that job** — the generated video is left in place as
   `<base>.generated.mp4` (not the final `<base>.mp4` name) and the error names
   ffmpeg's stderr; the totals line counts it; no sidecar is written.
5. **Sidecar** — `audio: { mode: "input" | "generated", inputClip: <path> | null,
   inputHadAudio: boolean }`, present only when `-PreserveInputAudio` is on.

Tooling and dry-run:

- With the option on and at least one job with an input clip, a missing
  `ffmpeg`/`ffprobe` (naming `ffmpegPath`/`ffprobePath`) is a hard error before any
  network call for a real run — so a job never spends API generation only to fail at
  the merge step. Dry-run never invokes ffmpeg (only ffprobe, per job, to check the
  input's audio stream) and so is never gated by this preflight.
- Dry-run lists, per job, `audio: input (<clip>)` or `audio: generated (no input
  clip)`.

### Input mode B — JSON manifest (Claude-extracted)

For anything the markdown parser can't express or read reliably, Claude reads the
source material, extracts each job, and writes a manifest; the CLI is then a pure
inference + delivery engine. Schema:

```json
{
  "sourceFile": "C:/abs/path/to/source.md",
  "outputDir":  "C:/abs/path/to/custom-folder",
  "jobs": [
    {
      "title":       "Mirror Ripple Edit",
      "prompt":      "When the person touches the mirror, make it ripple. Keep everything else the same.",
      "task":        "edit",
      "aspectRatio": "16:9",
      "delivery":    "uri",
      "image":       "images/first-frame.png",
      "references":  ["images/cat.png", "images/yarn.png"],
      "sourceVideo": "clips/mirror.mp4",
      "editFrom":    "#1",
      "split":          "clips/long-take.mp4",
      "segmentSeconds": 8,
      "walk":           true,
      "vision":         true
    }
  ]
}
```

- **`jobs`** (required) — ordered array; order = the `NN-` numbering.
- **`title`** (expected) — becomes the filename after `NN-` + slugify; default `job-N`.
- **`prompt`** (required, non-empty) — a missing/empty prompt is a hard error naming
  the job number.
- **`task`**, **`aspectRatio`**, **`delivery`** (optional) — else inferred/config default.
- **`image`**, **`references`**, **`sourceVideo`**, **`editFrom`** (optional) — same
  semantics as the markdown directives. Relative paths resolve against the manifest
  file's directory.
- **`split`**, **`segmentSeconds`**, **`walk`**, **`vision`** (optional, Stage 3) — same
  semantics as `Split:`/`Segment:`/`Walk:`/`Vision:` in markdown mode; `walk`/`vision`
  are booleans here rather than `on`/`off` strings.
- **`sourceFile`** (required unless `outputDir` given) — output folder derives from it
  exactly as in markdown mode. **`outputDir`** overrides.

### Task inference

When a job has no explicit `task`, infer in this order (first match wins):

1. `editFrom` present → `edit` (chained)
2. `sourceVideo` present → `edit` (upload)
3. `image` **and** ≥1 reference → `reference_to_video`
4. `image` only → `image_to_video`
5. none of the above → `text_to_video`

Contradictions are hard errors at validation time (reported in dry-run too):
`sourceVideo` together with `image`/`references`; `editFrom` together with any media;
an explicit `task` that its media can't satisfy (e.g. `image_to_video` without
`image`); references without an `image`; more than 6 references; an unknown task
value.

### Edit chaining (`Edit-from` / `editFrom`)

All generations send `store: true`, so every output is editable by
`previous_interaction_id`. The `editFrom` value resolves to an interaction id via, in
order:

1. **`#N`** — job N (1-based position) of the *same catalogue/manifest*. Resolution:
   the in-memory interaction id if job N completed earlier in this run, else the
   sidecar JSON of job N's existing output on disk (covers the skip/resume case).
   Forward references (`#N` where N ≥ the current job's position) are a validation
   error.
2. **A path to a sidecar `.json`** — read its `interactionId`.
3. **A path to a generated `.mp4`** — read the sidecar of the same base name beside it.
4. **A literal interaction id** (matches `^v1_[A-Za-z0-9_-]+$` or, tolerant fallback,
   any non-path string) — used directly.

A resolved sidecar missing `interactionId` is a hard error: `That output has no
interaction id to chain from.`

### Output layout, naming, sidecars

- Output folder: next to the source file, named from the first 4
  hyphen/underscore/space-separated words of the source filename, lowercased
  (`demo-videos-omni-prompts.md` → `demo-videos-omni-prompts/`). Manifest
  `outputDir` overrides. Created on first generation (not by dry-run).
- Video: `NN-<slug>.mp4` where `NN` is the 1-based catalogue position, zero-padded to
  `max(2, digits(jobCount))`, and `<slug>` is the slugified title (lowercase, ASCII,
  diacritics stripped, non-alphanumeric runs → single hyphen, trimmed, max
  `slugMaxLength` chars — reuse Lyra's proven `ConvertTo-Slug` verbatim).
- Sidecar: `NN-<slug>.json`, written on success (schema in Technical
  Implementation).
- Debug dump: when a *successful* HTTP response contains no locatable video and
  `saveResponseJson` is true, the raw body is saved as `NN-<slug>-response.json` and
  the job fails with a message pointing at that file.

### Console output

Startup banner, then per-file/per-manifest section, then totals — same visual
grammar as Lyra Producer:

```
Omni Producer
Model: gemini-omni-flash-preview   Aspect: 16:9   Delivery: uri   Mode: MARKDOWN   DRY-RUN

=== demo-videos-omni-prompts.md ===
Jobs: 5   ->   output: C:\...\demo-videos-omni-prompts
  [01] Neon City Flyover              [t2v]  9:16
        -> 01-neon-city-flyover.mp4   (142 chars)
  [02] Fish Drawing Comes Alive       [i2v]  image: fish-drawing.png
        -> 02-fish-drawing-comes-alive.mp4   (118 chars)
  [03] Cat And Yarn                   [r2v]  image + 2 refs
        -> 03-cat-and-yarn.mp4   (76 chars)
  [04] Mirror Ripple Edit             [edit] upload: mirror.mp4 (24.1 MB)
        -> 04-mirror-ripple-edit.mp4   (98 chars)
  [05] Anime Pass On The Flyover      [edit] chain: #1
        -> 05-anime-pass-on-the-flyover.mp4   (54 chars)

Dry run complete. 5 job(s) would be generated.
```

Generation run lines (task tag retained; upload and polling get their own progress
lines; per-job wall-clock and size are printed):

```
  [04] Mirror Ripple Edit             [edit]
        uploading mirror.mp4 (24.1 MB)... done (files/abc123, 41.2s)
        generating...
        polling files/xyz789... ACTIVE (85s)
        OK  04-mirror-ripple-edit.mp4  (18,204 KB, 214.6s)
  [05] Anime Pass On The Flyover      [edit]
        FAILED: <API error message verbatim>

Done. Generated: 4  Skipped: 0  Failed: 1
```

Task tags: `[t2v]`, `[i2v]`, `[r2v]`, `[edit]`. Skips print
`SKIP (exists): <filename>` in yellow; failures print the API's own message verbatim
in red — never paraphrased or smoothed over.

### User flows

**Batch generation:** author/receive a catalogue → `-DryRun` → confirm the plan
(count, tasks, media found) → run → collect `.mp4`s + sidecars → re-run is free
(skip-existing) → `-Force` or `-Index N` to redo specific jobs.

**Iterative editing:** generate once → add a new job with `Edit-from: #1` (or point
at the sidecar/mp4 from an earlier run) → run again — only the new job executes;
the edit chains server-side with no re-upload.

**Own-footage editing:** `Source:` a local video → the CLI uploads via the Files
API, waits for `ACTIVE`, then edits it.

### Edge cases and error states

- **Empty/missing prompt** → hard error naming the job.
- **Referenced media file missing** → reported per-job at validation (dry-run and
  live) as `FAILED: media not found: <path>`; other jobs still run.
- **Unsupported source video** → only `.mp4 .mov .webm .m4v` accepted; > 2 GB (Files
  API cap) rejected before upload: `Video is larger than the 2 GB upload limit.`
- **API error responses** → surface `error.message` from the JSON body verbatim
  (safety blocks and region restrictions carry their reason there). If absent:
  5xx → `Gemini had a server error — retry in a moment.`, else
  `Gemini rejected this request.`
- **Interaction `status` of `failed`/`error`/`cancelled`** in a 200 response →
  job fails with the response's `error.message` (fallback:
  `Gemini reported the generation failed.`).
- **No video found in a successful response** → save raw body (see debug dump),
  fail with pointer to it.
- **File poll returns 404** → `This generation's file expired server-side — retry to
  generate again.`
- **Poll deadline exceeded** (`pollTimeoutSeconds`) → `Generation is taking longer
  than expected — check back later or retry.`
- **Upload processing deadline exceeded** (`uploadPollTimeoutSeconds`) →
  `Video upload processing timed out — retry the job.`
- **Transient network failure** → counts as a retryable attempt (below), message
  `Couldn't reach Gemini — check your connection and retry.`
- **Interrupted run** (Ctrl+C, crash) → nothing partial persists: videos and sidecars
  are written atomically at job completion, so a re-run resumes via skip-existing.
- **Known API limitations** (do not work around; surface the API's message):
  uploaded-video editing unavailable in EEA/Switzerland/UK; no multi-video
  referencing; no system instructions/temperature/negative-prompt fields; audio
  reference upload unsupported.
- **`-PreserveInputAudio` merge failure** (Stage 5) — the job fails, the generated
  video is kept as `<base>.generated.mp4` (not the final name), and the error names
  ffmpeg's stderr; no sidecar is written for that job.
- **`-PreserveInputAudio` with `ffmpeg`/`ffprobe` missing** (Stage 5) — a real run
  with at least one input-clip job fails before any network call, naming
  `ffmpegPath`/`ffprobePath`.

## Technical Implementation

### Architecture

Single-file script, Windows PowerShell 5.1 (`#Requires -Version 5.1`,
`Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`). Force TLS 1.2
at startup exactly as Lyra does. No modules, no dependencies beyond built-in
`Invoke-RestMethod`/`Invoke-WebRequest` and .NET base classes.

Function map (mirroring the proven Lyra layout):

```
Get-OmniConfig            config load + defaults merge
ConvertTo-Slug            (verbatim from Lyra)
Get-OutputFolderName      (verbatim from Lyra)
Get-Prop                  case/style-tolerant property fetch (verbatim from Lyra)
Resolve-ApiError          extract error.message from ErrorDetails (verbatim pattern)
Get-VideoJobs             markdown parser: ### boundary + fenced prompt + directives
Read-OmniManifest         manifest load + normalization + validation
Resolve-JobTask           inference + contradiction checks
Resolve-EditFrom          #N / sidecar / mp4 / literal-id resolution
Get-MediaMime             extension → mime (image + video tables below)
Invoke-OmniFilesUpload    Files API resumable upload + ACTIVE wait, returns uri
Build-OmniRequestBody     per-task JSON body builder
Invoke-OmniInteraction    POST /interactions with timeout
Find-VideoItem            steps[] scan + output_video fallback + recursive scan
Find-TextItem             steps[] scan + output_text fallback (Stage 3: vision description)
Wait-OmniFileActive       poll GET /files/{id} until ACTIVE/FAILED/deadline
Invoke-OmniDownload       authenticated download to file
Invoke-OmniTool           (Stage 3) run ffmpeg/ffprobe, capture stdout/stderr/exit code
Get-VideoDuration         (Stage 3) ffprobe duration read
Split-OmniVideo           (Stage 3) ffmpeg segment split, copy->re-encode fallback
Get-LastFrame             (Stage 3) ffmpeg last-frame extraction
Get-FrameDescription      (Stage 3) vision text interaction, <=60 words
Expand-OmniSequences      (Stage 3) Split job -> per-segment edit jobs, before the queue
Test-AudioTools           (Stage 5) preflight: ffmpeg/ffprobe both resolvable
Test-ClipHasAudio         (Stage 5) ffprobe: does the input clip have an audio stream
Merge-ClipAudio           (Stage 5) ffmpeg: replace/drop the output's audio per the input clip
Invoke-JobQueue           selection, skip, retry, delivery, sidecars, totals
```

### Config file — `config.cfg`

JSON content; lives beside the script; the literal model name lives here so a future
model rename is a one-line config edit, never a script edit. Missing file → warning +
built-in defaults (identical values). Unknown keys ignored; known keys merged over
defaults. Template (this is the authoritative copy — the live `config.cfg` is
gitignored because it holds the real key):

```json
{
  "apiKey": "AIza...your-google-gemini-api-key-here...",
  "model": "gemini-omni-flash-preview",
  "endpointBase": "https://generativelanguage.googleapis.com/v1beta",
  "uploadEndpointBase": "https://generativelanguage.googleapis.com/upload/v1beta/files",
  "defaultAspectRatio": "16:9",
  "defaultDelivery": "uri",
  "store": true,
  "timeoutSeconds": 600,
  "pollIntervalSeconds": 5,
  "pollTimeoutSeconds": 600,
  "uploadPollIntervalSeconds": 3,
  "uploadPollTimeoutSeconds": 300,
  "maxRetries": 2,
  "delayBetweenJobsSeconds": 2,
  "saveResponseJson": true,
  "saveJobSidecar": true,
  "slugMaxLength": 80,
  "ffmpegPath": "ffmpeg",
  "ffprobePath": "ffprobe",
  "generationSeconds": 8,
  "preserveInputAudio": false
}
```

| Key | Meaning |
|---|---|
| `model` | Literal model id sent in every request. |
| `endpointBase` | Base for `/interactions` and `/files/...`. |
| `uploadEndpointBase` | Files API resumable-upload start URL. |
| `defaultAspectRatio` / `defaultDelivery` | Used when a job doesn't specify its own; CLI flags override these, per-job directives override everything. |
| `store` | Sent as `store` on every interaction. Must stay `true` for edit chaining to work (`store:false` outputs cannot be chained). |
| `timeoutSeconds` | HTTP timeout for the synchronous `/interactions` POST (generation runs inside this call — minutes are normal). |
| `pollIntervalSeconds` / `pollTimeoutSeconds` | URI-delivery polling cadence/deadline (proven: 5 s / 600 s). |
| `uploadPollIntervalSeconds` / `uploadPollTimeoutSeconds` | Upload-processing polling cadence/deadline (proven: 3 s / 300 s). |
| `maxRetries` | Extra attempts per job after the first failure. Backoff before retry N: `min(30, 3·N)` seconds. |
| `delayBetweenJobsSeconds` | Pause between jobs. |
| `saveResponseJson` | Save the raw body of a video-less success response. |
| `saveJobSidecar` | Write the per-video sidecar JSON (must stay `true` for cross-run chaining). |
| `slugMaxLength` | Filename slug cap. |
| `ffmpegPath` / `ffprobePath` | Stage 3: executable name or full path, resolved via PATH if bare. Only needed by `Split:` jobs. |
| `generationSeconds` | Stage 3: default `Segment:` length in seconds when a `Split:` job doesn't set its own. |
| `preserveInputAudio` | Stage 5: turns on `-PreserveInputAudio` for every run (the flag turns it on regardless). |

### Gemini Interactions API — request building

`POST {endpointBase}/interactions` with headers `x-goog-api-key: <key>` and
`Content-Type: application/json`. Common body skeleton (every job):

```json
{
  "model": "<config.model>",
  "input": <task-specific — see below>,
  "generation_config": { "video_config": { "task": "<task>" } },
  "response_format": {
    "type": "video",
    "aspect_ratio": "16:9 | 9:16",
    "delivery": "inline | uri"
  },
  "background": false,
  "store": true,
  "stream": false
}
```

`delivery` is always sent explicitly with one of the two literals — the proven
codebase does this for both values. `previous_interaction_id` is added at the top
level only for chained edits.

**Live-API amendments (verified 2026-08-03 during the quality gates; these
supersede the Rust blueprint where they conflict):**

- **Chained edits must omit `generation_config` entirely.** The API rejects the
  combination with `previous_interaction_id is not allowed when video task is
  set.` (400). The Rust client sends both, so its chained-edit path would hit the
  same rejection against the current API — the docs' own stateful-editing example
  sends neither.
- **All `edit` jobs omit `aspect_ratio` from `response_format`** (send only
  `type` and `delivery`) — an edit inherits its aspect from the source video, and
  the docs' edit examples never include it. Sidecars record `aspectRatio: null`
  for edits accordingly.
- **Uploaded-video edits reference the upload as `{type:"video", uri, mime_type}`,
  not `{type:"document", uri}`.** The SDK docs' `document` item is SDK sugar; the
  REST endpoint doesn't count it as a video and rejects with `Exactly one input
  video is required for edit task.`
- **The EEA/Switzerland/UK restriction on uploaded-video editing surfaces as a
  generic policy block** (`Input blocked: The prompt contains sensitive words…`)
  regardless of the actual prompt text — it fires even on the docs' own canonical
  edit prompts, while chained edits of model-generated videos keep working in the
  same region. Don't chase "sensitive words" in an innocuous prompt on an
  upload-edit; suspect the region first.

Per-task `input` (all shapes verbatim from the proven `build_request_body`):

- **`text_to_video`**
  ```json
  [ { "type": "text", "text": "<prompt>" } ]
  ```
- **`image_to_video`** — image first, then text:
  ```json
  [
    { "type": "image", "data": "<base64>", "mime_type": "image/png" },
    { "type": "text", "text": "<prompt>" }
  ]
  ```
- **`reference_to_video`** — the `image` (first-frame) item first — it binds
  `<FIRST_FRAME>` — then each reference in order (binding `<IMAGE_REF_0..>` by
  array position), then the text item.
- **`edit`, chained** (`previous_interaction_id` set) — input is the **plain prompt
  string**, not an array:
  ```json
  "Make this video anime. Keep everything else the same."
  ```
- **`edit`, uploaded video** — upload first (below), then:
  ```json
  [
    { "type": "video", "uri": "<files-api-uri>", "mime_type": "video/mp4" },
    { "type": "text", "text": "<prompt>" }
  ]
  ```
  Never inline base64 video into the request body — always the Files API.
  **Stage 3 sequence mode (unverified):** a walked segment (`k > 1`, `Walk` on,
  a driving frame available) prepends the previous segment's last frame as an
  `image` item before the `video` item: `[ {image}, {video}, {text} ]`. This
  reuses the same `image` item shape as `image_to_video`/`reference_to_video`
  above; it has not been confirmed against the live API.

Image `mime_type` by extension: `.png` → `image/png`, `.jpg`/`.jpeg` →
`image/jpeg`, `.webp` → `image/webp`; anything else is a validation error. Image
bytes are read from disk and base64-encoded per request (no caching needed).

### Response parsing

Parse the body as JSON (a 200 with an unparseable body is treated as
video-less — debug dump path). Then:

1. Capture top-level `id` (the interaction id) when present.
2. If top-level `status` ∈ {`failed`, `error`, `cancelled`} → fail with
   `error.message` (fallback message per Edge cases).
3. Locate the video item — three strategies, in order (verbatim from the proven
   `find_video_item`):
   1. Walk `steps[]`; in each step's `content[]`, note every object with
      `type == "video"` and a `data` or `uri` key; keep the **last** hit
      (model_output follows user_input).
   2. Fallback: top-level `output_video` object with `data` or `uri`.
   3. Fallback: tolerant recursive scan of the whole document for the first object
      with `type == "video"` and `data`/`uri`.
4. `data` present → base64-decode → the MP4 bytes (inline delivery done).
5. `uri` present → extract the file id: substring after the last `files/`, cut at
   the first `?`, `#`, or `:` → URI delivery, go poll.
6. Neither → debug dump + fail.

### Vision description — sequence-walk frames (Stage 3, unverified)

Between two walked segments, a `text`-response interaction describes the
driving frame:

```json
{
  "model": "<config.model>",
  "input": [
    { "type": "image", "data": "<base64>", "mime_type": "image/png" },
    { "type": "text", "text": "Describe this image in at most 60 words, focusing on scene, subject, and action, to help continue a video from this frame." }
  ],
  "response_format": { "type": "text" },
  "background": false,
  "store": false,
  "stream": false
}
```

Parsed the same way as a video response but looking for `{type:"text"}`
instead of `{type:"video"}`: walk `steps[]` keeping the last `text` hit
(model_output follows user_input), else fall back to a top-level
`output_text` field. An empty/unreadable description is tolerated — the
segment still runs, just without the `Continue from this scene: ...` clause.
`store: false` because the description itself is never chained from.

### URI delivery — poll and download

Poll `GET {endpointBase}/files/{fileId}` (header `x-goog-api-key`) every
`pollIntervalSeconds`, deadline `pollTimeoutSeconds`:

- HTTP 404 → terminal failure (expired — message per Edge cases).
- Other non-2xx → terminal failure with `error.message`.
- `state == "ACTIVE"` → download from `downloadUri` (accept `download_uri` too)
  when present, else the default URL
  `{endpointBase}/files/{fileId}:download?alt=media`, with the `x-goog-api-key`
  header, streamed to the output file (`Invoke-WebRequest -OutFile`).
- `state == "FAILED"` → terminal failure with the file's `error.message`
  (fallback `Generation failed server-side.`).
- Anything else (including a transient poll error) → keep polling until deadline.

### Files API — resumable upload (edit-upload jobs)

Validation first: extension ∈ {mp4, mov, webm, m4v}; size ≤ 2 GB. Video mime by
extension: `.mov` → `video/quicktime`, `.webm` → `video/webm`, `.m4v` →
`video/x-m4v`, else `video/mp4`.

1. **Start** — `POST {uploadEndpointBase}` with headers
   `x-goog-api-key`, `X-Goog-Upload-Protocol: resumable`,
   `X-Goog-Upload-Command: start`,
   `X-Goog-Upload-Header-Content-Length: <bytes>`,
   `X-Goog-Upload-Header-Content-Type: <mime>`, JSON body
   `{"file": {"display_name": "<filename>"}}`. Read the session URL from the
   `x-goog-upload-url` **response header** (PS 5.1: `$resp.Headers['x-goog-upload-url']`
   from `Invoke-WebRequest`). Missing header → `Upload session couldn't be started.`
2. **Upload + finalize** — `POST <session-url>` with headers
   `X-Goog-Upload-Offset: 0`, `X-Goog-Upload-Command: upload, finalize`, body =
   the raw file bytes (`[System.IO.File]::ReadAllBytes`; PowerShell sets
   Content-Length). Parse the JSON response's `file.uri`.
3. **Wait for processing** — extract the file id from the uri (same rule as above)
   and poll `GET {endpointBase}/files/{id}` every `uploadPollIntervalSeconds` until
   `ACTIVE` (return the uri), `FAILED` (fail with its message), or the
   `uploadPollTimeoutSeconds` deadline.

Uploads are fresh per run — the Files API TTL is 48 h, so cached handles are not
reused (matching the proven implementation).

### Sidecar JSON — data model

Written next to the video on success (when `saveJobSidecar` is true):

```javascript
{
  "title": string,            // catalogue title
  "index": number,            // 1-based catalogue position
  "task": "text_to_video" | "image_to_video" | "reference_to_video" | "edit",
  "prompt": string,
  "model": string,            // model id actually used
  "aspectRatio": "16:9" | "9:16",
  "delivery": "inline" | "uri",
  "interactionId": string | null,  // from the response `id` — the edit-chain handle
  "fileId": string | null,         // set for uri delivery
  "previousInteractionId": string | null,  // set for chained edits
  "image": string | null,          // resolved absolute path, as used
  "references": string[],          // resolved absolute paths, order sent
  "sourceVideo": string | null,    // resolved absolute path, if uploaded
  "videoFile": string,             // "NN-<slug>.mp4" (relative to sidecar)
  "createdAt": string,             // ISO 8601
  "elapsedSeconds": number,        // wall clock incl. polling
  "status": "completed",
  "sequence": {                    // Stage 3: present only on a Split job's segments
    "parent": number,              // the Split job's catalogue index (NN)
    "index": number,                // 1-based segment position (kkk)
    "count": number,                // segments in this sequence
    "segmentPath": string,          // the split .mp4 this segment uploaded/edited
    "firstFramePath": string | null,// extracted driving frame, null for segment 1 or Walk: off
    "visionText": string | null     // frame description, null when Vision is off or empty
  } | undefined,
  "audio": {                       // Stage 5: present only when -PreserveInputAudio is on
    "mode": "input" | "generated",  // "input" only when this job had a local input clip
    "inputClip": string | null,     // resolved absolute path, null when no input clip
    "inputHadAudio": boolean        // false when there was no input clip, or it was silent
  } | undefined
}
```

`interactionId` null (response had no `id`) is tolerated at write time but makes the
output unchainable — `Resolve-EditFrom` reports it then.

### Generation engine

Stage 3: every `Split` job is expanded into its segment jobs (`Expand-OmniSequences`
/ `ExpandSequences`) before selection or numbering, using the pre-expansion
catalogue count for `NN` width so `Edit-from #N` and non-sequence job numbering
never shift. Selection (`-Index`, then `-Limit`) then operates on the full
(expanded) numbered set so filenames are stable regardless of selection —
identical to Lyra, extended so `-Index N` selects every segment of catalogue
job `N` and `-Limit` counts flattened work items. Per selected job:

1. Skip if `NN-<slug>.mp4` exists and not `-Force` (sidecar presence not required).
2. Validate media, resolve `editFrom`, upload source video if needed (upload
   failures count as job attempts and are retried).
3. Attempt loop: up to `1 + maxRetries` attempts; on failure print
   `attempt N failed: <msg> - retrying in Xs`, backoff `min(30, 3·N)` s. All failure
   types are retryable except (a) validation errors (missing media, contradictions,
   unresolvable `editFrom`), which fail immediately without retry, and (b)
   deterministic input-safety blocks (message matching `Input blocked` /
   `Prohibited Use policy`) — the same input can never pass on retry, so retrying
   only wastes requests.
4. On success write video bytes, then sidecar, print OK line, sleep
   `delayBetweenJobsSeconds`.

Totals: `Planned` (dry-run) or `Generated / Skipped / Failed`. Exit code 0 when
nothing failed; 1 when any job failed (so callers can gate on it).

### PowerShell 5.1 implementation notes

- Force TLS 1.2 via `[Net.ServicePointManager]::SecurityProtocol` in a try/catch,
  exactly as Lyra does.
- `Invoke-RestMethod` for all JSON calls with `-TimeoutSec` from config;
  `Invoke-WebRequest` where response headers (`x-goog-upload-url`) or `-OutFile`
  streaming are needed.
- Error bodies: Gemini returns JSON error details in
  `$_.ErrorDetails.Message` — parse and surface `error.message` (the Lyra
  `Resolve-ApiError` pattern verbatim).
- Property access on parsed JSON must go through the tolerant `Get-Prop` helper
  (`downloadUri` vs `download_uri`, `mimeType` vs `mime_type`).
- Keep the script pure ASCII so it parses under 5.1 regardless of file encoding
  (Lyra's proven constraint — non-ASCII expansions are written as `[char]0x..`).
- Base64 of images happens in memory (`[Convert]::ToBase64String`); video bytes are
  never base64'd (Files API only), so peak memory stays ≈ the source video size.

## Testing Scenarios (the human quality gate)

Run in order; each gate must pass by human inspection of the artifact before the EXE
port begins:

1. **Dry-run integrity** — the 5-job example catalogue above dry-runs to exactly 5
   jobs with the tags/paths shown, flags a deliberately missing `Ref:` path, and
   makes no network calls (verify: works with no key configured).
2. **t2v inline** — 1 job, `Delivery: inline`: MP4 plays, sidecar has
   `interactionId`, exit code 0.
3. **t2v uri** — same prompt, `uri`: polling lines appear, file downloads, plays.
4. **i2v** — a real image animates per prompt.
5. **r2v** — first-frame + 2 refs; output starts on the first frame and uses the
   referenced subjects.
6. **edit-upload** — a short local MP4 uploads (progress line), edit applies,
   unedited elements preserved.
7. **edit-chain** — `Edit-from: #N` in the same file on a second run: only the new
   job runs (skips print), chain works without re-upload.
8. **Failure surfacing** — a prompt engineered to safety-block prints the API's own
   message and exits 1; a fake key prints the auth error verbatim.
9. **Resume** — interrupt a multi-job run; re-run completes only the missing jobs.
10. **Manifest parity** — the same 5 jobs expressed as a manifest produce
    byte-identical file names and equivalent results.

Stage 3 (sequence mode) has its own free, dry-run-only smoke test rather than a
live-API gate (it has not been proven against the live API — see *Sequence
mode* above):

11. **Sequence dry-run** — `omni-producer/tests/Test-Sequence.ps1` generates a
    20 s silent clip with `ffmpeg` (`testsrc`, 640x360, 24 fps), dry-runs
    `sequence-omni-prompts.md` (`Split:` that clip, `Segment: 8`) against it,
    and asserts exactly 3 planned segment jobs (`ceil(20/8) = 3`) with exit 0.
12. **Preserve-input-audio dry-run + merge** (Stage 5) —
    `omni-producer/tests/Test-PreserveInputAudio.ps1` dry-runs
    `preserve-audio-omni-prompts.md` under `--preserve-input-audio` and asserts the
    right `audio:` line per job, then runs the documented merge commands directly
    against a stand-in "returned" video and asserts with `ffprobe` that a tone
    clip's audio survives the merge (duration within 0.1 s), a silent clip's output
    has no audio stream, and the video stream is untouched in both cases. Free,
    no API key, no network call.

## Performance Goals

- Dry-run of a 50-job catalogue: < 2 s, zero network.
- Generation wall-clock is API-bound (~30 s–several min/video); the script adds only
  polling latency (≤ `pollIntervalSeconds` per completed poll cycle).
- Sequential by design — one interaction in flight; the API meters spend, and
  sequencing keeps `#N` chaining semantics trivial.

## Extended Features (explicitly out of scope for v1)

- Native `OmniProducer.exe` port — flag-compatible, same config, built only after
  the script passes every gate above.
- The `omni-producer` skill — authored last, from the proven behavior.
- Parallel workers, resolution/duration controls (not in the current API),
  audio-reference inputs (API rejects them), YouTube sources (unsupported),
  video interpolation/extension (unsupported).
