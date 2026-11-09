---
name: no-deletes
description: "Never delete files in the project; avoid rm in shell commands, even in scratch dirs"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 7b1ea34c-17a5-424a-b836-f06a8cd02b75
  modified: 2026-10-01T08:53:59.657Z
---

Don't delete anything from the project, and avoid `rm` in Bash commands generally — overwrite via redirection instead.

**Why:** User stopped a command containing `rm -f $S/*.cs` (scratchpad-only) because it looked like it could hit `~/.nuget/packages`; unguarded variable + rm reads as dangerous.

**How to apply:** Write outputs to fresh/absolute paths, use `>` to overwrite, never chain `rm` with `cd` into shared caches. If removal is genuinely needed, ask first and show the exact target.
