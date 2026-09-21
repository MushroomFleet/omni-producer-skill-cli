---
project: Omni Producer
description: Zero-UI Windows CLI (PowerShell 5.1 script + flag-identical .NET 8 exe) that batch-generates and statefully edits videos from a markdown or JSON job catalogue via the Gemini Omni Flash Interactions API.
updated: 2026-09-21 · 041f4c9 · main
---

# Omni Producer — Continuance

## Past

- [x] `omni-producer-CLI-TINS.md` — full TINS spec: four Omni Flash tasks, two input modes, dry-run, sidecar edit chaining, Files API upload; grounded in the docs and the proven Rust client · 45b9aaa
- [x] `omni-producer/Invoke-OmniProducer.ps1` — PowerShell 5.1 reference implementation, proven against the live API through the 10-scenario quality gate (TINS "Testing Scenarios"); four live-API amendments recorded in the spec · 2026-08-03
- [x] `omni-producer/OmniProducer/` — flag-compatible native `OmniProducer.exe` port (.NET 8, self-contained win-x64) · 6ab029f
- [x] `omni-producer` skill — orchestration skill authored last, from the proven behaviour (lives in `~/.claude/skills/omni-producer`) · 6ab029f
- [x] `v1.0.0` — public release: README, LICENSE, test fixtures (`omni-producer/tests/`), API reference docs, exe on GitHub Releases · 6ab029f · 2026-08-03
- [x] `GROWTH.md` — gated growth ledger added (tins-rsi C15/C39); no entries yet · 2f2ea40

## Present

**Stage 3 — input video splitting with FFmpeg.** `omnotation-dev/stage3-ffmpeg-sequence-plan.md`.
Parts A (EXE), B (script parity), and C (docs) are implemented in the working
tree; Definition of Done's last item (deploy chain replayed to the cut-release
boundary, this stage ticked) is next.

- Part A: `Program.cs` gains `Split`/`Segment`/`Walk`/`Vision` directives
  (markdown + manifest), a sequence planner (probe/split/last-frame/vision-describe),
  a `sequence` sidecar object, and dry-run listing. Builds clean, Debug and
  Release, 0 warnings.
- Part B: `Invoke-OmniProducer.ps1` mirrors Part A flag-for-flag
  (`Expand-OmniSequences`, `Get-VideoDuration`, `Split-OmniVideo`,
  `Get-LastFrame`, `Get-FrameDescription`, `Find-TextItem`).
- Part C: `omni-producer-CLI-TINS.md` and `Features.md` (via `features-scan`)
  both updated; the `omni-producer` skill's `SKILL.md` was **not** — no
  filesystem write access to that directory this session, flagged for the
  operator as a manual follow-up if wanted.
- Tests: `omni-producer/tests/Test-Sequence.ps1` + `sequence-omni-prompts.md`
  fixture (20 s ffmpeg `testsrc` clip, dry-run asserts 3 segments for
  `Segment: 8`). Both existing demo-catalogue dry-runs (5 jobs, exit 0)
  re-verified with zero regression, EXE and PS1, after every change.
- **Not yet proven against the live API** — unlike the four original tasks
  (10-scenario gate, 2026-08-03), no wet run was performed this session (no
  operator confirmation of spend was given or sought). Only the dry-run path
  was exercised, plus one indirect proof: this sandbox has no ffmpeg/ffprobe
  installed, and a real `Split` job correctly surfaces `'ffprobe' not found.
  Set 'ffmpegPath'/'ffprobePath'...` in both implementations. The vision
  (frame-description) request shape is best-effort, modeled on the proven
  video shapes rather than confirmed.
- Working file: `omnotation-dev/stage3-ffmpeg-sequence-plan.md`
- Blocked on: nothing
- Uncommitted: `Features.md`, `omni-producer-CLI-TINS.md`,
  `omni-producer/Invoke-OmniProducer.ps1`, `omni-producer/OmniProducer/Program.cs`,
  `omni-producer/template-config.cfg.txt`, `omni-producer/tests/Test-Sequence.ps1`
  (new), `omni-producer/tests/sequence-omni-prompts.md` (new)
- Next: the deploy chain (bump-version, build/publish, commit-push), stopping
  before cut-release per explicit operator instruction — no GitHub release
  will be cut this session.

## Future

No planning artifact names a next stage — v1.0.0 closed the TINS workflow
(script → exe → skill) and `GROWTH.md` holds no proposals. The only outstanding
list is the TINS "Extended Features" section, which marks these **explicitly out of
scope for v1**. Recorded here as candidates, not as a plan:

1. *Unplanned:* parallel workers — sequential is by design (spend metering, trivial `#N` chaining); would need a new artifact
2. *Unplanned:* resolution / duration controls — blocked on the API, which does not expose them
3. *Unplanned:* audio-reference inputs — blocked on the API, which rejects them
4. *Unplanned:* YouTube sources, video interpolation / extension — blocked on the API, unsupported
5. **Stage 3 — input video splitting with FFmpeg** — `omnotation-dev/stage3-ffmpeg-sequence-plan.md` *(in progress 2026-09-21 — see Present; Parts A/B/C implemented and uncommitted, not yet proven against the live API)*: introduce input video splitting with FFMPEG, to match generation duration, for batch queue operation, with prompt walking to remain consistent, checking the last frame, used as next first frame with vision in sequence

## Lessons

1. **Chained edits must omit `generation_config` entirely.** The API rejects
   `previous_interaction_id` alongside a video task (400). The proven Rust client
   sends both and would fail against the current API; the docs' own stateful-editing
   example sends neither. Live code beat both blueprints.
2. **Edit jobs omit `aspect_ratio`.** An edit inherits its aspect from the source
   video; sending one is rejected. Sidecars record `aspectRatio: null` for edits.
3. **Uploaded videos are referenced as `{type:"video", uri, mime_type}`, not
   `{type:"document", uri}`.** The `document` item in the SDK docs is SDK sugar; the
   REST endpoint does not count it as a video and fails with "Exactly one input
   video is required for edit task."
4. **An "Input blocked: sensitive words" error on an upload-edit is a region
   restriction, not the prompt.** EEA/Switzerland/UK block uploaded-video editing
   and surface it as a generic policy block on any prompt, while chained edits of
   model-generated videos keep working in the same region. Suspect the region first.
5. **Never retry a deterministic safety block.** The same input can never pass on
   retry, so `Input blocked` / `Prohibited Use policy` fail immediately; only
   transient errors enter the backoff loop.
