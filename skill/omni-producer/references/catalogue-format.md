# Markdown catalogue format

A catalogue is a plain `.md` file. The extraction rules (identical in the exe and
the ps1, live-proven against the API):

## Job boundaries

- A **job** is a level-3 heading (`### Title`) followed by a fenced ``` code block
  holding the **prompt**. Multiple fenced blocks under one heading concatenate.
- `#` / `##` headings **close** the current job — template/how-to sections under
  them are never captured. `####`+ lines are ignored.
- Fenced blocks outside a `###` heading are ignored.
- Sections without a prompt block are dropped. Jobs are numbered 1-based in file
  order; numbering is stable regardless of `-Index`/`-Limit` selection.

## Directives

Between/after the heading and prompt block, a job may carry labelled lines. Labels
are case-insensitive and tolerant of bold/colon placement — `**Task:** edit`,
`Task: edit`, and `**Task**: edit` all work:

| Directive | Value | Meaning |
|---|---|---|
| `Task:` | `text_to_video` \| `image_to_video` \| `reference_to_video` \| `edit` | Explicit task (else inferred). |
| `Aspect:` | `16:9` \| `9:16` | Per-job aspect ratio (overrides CLI flag and config). Ignored for edits — an edit inherits the source's aspect. |
| `Delivery:` | `inline` \| `uri` | Per-job delivery override. `uri` (default) polls and downloads; `inline` is base64 in-response (≤ ~4 MB videos). |
| `Image:` | file path | The driving image (`image_to_video`) or first-frame image (`reference_to_video`). PNG/JPG/WEBP. |
| `Ref:` | file path | A reference image; repeatable, order = `<IMAGE_REF_0..>`. Max 6. Requires `Image:`. |
| `Source:` | file path | The user's own video to upload and edit. MP4/MOV/WEBM/M4V, ≤ 2 GB. |
| `Edit-from:` | `#N` \| sidecar path \| `.mp4` path \| interaction id | Chain-edit a previous generation (see SKILL.md). |
| `Split:` | file path (`.mp4`/`.mov`/`.webm`/`.m4v`) | Sequence mode: a source video longer than one generation. Cannot combine with `Image`/`Ref`/`Source`/`Edit-from`. |
| `Segment:` | whole seconds | Sequence mode: segment length. Requires `Split`. Default: `config.generationSeconds` (8). |
| `Walk:` | `on` \| `off` | Sequence mode: carry the previous segment's last frame forward as a driving image. Default `on`. |
| `Vision:` | `on` \| `off` | Sequence mode: describe that carried-forward frame and fold it into the next segment's prompt. Default `on` when `Walk` resolves on. |

Relative paths resolve against the markdown file's directory.

## Task inference (when no `Task:` given)

First match wins: `Edit-from` → `edit`; `Source` → `edit`; `Image`+`Ref` →
`reference_to_video`; `Image` → `image_to_video`; none → `text_to_video`.

Contradictions are validation errors, flagged `!!` in dry-run and failed without
retry in wet runs: `Source` with `Image`/`Ref`; `Edit-from` with any media; `Ref`
without `Image`; an explicit task its media can't satisfy; > 6 refs; unknown
task/aspect/delivery values; missing media files; forward or self `#N` references;
`Split` combined with `Image`/`Ref`/`Source`/`Edit-from`; `Segment`/`Walk`/`Vision`
without `Split`.

## Sequence mode (Split jobs)

A `Split:` job bypasses task inference entirely and expands into its own batch
of `edit` jobs, one per segment:

1. **Probe** — `ffprobe` reads the input's duration. Segment count =
   `ceil(duration / segmentSeconds)`. A missing/unreadable input or a missing
   `ffmpeg`/`ffprobe` executable fails that job without aborting the rest of
   the run.
2. **Split** — `ffmpeg` cuts the input into `segments/NN-<slug>-%03d.mp4`
   (stream copy, falling back to a re-encode on a keyframe-boundary failure).
   Segments already on disk are reused unless `-Force`.
3. **Queue** — each segment becomes job `NN-<slug>-kkk`, task `edit`,
   inheriting the parent's aspect/delivery/model. `kkk` is the segment's
   1-based position; `-Index N` selects every segment of catalogue job `N`.
