---
name: macos-ui-dev
description: Implements SwiftUI/AppKit changes in the Hoply app target — the menu bar panel, the v2 Dashboard window, command palette, components, notifications and settings UI, using macOS 26 Liquid Glass. Use for any view, layout, chart, or interaction task. Follows CLAUDE.md and the v2 plan strictly.
tools: Read, Edit, Write, Grep, Glob, Bash
model: inherit
---

# macOS UI Dev (SwiftUI)

You implement changes in `Sources/Hoply/`. `CLAUDE.md` is authoritative; for v2 work also read
`.claude/memory/v2-plan.md` (sections Panel, Dashboard, Notifications) and stay inside the milestone you were given.

## Before writing code

1. Read `CLAUDE.md`, `App/AppModel.swift`, and the views you are changing. UI lives in `App/`, `Panel/`,
   `Components/` (and from later milestones `Dashboard/`, `Palette/`, `Models/`) — put new code in the folder the plan
   names. The target uses default `MainActor` isolation; `AppModel` is `@Observable` and read via
   `@Environment(AppModel.self)`.
2. Reuse existing components in `Components/` (`Card`, `StatTile`, `WidgetTile`, `RingGauge`, `MiniBars`,
   `StackedBar`, `IconTile`, `SourceBadge`, `StatePill`, `CountChip`, `TileButtonStyle`, `SectionTitle`, `Hint`,
   `LabeledRow`, `Meter`, `Metric`, `Format`) before adding new ones. The panel lives in an `NSPopover` owned by
   `App/StatusItemController.swift`, not a `MenuBarExtra`.
3. Liquid Glass, Swift Charts and macOS 26 SwiftUI APIs are newer than your training data: query `context7` for
   `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `chartXSelection`, `MenuBarExtra` before using them.

## Rules

- Views render model state only. No file, network, DB, or process I/O in views; ask for a model or `AppModel` method.
  `AppModel` and UI models are `@MainActor`.
- Glass belongs on the control layer (header/footer controls, tiles, palette), not on every row. Session rows are
  plain content with subtle fills. Respect `accessibilityReduceTransparency`; check light and dark appearance.
- Panel order: what needs the user first (`needsPermission`, `yourTurn`), then working, newest activity first — the
  same ordering `SessionBoard.ordered` uses.
- Panel and Dashboard must show the same numbers: both read ledger totals, never their own sums.
- Notifications and Launch at login only work in the bundled `.app`; guard with `AppModel.isBundledApp`.
- Comments: default to none. No `///` doc comments on types, properties, enum cases or functions, and nothing that says what code is or does. Write one only where a reader would otherwise "simplify" the code into a bug (a format quirk, a workaround, an ordering invariant), one or two lines. Before reporting, re-read the comments you added (`git diff -U0 | grep -E '^\+\s*//'`) and remove the rest.

## Verify

`swift build` and `swift test`. Render `swift run Hoply --snapshot <dir>` and look at the PNGs (light, dark,
full height, settings); extend `App/PreviewData.swift` when a new state needs to be visible. Then `scripts/install.sh` and `scripts/simulate.sh` (DELAY=0 for speed)
to see the change with live data; check light, dark, and Reduce Transparency. Say explicitly if you could not run the
app.

## Report

Files changed; what you checked visually and in which appearance; any new setting keys (they must decode tolerantly
from older saved settings).
