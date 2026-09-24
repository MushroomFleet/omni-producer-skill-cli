---
project: Omni Producer
description: Zero-UI Windows CLI (PowerShell 5.1 script + flag-identical .NET 8 exe) that batch-generates and statefully edits videos from a markdown or JSON job catalogue via the Gemini Omni Flash Interactions API.
updated: 2026-09-24 · dc70038 · main
---

# Omni Producer — Continuance

## Past

- [x] **v1.0.0** — TINS spec, both implementations (PowerShell + .NET exe) proven through the 10-scenario quality gate, the orchestration skill, public release (README/LICENSE/tests/docs) · 45b9aaa–6ab029f · 2026-08-03
- [x] `GROWTH.md` — gated growth ledger added (tins-rsi C15/C39); no entries yet · 2f2ea40
- [x] `USER-GUIDE.md` — Stage 4 written at repo root per plan; deploy chain replayed, released as v1.0.2 · 840a159
- [x] `GROWTH.md` G-0001 — tins-rsi loop policy proposal on `Deployment.md`: closes the off-tree skill-bundle write that `build` made unconditionally, and removes the undocumented stop-point ambiguity for `build only`; proposed, evaluated, operator-approved · cea4e6b
- [x] `GROWTH.md` G-0001 — applied and the v1.0.3 chain replayed: bump-version,
      build, commit-push, continuance checkpoint; ledger now carries `released`
      · 1d80b3c, 2b36670, f199194
- [x] `GROWTH.md` G-0002…G-0007 — 12 proposals from the tins-rsi loop (Stage 7,
      C69): six ranked policy diffs against `Deployment.md`; G-0003 picked
      (rank 2 of 6, removes the step-2 `cd` hazard) · d4ed670
- [x] `v1.0.4` — G-0003 approved and applied (`dotnet publish` now runs from
      the repo root, no `cd`); chain replayed through continuance; ledger now
      carries `released` · 97b727c, 5d85d7e, daea76b
- [x] `omnotation-dev/stage5-preserve-input-audio-plan.md` — `--preserve-input-audio`:
      both implementations (EXE + script parity), sidecar `audio` object, a
      hard ffmpeg/ffprobe preflight before any network call, docs (TINS,
      Features.md, USER-GUIDE.md), and a free smoke test; chain replayed
      through continuance, released as v1.0.5 (tins-rsi's C91 proof) · 69916cd
- [x] `omnotation-dev/stage6-skill-sync-plan.md` — the omni-producer skill
      (`skill/omni-producer/`) brought current with sequence mode and
      `--preserve-input-audio`: Installation/Sequence-mode/Preserving-input-audio
      sections in `SKILL.md`, the four sequence directives and the sidecar's
      `sequence`/`audio` fields in `references/`, a `README.md` "Install the
      skill" section, and the free `Test-SkillPackage.ps1` packaging test;
      chain replayed through continuance, released as v1.0.6 (first release to
      ship `omni-producer.skill` alongside the exe) · dc70038

## Present

*Nothing in progress.* v1.0.6 is released as a **pre-release**
(https://github.com/MushroomFleet/omni-producer-skill-cli/releases/tag/v1.0.6),
awaiting testing and promotion to Latest by a human. The chain always cuts the
release, as a pre-release, and continuance follows it (tins-rsi ruling C91).

- Working file: none.
- Blocked on: nothing.
- Uncommitted: none — this checkpoint commits cleanly alongside `GROWTH.md`
  (unchanged this cycle — no `applied`-without-`released` entries, and Stage 6
  is the operator's own item, not a tins-rsi loop proposal).
- Next: testers pick up the v1.0.6 pre-release; a human promotes it once
  cleared. This repo's chain never writes outside its own tree (Deployment.md);
  any copy of `skill/omni-producer/` into the global `~/.claude/skills/omni-producer`
  is done by hand, outside this session. G-0002 and G-0004…G-0007 remain
  `evaluated` only (not picked, Stage 7): no action pending on them.

## Future

No planning artifact names a next stage — Stage 6 was the last named item and
`GROWTH.md` holds no unactioned proposals. The only outstanding list is the
TINS "Extended Features" section, which marks these **explicitly out of scope
for v1**. Recorded here as candidates, not as a plan:

1. *Unplanned:* parallel workers — sequential is by design (spend metering, trivial `#N` chaining); would need a new artifact
2. *Unplanned:* resolution / duration controls — blocked on the API, which does not expose them
3. *Unplanned:* audio-reference inputs — blocked on the API, which rejects them
4. *Unplanned:* YouTube sources, video interpolation / extension — blocked on the API, unsupported

Stages 3–6 (splitting, the user guide, `--preserve-input-audio`, and the skill
sync) are all done — see Past; their plan files are kept for their text.

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
6. **Verify a growth-loop diff by content and `artifactSha`, not by trusting
   `git apply`.** G-0001's proposal.diff had internally-consistent hunk headers
   that still didn't line up with the actual file (a generation artifact) —
   `git apply --check` rejected it even though the content was exactly right.
   Hashing the target file against the ledger's `artifactSha` first confirmed
   the diff was safe to apply by hand, hunk-by-content instead of by line number.
