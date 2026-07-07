# Ashokan

A simple, fast, native WYSIWYG editor for HTML documents on the Mac.

Named for the [Ashokan Reservoir](https://en.wikipedia.org/wiki/Ashokan_Reservoir)
in the Catskills.

## Why

HTML is the best document format we have: open, light, portable, viewable
anywhere, and capable of anything — tables, charts, columns, whatever you can
imagine. AI coding agents write beautiful HTML documents all day. But there is
no good way to *edit* one like a document. Code editors show you angle
brackets; word processors lock you into their own formats. Ashokan opens an
HTML file and lets you edit it the way a word processor would — and one
keystroke (⌘/) flips open the source pane when you want the markup.

## The core promise: lossless round-trip

Ashokan never rewrites what you didn't edit.

- Everything outside `<body>` — doctype, head, styles, meta — is preserved
  byte-for-byte.
- Every supported element keeps its full attribute bag (`class`, `id`,
  `style`, `data-*`) and re-emits it on save.
- Markup the editor doesn't model (scripts, SVG, custom elements, widgets)
  is carried as protected islands: rendered, movable, deletable — never
  mangled. (Islands pass through one DOM serialization, so spec-equivalent
  normalizations like `open` → `open=""` can occur; nothing is lost.)
- Documents render with their **own** stylesheets inside the editor, so a
  styled memo looks like itself while you edit it. Unstyled files get a clean
  default theme.

## Architecture

- **Shell:** native Swift/AppKit, `NSDocument`-based (autosave, Versions,
  window restoration come free). No frameworks, no Electron.
- **WYSIWYG surface:** `WKWebView` — Apple's system HTML engine — hosting a
  [ProseMirror](https://prosemirror.net) editing core
  ([editor/src/editor.js](editor/src/editor.js)). The document is HTML, so it
  is rendered by a real HTML engine: what you see is what a browser shows.
- **Source pane:** native `NSTextView`, toggled with ⌘/, live-synced both ways.
- **Round-trip layer:** [HTMLDocumentModel.swift](Ashokan/HTMLDocumentModel.swift)
  splits prelude / body / postlude; the JS core owns body fidelity.

## Building

```sh
scripts/build.sh          # bundles the JS core, generates the Xcode project,
                          # builds, and installs to /Applications
open -a Ashokan
```

Requires Xcode; node + xcodegen via Homebrew. The built ProseMirror bundle
(`Ashokan/Resources/editor.js`) is committed, so only `xcodegen` + `xcodebuild`
are strictly needed.

## Testing

```sh
swift scripts/roundtrip-test.swift   # headless fidelity checks on the real editing core
```

## Features

- **Welcome launcher & workspace** — recent documents with live-rendered
  thumbnails, filename, and path; add your project folders to the workspace
  sidebar and browse every HTML/Markdown document in them.
- **Markdown too** — open `.md` files, edit them WYSIWYG, flip to source to
  see clean Markdown, and saves stay Markdown (marked + turndown under the
  hood). HTML remains the native tongue.
- **Two-tier chrome** — file commands up top (save, PDF export, recents,
  source toggle), a slim formatting bar below, native window tabs for
  multiple documents, and a thin status bar with the file's path, format,
  size, save time, and live word count.
- **Images** — insert from file (embedded as a data URI so the document stays
  one self-contained file), paste or drag from anywhere, drag-corner resize,
  inline/float/center alignment, editable `<figure>`/`<figcaption>`.
- **Tables** — insert via Table menu or toolbar dropdown; add/delete rows and
  columns, merge/split cells, header-row toggle, draggable column widths.
- **PDF export** (⌥⌘P) — print-quality pagination: images, tables, and code
  blocks never split across pages; headings stay with their text.
- Markdown-style shortcuts while typing: `#` + space → heading, `-` + space →
  list, ` ``` ` → code block, `>` + space → blockquote.
- ⌘B/⌘I/⌘U/⌘E marks, ⌘⌥1–4/⌘⌥0 block styles, ⌘K link, Tab between table cells.
- Clicked links open in your browser; the document never navigates away.

## Roadmap

- Review mode: tracked changes as standard `<ins>`/`<del>`, comments, accept/reject
- Preserve `<colgroup>` and table `caption`
- Syntax highlighting in the source pane; find & replace across both panes
- PDF page numbers/headers; QuickLook thumbnails in Finder
- iOS companion (the editing core already runs in any WKWebView), files
  synced via iCloud Drive

## License

MIT
