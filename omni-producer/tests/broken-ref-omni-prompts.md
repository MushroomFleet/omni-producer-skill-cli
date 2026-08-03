# Broken-ref catalogue — validation flag test fixture

### Job With Missing Ref
**Image:** ./images/first-frame.png
**Ref:** ./images/does-not-exist.png
```
A test job whose reference image is deliberately missing.
```

### Contradictory Job
**Task:** text_to_video
**Image:** ./images/cat.png
```
A test job whose explicit task contradicts its media.
```
