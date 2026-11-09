---
name: ui-mizu-reference
description: "User judges Hoply's UI against Mizu's real screenshots; visible polish matters early, not only at the planned UI milestone"
metadata:
  node_type: memory
  type: feedback
  originSessionId: c53074c8-d9dc-4517-8e9d-e482ca4b70b8
  modified: 2026-11-09T15:11:04.828Z
---

On 2026-11-09, after M0 shipped with no visual change, the user said the panel was "far from the glass and how usemizu is looks like". So the panel visuals were pulled ahead of M1 (M0.5 in [[v2-plan]]).

**Why:** the user is building Hoply to look at least as good as Mizu (usemizu.com). They evaluate each step by how the panel looks, not only by the milestone checklist.

**How to apply:**
- Use Mizu's own screenshots as the reference, not guesses: `https://usemizu.com/img/resources/guide-panel.webp` (panel) and `widgets-1-0.webp` (widgets).
- Their language: frosted popover with an arrow, white 16 pt cards, 3-up stat tiles with tiny bar sparklines, project cards with a row of action buttons, ring widgets.
- Before reporting UI work, render `swift run Hoply --snapshot <dir>` and look at the PNGs yourself.
- When a milestone has user-visible output, show it (snapshot or a run) instead of only listing what changed.
