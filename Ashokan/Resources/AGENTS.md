# Ashokan — Agent Guide

You are an AI agent (Claude Code, Codex, Hermes, or similar) working with
Ashokan, a native macOS WYSIWYG editor for HTML and Markdown documents.
This file tells you everything you need to operate with it correctly.

## What Ashokan is

- Documents are **plain HTML or Markdown files** — no proprietary format,
  no sidecar files. Anything you write into the file, the user sees.
- Ashokan's core guarantee is the **lossless round-trip**: it never rewrites
  markup the user didn't edit. You should honor the same rule.

## Editing a document for a user (THE PROTOCOL)

When asked to review or revise an Ashokan document, do **not** rewrite text
in place. Record every change as a tracked suggestion using standard HTML:

| Intent        | Markup |
|---------------|--------|
| Replace text  | `<del data-ashokan-author="YOUR-NAME">old</del><ins data-ashokan-author="YOUR-NAME">new</ins>` |
| Insert text   | `<ins data-ashokan-author="YOUR-NAME">added text</ins>` |
| Delete text   | `<del data-ashokan-author="YOUR-NAME">removed text</del>` |
| Comment       | `<mark title="your comment" data-ashokan-author="YOUR-NAME">the text you are commenting on</mark>` |

Rules:

- `YOUR-NAME` is your agent/model name (e.g. `Claude Code`). Optionally add
  `data-ashokan-ts="<ISO-8601 timestamp>"`.
- Keep every other byte — including the `<head>` — exactly as it was.
- Do not nest `<ins>` inside `<del>`. Keep suggestions small and local.
- The user accepts or rejects each suggestion in Ashokan's review UI
  (hover chips, review bar, margin comment cards). Insertions render
  green/underlined; deletions red/struck; comments as yellow highlights.

## Embedded instructions

Documents may contain an HTML comment beginning `<!-- ashokan-agent-instructions`.
It carries a task for you plus this same protocol. If present, follow its TASK
line. Users add it via Review > Add Agent Instructions…

## Operating the app itself

- Launch / open a file: `open -a Ashokan /path/to/file.html` (also `.md`).
- The app registers as an editor for `public.html` and
  `net.daringfireball.markdown`.
- Preferences and recents live in `com.brantkuehn.Ashokan` defaults;
  workspace folders under the `AshokanWorkspaceFolders` key.
- The app's own AI review (Review > AI Review with Local Model) talks to
  Ollama at `http://localhost:11434` and applies quote-anchored suggestions
  `{quote, replacement?, comment?}` as tracked changes.
- Human documentation: `Contents/Resources/ashokan-help.html` in this bundle.

## File-format details worth knowing

- Head, doctype, and everything outside `<body>` round-trip byte-for-byte.
- HTML comments inside the body are preserved (rendered as invisible islands).
- Unknown elements (scripts, SVG, custom tags) are preserved verbatim as
  protected islands; the editor won't let users mangle them.
- `<li>` and table cells keep their compact form (no spurious `<p>` wrappers).
- Markdown documents are converted in-editor (marked) and saved back as
  Markdown (turndown, GFM); `ins`/`del`/`mark` survive as inline HTML, which
  is valid Markdown.

## Building from source

Repo layout: Swift/AppKit shell (`Ashokan/`), ProseMirror editing core
(`editor/src/editor.js`), fidelity tests (`scripts/roundtrip-test.swift`).
`scripts/build.sh` bundles the JS, generates the Xcode project (xcodegen),
builds, and installs to /Applications. Run the test harness with
`swift scripts/roundtrip-test.swift` — all phases must pass.
