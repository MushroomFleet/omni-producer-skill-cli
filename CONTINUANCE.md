---
project: Omni Producer
description: Zero-UI Windows CLI (PowerShell 5.1 script + flag-identical .NET 8 exe) that batch-generates and statefully edits videos from a markdown or JSON job catalogue via the Gemini Omni Flash Interactions API.
updated: 2026-09-21 · 2f2ea40 · main
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

**Repository housekeeping — root-family files.** `GROWTH.md` landed at 2f2ea40; this
`CONTINUANCE.md` is being added in the same session. No feature work in flight.

- Working file: none
- Blocked on: nothing
- Uncommitted: `CONTINUANCE.md`

## Future

No planning artifact names a next stage — v1.0.0 closed the TINS workflow
(script → exe → skill) and `GROWTH.md` holds no proposals. The only outstanding
list is the TINS "Extended Features" section, which marks these **explicitly out of
scope for v1**. Recorded here as candidates, not as a plan:

1. *Unplanned:* parallel workers — sequential is by design (spend metering, trivial `#N` chaining); would need a new artifact
2. *Unplanned:* resolution / duration controls — blocked on the API, which does not expose them
3. *Unplanned:* audio-reference inputs — blocked on the API, which rejects them
4. *Unplanned:* YouTube sources, video interpolation / extension — blocked on the API, unsupported
5. **Stage 3 — input video splitting with FFmpeg** — `omnotation-dev/stage3-ffmpeg-sequence-plan.md` *(planned, added by the operator 2026-09-21)*: introduce input video splitting with FFMPEG, to match generation duration, for batch queue operation, with prompt walking to remain consistent, checking the last frame, used as next first frame with vision in sequence

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
