---
artifact: Features.md
standard_version: 1.0
project: Omni Producer
project_version: 1.0.0
last_curated: 2026-09-21
curation_trigger: scan
source_of_truth: true
contains_code: false
---

> **Maturity note:** most of this manifest describes behavior proven against
> the live API through a ten-scenario human quality gate (see Distribution).
> Entries tagged `unproven` are implemented and dry-run-tested but have not
> yet been exercised against the live API — treat their exact behavior as
> provisional until they are.

> This file is the public source of truth for Omni Producer. It is deliberately
> code-free and redacted: it states what the system does, not how. The absence of
> internal detail here does not imply the absence of a capability.

## 1. System Summary

Omni Producer is a zero-UI Windows command-line tool that turns a plain-text
"video job catalogue" into finished `.mp4` videos on disk by driving the Gemini Omni
Flash video generation and editing API. A user writes video prompts as headed
sections of a markdown file (or hands the tool a JSON job manifest), previews the
whole batch for free, then generates every video sequentially with skip-existing,
retry and a totals summary. Every finished video is written beside a small JSON
sidecar that remembers its server-side interaction, so any later job can edit that
video conversationally without re-uploading anything. A job may also name a source
video longer than one generation; the tool splits it into duration-matched segments
and generates the sequence as a continuity-aware batch (see *Sequence generation*).
It ships as two flag-identical implementations, a script and a self-contained native
executable, plus an agent-orchestration skill layered over both.

## 2. Stack Profile

- **Platform:** Windows desktop, x64. No installer; the executable is a single
  self-contained file, and the script needs only the shell that ships with Windows.
- **Reference implementation:** a shell-script runtime native to stock Windows, with
  no external module dependencies.
- **Native port:** a managed, compiled, self-contained single-file executable built
  from a typed language in the .NET family; flag-for-flag identical to the script.
- **Backend / datastore:** none. The tool is a stateless client of a hosted
  generative-video API over HTTPS. All persistent state is plain files beside the
  user's inputs (videos, JSON sidecars, one JSON config file).
- **External services:** one hosted multimodal API (an interactions endpoint for
  generation and editing; a resumable file-upload endpoint for user footage).
- **Local tooling:** an ffmpeg-class media-processing toolchain, invoked as a
  subprocess, resolved from the system path or a configured location. Required only
  for sequence-mode jobs (see *Sequence generation*); every other feature has no
  local media-tooling dependency. `unproven`
- **Agent layer:** a Claude Code skill that orchestrates the CLI, published
  separately from this repository.

## 3. Feature Manifest

### Input: catalogue authoring
- **Markdown job catalogue** — each level-3 heading is one video; the fenced code
  block beneath it is the prompt. Higher-level headings close a job, so template and
  how-to sections never leak into the batch. `stable`
- **Per-job directive lines** — labelled lines under a heading set the task, aspect
  ratio, delivery mode, driving image, reference images, source video, edit origin,
  or (see *Sequence generation*) a long-form source video and its sequence options.
  Bold and colon placement are tolerated and labels are case-insensitive. `stable`
- **Folder mode** — point the tool at a folder and it runs every markdown catalogue
  in it, optionally recursing into subfolders. `stable`
- **JSON manifest mode** — an alternative, machine-authored job list for source
  material the markdown parser cannot read. Mutually exclusive with markdown mode;
  same job semantics. `stable`
- **Relative media paths** — image and video paths resolve against the catalogue or
  manifest file's own folder. `stable`

### Generation tasks
- **Text-to-video** — a prompt alone produces a video with generated audio. `stable`
- **Image-to-video** — a prompt plus one image animates that image. `stable`
- **Reference-to-video** — a prompt plus a first-frame image plus up to six
  reference images (characters, products, style) produces a video starring the
  referenced subjects; references are addressed in the prompt by ordinal
  placeholders. `stable`
- **Edit of a previous generation (chained edit)** — a prompt plus a pointer to any
  earlier output re-works that video server-side with full context of what was made
  before, with no re-upload. `stable`
- **Edit of the user's own footage (upload edit)** — a prompt plus a local video file
  uploads the footage and applies the edit. `stable`
- **Automatic task inference** — when no task is stated, the tool infers it from the
  media present; an explicit task is honoured when it is consistent with its media. `stable`

