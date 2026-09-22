---
artifact: GROWTH.md
project: Omni Producer
updated: 2026-09-21 · 6ab029f · main
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

