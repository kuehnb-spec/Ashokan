# QA Sweep Report — v0.7.0 → v0.7.1 (July 7, 2026)

Four Sonnet agents drove the installed app via computer-use, executing all 29
scenarios in docs/QA-PLAN.md with screenshot evidence (raw reports and images
in the session QA folder). Claude Fable directed, audited, fixed, and
re-verified. Wall-to-wall result: **29/29 scenarios pass** after fixes.

## Verdicts

| Group | Scenarios | Result |
|-------|-----------|--------|
| 1 — Launcher, onboarding, help, chrome | 1–6 | 6 PASS |
| 2 — Core editing | 7–15 | 7 PASS, 1 CRASH (fixed), 1 confusion (fixed) |
| 3 — Images, tables, formats, export | 16–21 | 5 PASS, 1 UGLY (fixed) |
| 4 — Review & AI | 22–29 | 8 PASS |

## Bugs found by the sweep → fixed & re-verified

1. **CRASH: toggling the source pane** (100% reproducible, 3 crash logs).
   The pane starts collapsed so its view was never loaded; `setText` hit a
   nil text view. Regression introduced by the v0.3 two-tier chrome
   restructure. Fix: `loadViewIfNeeded()` in the source controller's
   accessors. Re-verified live: repeated toggles, no crash.
2. **Style popup never tracked the cursor**, making the `# ` heading
   shortcut look broken (heading rendered but popup said "Body"). Fix: the
   editor now reports the cursor's block on every selection change and the
   popup follows (Title/Heading/Subheading/Body/Code Block). Re-verified live.
3. **macOS inline predictive text silently rewrote words** while typing
   ("formatme" → "Format"). Fix: `allowsInlinePredictions = false`.
4. **Image alignment didn't render in the canvas** (file was correct; the
   resize wrapper swallowed float/centering styles). Fix: layout styles
   mirror onto the wrapper. Verified headlessly: centered → block wrapper,
   float → floated wrapper.
5. **PDF export from Markdown proposed the wrong filename** (found by Brant,
   pre-sweep; scenario 19 verifies the fix): now always `name.pdf`.
6. **Latent: Save panel offered cross-format saving** (HTML doc saved "as
   Markdown" would have written mislabeled content). Found during fix
   verification. Fix: save panels now offer only the document's own format.

## Follow-ups noted (not blocking)

- AI review on a document that already contains tracked changes can wrap
  existing `ins`/`del` spans again — visually noisy nesting. Consider
  filtering suggestion quotes that overlap pending changes. (Roadmap.)
- One unreproducible stray-keystroke report during a suggest-mode focus
  transition (group 4); watch for recurrence.
- Workspace-folder count on onboarding step 4 doesn't visibly change when
  the chosen folder was already in the workspace (idempotent add; cosmetic).
- ⌘/ source toggle: works from menu/toolbar; the synthetic keystroke didn't
  trigger it under computer-use (likely injection quirk) — confirm on a
  physical keyboard.
