---
artifact: GROWTH.md
project: Omni Producer
updated: 2026-09-23 · f199194 · main
---

# Omni Producer — Growth

The gated ledger of proposals (tins-rsi C15). Append-only. One entry names one artifact and one diff.
The loop may append entries and evidence and the states `wanted`, `proposed`, `evaluated`.
Only the operator adds `picked`, `plan-approved`, `approved`, `rejected`. The applier adds `applied`
under its own identity. The deploy chain's continuance step adds `released`. A rejected entry is kept
verbatim: the losing reading is the payload. Entries mirrored from CRAB's `growth.md` carry their koji
and are never written back.

Capability path: wanted -> picked -> plan-approved -> built -> approved -> applied -> released
Policy path:     proposed -> evaluated -> approved | rejected -> applied -> released

## Entries

### G-0001 · policy · Deployment.md
- artifactSha: e654d7289c4d22a7c6dfccbca6bd854d59256da5a74eb8e3cee2c5820a06c4ed
- diff: tins-rsi-memory:proposals/20260921-204122-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: Removes the off-tree write that step 2 (build) unconditionally made outside the repo (the skill-bundle copy), and removes the undocumented-stop-point ambiguity that let a "build only" run fall through into the forbidden cut-release calls.
- states:
  - 2026-09-22T22:30:03.0102740Z proposed (loop)
  - 2026-09-22T22:30:03.0636525Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=fail, omnotation-stage-20260921-183403/big=fail, omnotation-stage-20260921-223018/big=fail, omnotation-chain-20260921-172058/small=fail, omnotation-stage-20260921-183403/small=fail (Stage 5, 20260921-204122-omnotation-chain)
  - 2026-09-22T22:38:53.0845899Z approved (MushroomFleet) · approved by the operator (Stage 6 proof, C75)
  - 2026-09-22T22:51:32.0871165Z applied (applier:Invoke-TinsRsiApply (MushroomFleet)) · 20260922-224347-apply-g-0001; applied-with-deviation; chain passed=True
  - 2026-09-22T23:04:27.136Z released (deploy-chain:continuance) · v1.0.3 chain replayed through continuance; commit-push at f199194

### G-0002 · policy · Deployment.md
- artifactSha: 0d2eab8ecb147c9687aaff5acc87a463aad7e51bfd20263a5b6aa89d98b90739
- diff: tins-rsi-memory:proposals/20260924-180351-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: Removes one redundant tool-call turn from an already-passing run by merging step 4's `git add CONTINUANCE.md GROWTH.md` + `git commit -m ...` into a single `git commit -am ...`, cutting the continuance step from 3 commands to 2.
- states:
  - 2026-09-24T20:00:14.8749299Z proposed (loop)
  - 2026-09-24T20:00:14.9035619Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=pass, omnotation-stage-20260921-223018/big=pass; rank 1 of 6, does not dominate the incumbent (stage7, 20260924-180351-omnotation-chain)

### G-0003 · policy · Deployment.md
- artifactSha: 0d2eab8ecb147c9687aaff5acc87a463aad7e51bfd20263a5b6aa89d98b90739
- diff: tins-rsi-memory:proposals/20260924-174308-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: Removes the extra `cd omni-producer/OmniProducer` command in step 2 by publishing the csproj directly from the repo root, cutting one command/turn from the build step on every replay.
- states:
  - 2026-09-24T20:00:14.9297080Z proposed (loop)
  - 2026-09-24T20:00:14.9384233Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=pass, omnotation-stage-20260921-223018/big=pass; rank 2 of 6, does not dominate the incumbent (stage7, 20260924-174308-omnotation-chain)

### G-0004 · policy · Deployment.md
- artifactSha: 0d2eab8ecb147c9687aaff5acc87a463aad7e51bfd20263a5b6aa89d98b90739
- diff: tins-rsi-memory:proposals/20260924-182534-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: Removes one turn from step 2 by folding the DryRun sanity check into the same fenced invocation as the post-build Copy-Item, instead of replaying them as two separate commands.
- states:
  - 2026-09-24T20:00:14.9634688Z proposed (loop)
  - 2026-09-24T20:00:14.9758053Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=pass, omnotation-stage-20260921-223018/big=pass; rank 3 of 6, does not dominate the incumbent (stage7, 20260924-182534-omnotation-chain)

### G-0005 · policy · Deployment.md
- artifactSha: 0d2eab8ecb147c9687aaff5acc87a463aad7e51bfd20263a5b6aa89d98b90739
- diff: tins-rsi-memory:proposals/20260924-194954-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: This removes the per-command turn cost step 4 pays for listing its `git add`/`commit`/`push` sequence as three comma-joined inline code spans instead of one fenced block, unlike every other multi-command step in the chain.
- states:
  - 2026-09-24T20:00:15.0021101Z proposed (loop)
  - 2026-09-24T20:00:15.0147627Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=pass, omnotation-stage-20260921-223018/big=fail; rank 4 of 6, does not dominate the incumbent (stage7, 20260924-194954-omnotation-chain)

### G-0006 · policy · Deployment.md
- artifactSha: 0d2eab8ecb147c9687aaff5acc87a463aad7e51bfd20263a5b6aa89d98b90739
- diff: tins-rsi-memory:proposals/20260924-175441-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: Removes one wasted preflight command — the unconditional `gh auth status` check — from every replay that stops before cut-release, cutting a turn from both the build-only and the stage-full runs without touching any required or forbidden call.
- states:
  - 2026-09-24T20:00:15.0454167Z proposed (loop)
  - 2026-09-24T20:00:15.0591384Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=pass, omnotation-stage-20260921-223018/big=fail; rank 5 of 6, does not dominate the incumbent (stage7, 20260924-175441-omnotation-chain)

### G-0007 · policy · Deployment.md
- artifactSha: 0d2eab8ecb147c9687aaff5acc87a463aad7e51bfd20263a5b6aa89d98b90739
- diff: tins-rsi-memory:proposals/20260924-181503-omnotation-chain/proposal.diff
- source: loop
- koji: -
- prediction: This change removes one tool-call turn from step 2 (build) by merging the already repo-root-relative, already-adjacent Copy-Item and DryRun sanity-check commands into a single script block instead of two separately fenced blocks.
- states:
  - 2026-09-24T20:00:15.0902431Z proposed (loop)
  - 2026-09-24T20:00:15.1053444Z evaluated (tins-rsi-loop) · pool vector: omnotation-chain-20260921-172058/big=pass, omnotation-stage-20260921-223018/big=fail; rank 6 of 6, does not dominate the incumbent (stage7, 20260924-181503-omnotation-chain)