### Sequence generation (long-form input splitting)
- **Automatic duration-matched splitting** — a job may name a source video longer
  than one generation; the tool splits it into segments sized to the generation
  duration and generates one job per segment automatically, in order. `unproven`
- **Configurable segment length** — segment length is set per job or falls back to
  a configured default. `unproven`
- **Prompt walking with last-frame continuity** — by default, each segment after
  the first is driven by the last frame of the previous segment's finished output,
  so a multi-segment sequence stays visually continuous without the author writing
  per-segment prompts; can be turned off per job to make segments independent. `unproven`
- **Automatic scene description** — by default, the carried-forward frame is
  described by the model and folded into the next segment's prompt, so continuity
  is reinforced in text as well as image; can be turned off independently of
  walking. `unproven`
- **Sequence-aware batch selection** — running a single job or a limited number of
  jobs counts expanded segments individually, without shifting the numbering of
  other jobs in the same catalogue. `unproven`
- **Resumable sequences** — an interrupted or re-run sequence picks up continuity
  from whichever segment last completed, whether that was earlier in the current
  run or a previous one; reuses the same skip-existing mechanism as ordinary jobs. `unproven`
- **Segment-level provenance** — each segment's sidecar records its position in the
  sequence and, when walking produced one, the continuity frame and its
  description. `unproven`

### Edit chaining
- **Same-file chaining** — a job may point at an earlier job in the same catalogue
  by its number. Forward references are rejected. `stable`
- **Cross-run chaining** — a job may point at a sidecar file, a generated video
  file, or a literal interaction id from any previous run, days or weeks later. `stable`
- **Resume-aware resolution** — when the referenced job was skipped this run because
  its output already exists, the chain resolves through the sidecar on disk. `stable`
- **Sidecar memory** — every successful video gets a JSON sidecar recording the
  interaction that produced it; this is the chaining handle. `stable`

### Delivery
- **URI delivery with polling** — the default: the tool polls the server-side file
  until it is ready, then downloads it, printing progress lines. `stable`
- **Inline delivery** — for small videos the encoded bytes come back in the response
  and are decoded straight to disk. `stable`
- **Per-job and per-run delivery choice** — a directive sets one job's delivery; a
  flag or config sets the run default. `stable`

### Run control
- **Free dry-run** — prints the full numbered plan (task tag, media, output name,
  prompt length), validates every referenced file, and makes no network call. Needs
  no API key. `stable`
- **Single-job and limited runs** — run only job N, or at most N jobs. `stable`
- **Skip-existing (free re-runs)** — a job whose output video already exists is
  skipped, so re-running a catalogue costs nothing. A force flag regenerates. `stable`
- **Sequential engine with retry** — one interaction in flight at a time; failed
  attempts retry with short backoff, except validation errors and deterministic
  safety blocks, which fail immediately. `stable`
- **Atomic outputs and resume** — videos and sidecars are written only on completion,
  so an interrupted run leaves nothing partial and a re-run finishes the missing
  jobs. `stable`
- **Pause between jobs** — a configurable delay separates consecutive generations. `stable`

### Configuration
- **JSON config file** — lives beside the tool; sets the model id, endpoint bases,
  default aspect ratio and delivery, timeouts, polling cadences, retry count, job
  delay, sidecar and debug-dump switches, filename slug length, and (see *Sequence
  generation*) the media-tooling location and default segment length. A missing
  file falls back to built-in defaults with a warning. `stable`
- **Layered overrides** — per-job directives override command-line flags, which
  override the config file, which overrides built-in defaults. `stable`
- **API key resolution** — key taken from a flag, then the config file, then either
  of two environment variables; generating without any is a hard error naming all
  four sources. `stable`
- **Config template** — a shipped template with a placeholder key is copied to
  create the live config, which is excluded from version control. `stable`

### Output
- **Deterministic naming** — output folder derived from the source file's name;
  videos named by zero-padded catalogue position plus a slug of the job title. `stable`
- **Sidecar JSON per video** — see Integration Surfaces. `stable`
- **Debug dump** — when a successful response contains no video, the raw body is
  saved beside the outputs and the job fails pointing at it. `stable`

### Console and error surfacing
- **Structured console output** — a startup banner, a per-file section with numbered
  job lines and task tags, per-job status lines (OK / SKIP / FAILED) with size and
  wall-clock, and a final totals line. `stable`
- **Verbatim API errors** — failures print the API's own error message, never
  paraphrased; safety blocks and region restrictions surface their real reason. `stable`
