# Ashokan QA Plan

Feature-by-feature manual/agent test plan. Run against the installed
/Applications/Ashokan.app. Each scenario gets a verdict: PASS / FAIL /
UGLY (works but looks wrong), with a screenshot.

## Group 1 — Launcher, onboarding, help, chrome

1. Reset onboarding (`defaults delete com.brantkuehn.Ashokan AshokanDidOnboard`),
   launch app → onboarding tour appears; Continue through all 4 steps; Back
   works; step 4 Add Folder opens a folder picker; Get Started closes tour and
   shows Welcome.
2. Welcome window: recents grid shows thumbnail cards with filename + path;
   sidebar lists Recents + workspace folders; selecting a folder lists its
   HTML/MD files; Add Folder… works; right-click folder → Remove works.
3. Click a recent card → document opens, Welcome closes.
4. Help menu: Ashokan Help (⌘?), Agent Guide, Roadmap & Plans each open as
   documents; Show Onboarding Tour replays.
5. Window tabs: open two documents → they appear as tabs; Window menu tab
   commands work.
6. About Ashokan shows version 0.7.0+ and a build number.

## Group 2 — Core editing

7. Untitled document (⌘N): template appears; type text; word count in status
   bar updates live.
8. Bold/italic/underline/inline code via format bar and ⌘B/⌘I/⌘U/⌘E.
9. Style popup: Title/Heading/Subheading/Body/Code Block all apply.
10. Markdown shortcuts: `# ` → heading, `- ` → list, `> ` → quote,
    triple-backtick → code block.
11. Link (⌘K) on selected text → link applied; clicking it opens the browser
    (document must not navigate).
12. Source pane (⌘/): opens with full HTML; edit in source → WYSIWYG updates;
    edit in WYSIWYG → source updates.
13. Zoom in/out/actual (⌘= ⌘− ⌘0).
14. Undo/redo in both panes.
15. Status bar shows path · format · size · saved time · words.

## Group 3 — Images, tables, formats, export

16. Insert image (⇧⌘I) from a file → appears; select → drag corner handle
    resizes; Format > Image alignment options apply.
17. Insert table 3×3 from Table menu → header row present; Tab moves between
    cells; add/delete row and column; merge two selected cells; toggle header
    row; drag a column border.
18. Open a Markdown file: renders WYSIWYG with default theme; source pane
    shows Markdown; edit + ⌘S keeps it Markdown; status bar says Markdown.
19. **REGRESSION (Brant, v0.7.0):** Export as PDF from a MARKDOWN document →
    save panel must propose `name.pdf` (NOT .md), format locked to PDF, and
    the exported PDF must open and paginate correctly.
20. Export as PDF from an HTML document with a table + image → nothing splits
    across pages.
21. demo-memo.html renders with its own stylesheet (blue headings, styled
    table); callout div and details widget are protected islands (subtle
    outline on hover, uneditable inline).

## Group 4 — Review & AI

22. review-demo.html: review bar auto-appears; ⌥⌘[ / ⌥⌘] navigate changes;
    hover a change → ✓/✕ chip; ✓ accepts exactly that change; ✕ rejects.
23. Accept All then undo; Reject All then undo.
24. Suggest toggle: typing inserts green ins text under your name; backspace
    over existing text marks red del; deleting your own pending insertion
    really deletes it.
25. Comments: select text, ⌥⌘M, add → yellow highlight; click highlight →
    popover with full text (no truncation), Edit… and Remove work.
26. Show All → margin cards aligned with anchors; card click jumps; hover
    card → Edit…/Remove buttons work.
27. Add Agent Instructions… → embeds comment block (verify in source pane,
    invisible in WYSIWYG).
28. AI Review with Local Model (qwen3:8b), default task → suggestions arrive
    as tracked changes with model as author; accept/reject them.
29. Save after review actions; reopen file; state round-trips.
