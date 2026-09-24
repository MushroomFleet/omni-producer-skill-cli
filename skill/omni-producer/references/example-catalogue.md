# Example catalogue — copy this file's layout

This file IS a parseable catalogue (6 jobs: `[t2v] [i2v] [r2v] [edit] [edit]`,
plus one `Split` job that expands into its own segment `[edit]` jobs) — the
first five are the proven test fixture; the `Split` job shows the newer
sequence-mode directive syntax (point `Split:` at a real video to use it).
Prose under `#`/`##` headings, like this paragraph, is ignored by the parser;
only `###` jobs count. Media paths resolve relative to wherever your copy of
the catalogue lives.

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

### Anime Upload Edit
**Source:** ./clips/source-clip.mp4
```
Make this video anime. Keep everything else the same.
```

### Anime Pass On The Flyover
**Edit-from:** #1
```
Make this video anime. Keep everything else the same.
```

### Long Take Walkthrough
**Split:** ./clips/long-take.mp4
**Segment:** 8
```
Walk through the scene, continuous unbroken motion, no cuts, natural lighting throughout.
```

## Prompting notes (from the Omni Flash prompt guide)

- Want a single unbroken scene? Say so: "in a single continuous shot", "no scene
  cuts".
- Steer audio explicitly: "Include calm background music", "No dialogue".
- Time events naturally ("After 3 seconds, ...") or with timecodes
  (`[0-3s] ... [3-6s] ...`).
- Edit prompts work best simple; add "Keep everything else the same." to preserve
  the rest.
- Negatives go in the prompt itself ("Do not show the drawing") — the API has no
  negative-prompt field.
- A `Split:` job's prompt is reused for every segment — keep it generic
  ("continuous unbroken motion, no cuts") and let `Walk`/`Vision` (on by
  default) carry scene continuity forward instead of describing it per segment.
