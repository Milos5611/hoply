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

**How to apply:**
- A comment explains a non-obvious *why*: a format quirk, a workaround, an invariant, or ordering that matters. Never what the next line does.
- No doc comments on obvious types, properties, fields or one-line helpers.
- When you touch existing code, drop comments that only restate it. Keep script usage lines, because scripts have no `--help`.
- Tell subagents the same rule. Related: [[no-deletes]].