- **Named failure states** — expired server-side file, poll deadline, upload
  processing deadline, unreachable network, and generation-failed each produce a
  distinct, actionable message. `stable`
- **Exit code gating** — exit 0 when nothing failed, 1 when any job failed. `stable`

### Validation
- **Pre-flight media check** — missing images or videos are reported per job at
  validation (dry-run and live); other jobs still run. `stable`
- **Contradiction detection** — source video together with images, edit origin
  together with any media, an explicit task its media cannot satisfy, references
  without a first frame, too many references, and unknown task values are hard
  errors reported before any spend. `stable`
- **Upload guard** — only supported video extensions are accepted, and files over
  the upload size cap are rejected before any transfer begins. `stable`

### Distribution
- **Native executable** — a single self-contained Windows exe published on GitHub
  Releases with a checksum in the release notes; reproducible from source. `stable`
- **Script fallback** — the reference script runs on stock Windows with nothing to
  install; flag-identical to the exe. `stable`
- **Agent orchestration skill** — a Claude Code skill that extracts jobs, previews
  with a dry-run, confirms spend scope, and drives either implementation. `stable`
- **Specification-first delivery** — the complete behavioural spec ships in the
  repository; both implementations were generated from it and proven against the
  live API through a ten-scenario human quality gate. `stable`

## 4. Capabilities & Limits

- **Aspect ratios:** landscape (16:9) and portrait (9:16). Edits inherit the source
  video's aspect and cannot set one.
- **Reference images:** up to six per job, plus one first-frame image. Formats: PNG,
  JPG, WEBP.
- **Uploadable source video:** MP4, MOV, WEBM, M4V; up to 2 GB per file. Uploads are
  fresh per run (server-side upload handles are short-lived and not reused).
- **Delivery:** URI (default, any size) or inline (small videos only).
- **Concurrency:** strictly sequential by design; one generation in flight.
- **Timing:** dry-run of a fifty-job catalogue completes in about two seconds with
  zero network; generation is API-bound at roughly thirty seconds to several minutes
  per video, with polling adding at most one poll interval.
- **Cost model:** every generation is metered by the API provider; dry-runs and
  skip-existing re-runs are free.
- **Retry policy:** a configurable number of extra attempts with capped backoff;
  safety blocks and validation errors are never retried.
- **Known provider restrictions (surfaced, not worked around):** editing uploaded
  footage is unavailable in the EEA, Switzerland and the UK, and appears there as a
  generic policy block regardless of prompt; chained edits of generated videos still
  work in those regions. No multi-video referencing, no audio-reference inputs, no
  resolution or duration controls, no remote-URL video sources, no interpolation or
  extension.
- **Watermarking:** all generated videos carry the provider's invisible watermark.
- **Chaining prerequisite:** outputs are chainable only when the store setting is on
  (the default) and sidecars are being written (the default).
- **Sequence mode maturity (`unproven`):** implemented and covered by a free,
  dry-run-only smoke test, but not yet exercised against the live API — unlike the
  four generation tasks and edit chaining above, it has not passed a live quality
  gate. Sequence mode also needs a local media-processing toolchain; no other
  feature does.

## 5. Integration Surfaces

### Command-line interface
Both implementations accept the same flags. Positional: the markdown path. Named:
manifest path, config path, single job index, job limit, model override, aspect
ratio override, delivery override, API key override, force, dry-run, and recurse.
Exactly one of the markdown path or the manifest path is required.

### Markdown catalogue grammar
A job is a level-3 heading followed by a fenced code block holding the prompt.
Directive lines between the heading and the block, or after the block, carry these
labels: `Task`, `Aspect`, `Delivery`, `Image`, `Ref` (repeatable), `Source`,
`Edit-from`, and (`unproven`) `Split`, `Segment`, `Walk`, `Vision`. Files matching
the `*-omni-prompts.md` naming convention are the recognised catalogue form.

### JSON manifest (input contract)
A machine-authored producer must supply this shape:

