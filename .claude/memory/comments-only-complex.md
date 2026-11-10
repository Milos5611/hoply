---
name: comments-only-complex
description: Write code comments only on genuinely complex parts; never restate what the code does
metadata:
  node_type: memory
  type: feedback
  originSessionId: 65b7a48e-4bed-4913-a456-69fcc04298ea
  modified: 2026-11-09T14:20:33.541Z
---

Add comments only where the logic is genuinely complex. This applies to Swift, shell scripts and config alike.

**Why:** The user asked on 2026-11-09 for "comments only on complex parts".

The user repeated it on 2026-11-10, annoyed: the M4/M5 work and its review fixes (written by subagents) carried a doc comment on almost every member, and the user asked to "remove all not-needed comments". About 140 of 180 comment lines in the app target were removed. My reading: "explains a why" was too loose a bar, because nearly every comment can be phrased as a why.

**How to apply:**
- Default to no comment. The bar: without it, a reader would "simplify" the code into a bug. One or two lines.
- No `///` on types, properties, enum cases or functions that says what the thing is or does, even when it also gives context.
- Before reporting any change, list the added comments (`git diff -U0 | grep -E '^\+\s*//'`) and cut the ones below the bar. Do the same on every subagent's result; the brief alone does not hold them to it.
- A comment explains a non-obvious *why*: a format quirk, a workaround, an invariant, or ordering that matters. Never what the next line does.
- No doc comments on obvious types, properties, fields or one-line helpers.
- When you touch existing code, drop comments that only restate it. Keep script usage lines, because scripts have no `--help`.
- Tell subagents the same rule. Related: [[no-deletes]].
