# Manifest schema (Claude-extracted input for the CLI)

When source material can't be read reliably by the markdown parser — prose briefs,
storyboard docs, `## Track`-style headers, programmatically assembled batches —
Claude reads and understands it, extracts each job, and writes a **manifest JSON**.
The CLI's `-Manifest` mode consumes it and does only inference + delivery: the CLI
infers, Claude extracts.

## Schema

```json
{
  "sourceFile": "C:/abs/path/to/source.md",
  "outputDir":  "C:/abs/path/to/custom-folder",
  "jobs": [
    {
      "title":       "Cat And Yarn",
      "prompt":      "<FIRST_FRAME> A cat <IMAGE_REF_0> playfully batting at a ball of yarn <IMAGE_REF_1>.",
      "task":        "reference_to_video",
      "aspectRatio": "16:9",
      "delivery":    "uri",
      "image":       "images/first-frame.png",
      "references":  ["images/cat.png", "images/yarn.png"],
      "sourceVideo": "clips/source-clip.mp4",
      "editFrom":    "#1"
    }
  ]
}
```

Fields:

- **`jobs`** (required) — ordered array; order = the `NN-` file numbering.
- **`title`** (expected) — becomes the filename after `NN-` + slugify; defaults to
  `job-N`.
- **`prompt`** (required, non-empty) — a missing one is a hard error naming the job.
- **`task`**, **`aspectRatio`**, **`delivery`** (optional) — else inferred /
  config defaults. Same values and inference rules as markdown directives.
- **`image`**, **`references`**, **`sourceVideo`**, **`editFrom`** (optional) —
  same semantics as the `Image:`/`Ref:`/`Source:`/`Edit-from:` directives. A real
  job carries only the media its task needs (the example above shows every field
  purely for shape — `sourceVideo`/`editFrom` would contradict the image fields).
  Relative paths resolve against the **manifest file's** directory.
- **`sourceFile`** (required unless `outputDir` given) — the CLI derives the output
  folder from it (its directory + the first-4-filename-words rule).
- **`outputDir`** (optional) — explicit output folder; overrides the derivation.

Validation is identical to markdown mode: dry-run flags missing media,
contradictions, and bad `editFrom` references with `!!` and exit 1.

## How to extract (the reading step)

Read the whole source and find, per job: the **boundary** (heading, rule, bold
title — usually visually obvious), the **prompt** (the text the author intends as
the generation prompt), any **media** the job references (resolve to paths), and
any **edit relationship** ("then restyle the previous clip" → `editFrom`). Extract
by meaning, not fixed position. Give clean titles — slugging handles the rest.

Always dry-run the manifest (`-Manifest <path> -DryRun`) and confirm the job list
with the user before generating.
