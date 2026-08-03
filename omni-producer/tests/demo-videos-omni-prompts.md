# Demo video catalogue — Omni Producer test fixture

This file mirrors the 5-job example in `omni-producer-CLI-TINS.md`. The fenced
block under each `###` heading is the prompt; labelled lines are directives.

## How this catalogue works

Fenced blocks outside a `###` heading are ignored by the parser, like this one:

```
This template block must NOT appear as a job.
```

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