```json
{
  "sourceFile": "string",          // absolute path; required unless outputDir given
  "outputDir":  "string",          // optional; overrides the derived output folder
  "jobs": [                        // required; order defines the NN- numbering
    {
      "title":       "string",     // expected; slugified into the filename
      "prompt":      "string",     // required, non-empty
      "task":        "text_to_video | image_to_video | reference_to_video | edit",  // optional
      "aspectRatio": "16:9 | 9:16",       // optional
      "delivery":    "inline | uri",      // optional
      "image":       "string",            // optional path
      "references":  ["string"],          // optional paths, max 6
      "sourceVideo": "string",            // optional path
      "editFrom":    "string",            // optional: "#N", sidecar path, video path, or interaction id
      "split":          "string",         // optional path; unproven, see Sequence generation
      "segmentSeconds": 0,                // optional; unproven
      "walk":           true,             // optional; unproven
      "vision":         true              // optional; unproven
    }
  ]
}
```
Relative paths resolve against the manifest file's directory.

### Sidecar JSON (output contract)
Written beside each video; a downstream consumer reads it to chain edits or to
index outputs. Fields an integrator may rely on:

```json
{
  "title": "string",
  "index": 0,                          // 1-based catalogue position
  "task": "text_to_video | image_to_video | reference_to_video | edit",
  "prompt": "string",
  "model": "string",
  "aspectRatio": "16:9 | 9:16 | null", // null for edits
  "delivery": "inline | uri",
  "interactionId": "string | null",    // the edit-chain handle; null means unchainable
  "previousInteractionId": "string | null",
  "videoFile": "string",               // video filename relative to the sidecar
  "createdAt": "ISO-8601",
  "elapsedSeconds": 0,
  "status": "completed",
  "sequence": {                        // present only on a sequence segment; unproven
    "parent": 0,                       // the source job's catalogue position
    "index": 0,                        // this segment's 1-based position
    "count": 0,                        // segments in the sequence
    "segmentPath": "string",
    "firstFramePath": "string | null",
    "visionText": "string | null"
  }
}
```

### Exit codes
0 when every selected job succeeded or was skipped; 1 when any job failed or the
invocation was invalid.

### Agent skill
The published skill is the intended surface for assistant-driven use: it extracts
a manifest from free-form source material, runs a dry-run, confirms spend with the
user, and invokes the CLI. It consumes and produces exactly the contracts above.

## 6. Extension Notes

- **Manifest mode is the extension seam.** Any upstream tool or agent that can emit
  the manifest shape can drive the full engine without touching the markdown parser.
- **Sidecars are the cross-tool handoff.** Downstream editors, galleries or pipelines
  can index outputs and originate chained edits from sidecars alone.
- **Model and endpoints are configuration, not code.** A provider model rename is a
  one-line config change.
- **The spec is the build input.** Both implementations were generated from the
  shipped specification; a new port targets the spec, then the ten-scenario quality
  gate, then the release.
- **Explicitly out of scope for this version:** parallel workers (sequencing is
  deliberate), resolution and duration controls, audio references, remote video
  sources, interpolation and extension. Most are blocked on the provider API rather
  than on this tool.
- **Sequence generation is the newest surface and the least proven.** It reuses the
  edit-upload and sidecar mechanics rather than adding a new task type, so it
  inherits their error handling and chaining limits; a job referencing a sequence's
  output by its catalogue number, rather than a specific segment, is not yet
  resolvable.

## 7. Glossary

- **Catalogue** — a markdown file of headed video jobs; the primary input.
- **Job** — one video to generate or edit: a title, a prompt, and optional media.
- **Directive** — a labelled line under a job heading that sets one job option.
- **Manifest** — the JSON equivalent of a catalogue, usually machine-authored.
- **Sidecar** — the JSON file written beside each output video, holding its
  interaction id and provenance.
- **Interaction id** — the provider's handle for a completed generation; the key
  that lets a later job edit it without re-uploading.
- **Chained edit** — an edit whose source is a previous generation, referenced by
  interaction id.
- **Upload edit** — an edit whose source is the user's own local video.
- **Dry-run** — a free preview and validation pass that makes no network call.
- **Task tags** — the console shorthand `[t2v]`, `[i2v]`, `[r2v]`, `[edit]` for the
  four task types.
- **Sequence** — the set of segments produced by splitting one long-form source
  video; generated and tracked as a group.
- **Segment** — one duration-matched slice of a sequence's source video, generated
  as its own edit job.
- **Prompt walking** — carrying continuity from one segment to the next via a
  driving frame and, optionally, a model-written description of it.
- **Continuity (driving) frame** — the last frame of a segment's finished output,
  used to drive the next segment when walking is on.