4. **Walk** (default on) — before segment `k > 1` runs, the last frame of the
   nearest completed earlier segment is extracted and sent as an additional
   driving image. When **Vision** is also on (default while walking), that
   frame is described by the model and `Continue from this scene: <description>`
   is appended to the segment's prompt. `Walk: off` makes every segment
   independent.
5. **Sidecars** — each segment's sidecar adds a `sequence` object: `{parent,
   index, count, segmentPath, firstFramePath, visionText}` (the last two
   `null` when walking is off or this is segment 1).
6. **Dry-run** — lists every planned segment after probing the input
   (`ffprobe` only — `ffmpeg` and the API are never called).

## Reference binding in prompts

For `reference_to_video`, the images bind to tags usable in the prompt: the
`Image:` is `<FIRST_FRAME>`, each `Ref:` is `<IMAGE_REF_0>`, `<IMAGE_REF_1>`, … in
directive order. Example prompt:
`<FIRST_FRAME> A cat <IMAGE_REF_0> playfully batting at a ball of yarn <IMAGE_REF_1>.`

## Output layout

- Output folder: next to the source file, named from the first 4
  hyphen/underscore/space-separated words of its filename, lowercased
  (`demo-videos-omni-prompts.md` → `demo-videos-omni-prompts/`).
- Video: `NN-<slug>.mp4` — NN zero-padded to `max(2, digits(jobCount))`, slug from
  the title (lowercase ASCII, diacritics stripped, non-alphanumerics → hyphens).
- Sidecar: `NN-<slug>.json`, written on success. Schema:

```json
{
  "title": "...", "index": 1, "task": "text_to_video",
  "prompt": "...", "model": "gemini-omni-flash-preview",
  "aspectRatio": "9:16",            // null for edits (inherited)
  "delivery": "uri",
  "interactionId": "v1_...",        // the edit-chain handle
  "fileId": "...",                  // set for uri delivery
  "previousInteractionId": null,    // set for chained edits
  "image": null, "references": [], "sourceVideo": null,
  "videoFile": "01-....mp4",
  "createdAt": "2026-08-03T02:44:37Z",
  "elapsedSeconds": 35.9, "status": "completed",
  "sequence": null,   // {parent, index, count, segmentPath, firstFramePath,
                       //  visionText} on a Split job's segments; else absent
  "audio": null        // {mode: "input"|"generated", inputClip, inputHadAudio}
                        // present only when -PreserveInputAudio is on; else absent
}
```

- Debug dump: a successful response with no recognizable video is saved as
  `NN-<slug>-response.json` and the job fails pointing at it.

## Engine behavior

Sequential, one job at a time. Skip-existing (unless `-Force`) checks only the
`.mp4`. Retries: `maxRetries` extra attempts (default 2), backoff `min(30, 3·N)` s
— but deterministic input-safety blocks are never retried, and validation errors
fail immediately without any API call. Uploads happen once per job and are cached
across that job's retries. Writes are atomic (`.part` → move), so interrupted runs
leave nothing partial. Exit code 0 = no failures; 1 = any failure (or any `!!`
validation flag in dry-run).

## Config keys (config.cfg beside the executable)

`apiKey`; `model` (the literal model id — update here if the model is renamed);
`endpointBase`; `uploadEndpointBase`; `defaultAspectRatio` (16:9);
`defaultDelivery` (uri); `store` (must stay true for chaining);
`timeoutSeconds` (600, the synchronous generation call); `pollIntervalSeconds` /
`pollTimeoutSeconds` (5/600, uri delivery); `uploadPollIntervalSeconds` /
`uploadPollTimeoutSeconds` (3/300, Files API processing); `maxRetries` (2);
`delayBetweenJobsSeconds` (2); `saveResponseJson` (true); `saveJobSidecar` (true —
must stay true for cross-run chaining); `slugMaxLength` (80); `ffmpegPath` /
`ffprobePath` (`ffmpeg`/`ffprobe`, resolved via `PATH` if bare — needed for
`Split:` jobs and `-PreserveInputAudio`); `generationSeconds` (8, the default
`Segment:` length); `preserveInputAudio` (`false` — turns the option on for
every run; the CLI flag turns it on regardless of this setting).
