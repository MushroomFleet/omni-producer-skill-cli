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

_(no entries yet)_
