# Changelog

## 0.10.2 — July 16, 2026
- **Every bar is now discoverable** (Brant's design): the View menu lists
  Format Bar, Review Bar, Comments in Margin, Source Pane, and Status Bar
  with checkmarks; the matching toolbar buttons tint with the system accent
  color while their bar is visible. Format and status bar preferences persist.
- **Installs like a Mac app**: releases now ship a notarized drag-to-
  Applications .dmg alongside the .zip.

## 0.10.1 — July 14, 2026
- **Print** (File > Print…, ⌘P, and a toolbar button) — somehow we shipped
  ten versions of a document editor without it (thanks, Brant). Uses the
  same pagination as PDF export (images/tables/code blocks never split,
  headings stay with their text) and the same pending-review warning.

## 0.10.0 — July 13, 2026
- **MCP server** (Review > Allow Agents to Connect): any MCP-speaking agent —
  Claude Code, Codex, others — can list, read, and open Ashokan documents
  and propose edits that land as tracked changes under the agent's name.
  Optimistic-concurrency revision tokens make stale writes impossible;
  there is deliberately no accept/reject tool (humans adjudicate).
  Off by default; zero overhead when off; 127.0.0.1-only with bearer-token
  auth; one-paste setup via Review > Copy Agent Setup Command.

## 0.9.1 — July 9, 2026
- **Fix:** a comment spanning a paragraph boundary produced duplicate margin
  cards (one per paragraph). Comments now carry a stable id in their markup
  and the margin merges by it; existing id-less comments are healed by a
  block-boundary-aware merge. (Reported by Brant from daily use.)

## 0.9.0 — July 9, 2026
- **Signed and notarized.** Releases are now built in Release configuration,
  signed with a Developer ID (hardened runtime), notarized by Apple, and
  stapled — downloads open with no Gatekeeper warnings. The full pipeline is
  `scripts/release.sh`.

## 0.8.1 — July 9, 2026
- **Start Here tour**: a live tutorial document with pre-seeded suggestions,
  a comment, and a task checklist; opens as an editable untitled from
  onboarding, the Welcome window's Start Here button, or Help.
- Demo GIF in the README, recorded against the real app.

## 0.8.0 — "the research release," July 8, 2026
Tranche 1 of the [45-agent market study](docs/MARKET-RESEARCH.html):
- Bulk review operations: Accept/Reject All scoped to everything, the
  selection, or a single author (humans vs. AI reviewers).
- Preview modes: Markup / Final / Original — view-only, with a safety banner
  and read-only enforcement; the file always keeps its markup.
- External-change detection: agent rewrites the open file → clean documents
  reload automatically; dirty documents get a Reload-or-Keep conflict alert.
- Data-loss guards: WebKit process-death recovery; suspicious empty-body
  updates rejected.
- Export-time review check (with Accept All & Export); PDF title/author metadata.
- Clickable GFM task lists round-tripping to `- [x]`; dark-mode default theme.
- Adversarial round-trip corpus: 38 fidelity checks across five phases.

## 0.7.x — July 8, 2026
- Review bar summonable anytime (toolbar checklist button, ⇧⌘R).
- Onboarding tour; bundled help + AGENTS.md agent guide; Help menu.
- Margin comment cards with Edit/Remove; comment popover sizing fix.
- QA sweep by four computer-using agents (29 scenarios): fixed a
  source-pane crash, style-popup cursor tracking, silent predictive-text
  rewrites, invisible image alignment, cross-format save mislabeling,
  Markdown PDF-export filename.
- Versioning from git (`VERSION` file + commit count).

## 0.5–0.6 — July 7–8, 2026
- **AI Review with a local Ollama model**: quote-anchored suggestions applied
  as tracked changes, model named as author; nothing leaves the machine.
- Agent instructions: invisible embedded protocol teaching Claude Code/Codex
  to propose edits as tracked changes.
- Click-to-read comment popovers; comments margin (Show All).
- HTML comments in the body preserved through the round-trip.
- Hover ✓/✕ chips on tracked changes. App icon (Angle-Bracket Mountains).

## 0.2–0.4 — July 7, 2026
- **Review mode**: tracked changes as standard `ins`/`del`, comments as
  `mark`+`title` — redlines readable in any browser.
- Images (data-URI embed, drag/paste, resize, alignment), full table editing,
  print-quality PDF export, Markdown open/edit/save, Welcome launcher with
  workspace folders and live thumbnails, two-tier toolbar, status bar,
  native tabs.

## 0.1 — July 7, 2026
- Initial release: native AppKit shell, WKWebView + ProseMirror editing core,
  toggleable source pane, and the founding rule — the lossless round-trip.
  Everything outside `<body>` byte-for-byte; unknown markup preserved as
  protected islands.
