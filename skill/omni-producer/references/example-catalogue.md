# Example catalogue — copy this file's layout

This file IS a parseable catalogue (5 jobs: `[t2v] [i2v] [r2v] [edit] [edit]`) —
this exact shape is the proven test fixture. Prose under `#`/`##` headings, like
this paragraph, is ignored by the parser; only `###` jobs count. Media paths
resolve relative to wherever your copy of the catalogue lives.

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
