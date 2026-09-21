# Omni Producer — User Guide

A guide for turning a video prompt catalogue into finished `.mp4` files, once
you already have `OmniProducer.exe` and a Gemini API key. Everything below is
drawn from `Features.md` and `omni-producer-CLI-TINS.md`; consult those for
full detail.

## 1. What it does

Omni Producer is a zero-UI Windows command-line tool that turns a plain-text
"video job catalogue" into finished `.mp4` videos on disk by driving the
Gemini Omni Flash video generation and editing API. You write video prompts
as headed sections of a markdown file (or hand it a JSON job manifest),
preview the whole batch for free, then generate every video sequentially with
skip-existing, retry, and a totals summary. Every finished video is written
beside a small JSON sidecar that remembers its server-side interaction, so any
later job can edit that video conversationally without re-uploading anything.

## 2. Setup

1. Get `OmniProducer.exe` — a single self-contained Windows executable, with
   nothing else to install.
2. Put a `config.cfg` file beside the exe. It's plain JSON and holds your
   Gemini API key plus everything else the tool needs (model id, endpoints,
   defaults). A missing `config.cfg` falls back to built-in defaults with a
   warning.
3. The API key is resolved in this order: the `-ApiKey` flag, then `apiKey` in
   `config.cfg`, then the `GEMINI_API_KEY` environment variable, then
   `OMNI_API_KEY`. **A dry run needs no key at all.** Generating without a key
   anywhere in that chain is a hard error naming all four sources.

## 3. Your first catalogue

Save this as `my-videos-omni-prompts.md`:

````markdown
### Neon City Flyover
```
A futuristic city with neon lights and flying cars, cyberpunk style,
continuous unbroken aerial shot. Include a high energy techno beat. No dialogue.
```
````

Preview it for free — no key required, no network call:

```
OmniProducer.exe -Path .\my-videos-omni-prompts.md -DryRun
```

This prints a numbered plan (task tag, media, output filename, prompt length)
for every job, validates that every referenced media file exists, and exits
without spending anything. Once the plan looks right, generate for real:

```
OmniProducer.exe -Path .\my-videos-omni-prompts.md
```

The video lands next to your markdown file, in a folder named after it, as
`01-neon-city-flyover.mp4`.

## 4. Directives

Add labelled lines under a job's `###` heading to control it. Labels are
case-insensitive and tolerate bold/colon formatting (`**Task:** edit` and
`Task: edit` both work).

| Directive | Value | Meaning |
|---|---|---|
| `Task:` | `text_to_video` \| `image_to_video` \| `reference_to_video` \| `edit` | Force the task type (otherwise inferred from the media you provide). |
| `Aspect:` | `16:9` \| `9:16` | Landscape or portrait for this job. |
| `Delivery:` | `inline` \| `uri` | How the finished video comes back (default `uri`; `inline` only suits small videos). |
| `Image:` | file path | The image to animate, or the first-frame image for a reference job. |
| `Ref:` | file path | A reference image (character, product, or style); repeatable up to 6, needs an `Image:` first-frame. |
| `Source:` | file path | Your own video (`.mp4`/`.mov`/`.webm`/`.m4v`, up to 2 GB) to upload and edit. |
| `Edit-from:` | `#N`, a sidecar path, a video path, or an interaction id | Chain an edit onto a previous generation. |
| `Split:` | file path | Sequence mode: a source video longer than one generation, split and generated as a continuity-aware batch. |
| `Segment:` | whole seconds | Sequence mode: segment length (needs `Split:`; default 8s). |
| `Walk:` | `on` \| `off` | Sequence mode: carry the previous segment's last frame forward for continuity (default `on`). |
| `Vision:` | `on` \| `off` | Sequence mode: describe the carried-forward frame and fold it into the next prompt (default `on` when `Walk` is on). |

## 5. Batch behaviour

- **Skip-existing:** a job whose output `.mp4` already exists is skipped, so
  re-running a catalogue costs nothing. Add `-Force` to regenerate anyway.
- **`-Index N`:** run only job N (1-based catalogue position).
- **`-Limit N`:** run at most N jobs.
- **Folder mode:** point `-Path` at a folder instead of a file to run every
  markdown catalogue in it; add `-Recurse` to include subfolders too.
- **Totals line:** every run ends with `Done. Generated: X  Skipped: Y  Failed: Z`
  (or, for `-DryRun`, `Dry run complete. N job(s) would be generated.`).
- **Sidecars:** every successful video gets a `.json` sidecar recording its
  interaction id — that's what makes it editable later.
- **Conversational edits:** point a new job's `Edit-from:` at any earlier
  output — by its catalogue number (`#1`), its sidecar, or its `.mp4` — and the
  API reworks that video server-side with full context of what it made before,
  with no re-upload. This works in the same file, across runs, or weeks later.

## 6. Troubleshooting

| Problem | Fix |
|---|---|
| `Provide -Path <markdown-or-folder> or -Manifest <json>.` | You gave neither `-Path` nor `-Manifest` — supply exactly one. |
| A hard error naming all four API key sources | No key was found in the `-ApiKey` flag, `config.cfg`, `GEMINI_API_KEY`, or `OMNI_API_KEY` — set one of them. |
| `FAILED: media not found: <path>` | A job's `Image:`, `Ref:`, `Source:`, or `Split:` path doesn't resolve — check it's correct relative to the catalogue file. |
| `'ffprobe' not found. Set 'ffmpegPath'/'ffprobePath'...` | A `Split:` job needs `ffmpeg`/`ffprobe` on your `PATH`, or `ffmpegPath`/`ffprobePath` set in `config.cfg`. |
