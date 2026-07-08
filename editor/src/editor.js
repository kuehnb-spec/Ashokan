// Ashokan editing core.
//
// Design principle: NEVER destroy markup we don't understand.
//  - Every supported element keeps its full attribute bag (class, id, style, data-*)
//    and re-emits it verbatim on serialize.
//  - Unsupported elements are captured whole (outerHTML) into protected "raw"
//    island nodes — visible, movable, deletable, but never rewritten.
//  - The Swift shell owns everything outside <body>; this core only ever sees
//    and returns body HTML.

import { Schema, DOMParser as PMDOMParser, DOMSerializer } from "prosemirror-model"
import { EditorState, TextSelection, Plugin } from "prosemirror-state"
import { EditorView } from "prosemirror-view"
import { history, undo, redo } from "prosemirror-history"
import { keymap } from "prosemirror-keymap"
import {
  baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode,
  newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock,
} from "prosemirror-commands"
import { wrapInList, splitListItem, liftListItem, sinkListItem } from "prosemirror-schema-list"
import { inputRules, wrappingInputRule, textblockTypeInputRule } from "prosemirror-inputrules"
import { dropCursor } from "prosemirror-dropcursor"
import { gapCursor } from "prosemirror-gapcursor"
import { marked } from "marked"
import TurndownService from "turndown"
import { gfm } from "turndown-plugin-gfm"
import {
  tableNodes, tableEditing, goToNextCell, columnResizing,
  addColumnBefore, addColumnAfter, deleteColumn,
  addRowBefore, addRowAfter, deleteRow,
  mergeCells, splitCell, toggleHeaderRow, deleteTable,
} from "prosemirror-tables"

// ---------------------------------------------------------------------------
// Attribute-bag helpers: capture ALL attributes of an element so we can
// re-emit them exactly on save.
// ---------------------------------------------------------------------------

function bagFromDOM(dom, skip) {
  const bag = {}
  for (const a of dom.attributes) {
    if (skip && skip.includes(a.name)) continue
    bag[a.name] = a.value
  }
  return bag
}

const bagAttr = { attrs: { default: {} } }

function bagToDOM(node) {
  return node.attrs.attrs || {}
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const CONTAINER_TAGS = ["div", "section", "article", "aside", "header", "footer", "main", "nav", "figure"]

const nodes = {
  doc: { content: "block+" },

  paragraph: {
    group: "block",
    content: "inline*",
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "p", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["p", bagToDOM(node), 0] },
  },

  heading: {
    group: "block",
    content: "inline*",
    defining: true,
    attrs: { level: { default: 1 }, attrs: { default: {} } },
    parseDOM: [1, 2, 3, 4, 5, 6].map(level => ({
      tag: "h" + level,
      getAttrs: d => ({ level, attrs: bagFromDOM(d) }),
    })),
    toDOM(node) { return ["h" + node.attrs.level, bagToDOM(node), 0] },
  },

  blockquote: {
    group: "block",
    content: "block+",
    defining: true,
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "blockquote", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["blockquote", bagToDOM(node), 0] },
  },

  code_block: {
    group: "block",
    content: "text*",
    marks: "",
    code: true,
    defining: true,
    attrs: { attrs: { default: {} }, codeAttrs: { default: {} } },
    parseDOM: [{
      tag: "pre",
      preserveWhitespace: "full",
      getAttrs: d => {
        const code = d.querySelector(":scope > code")
        return { attrs: bagFromDOM(d), codeAttrs: code ? bagFromDOM(code) : {} }
      },
    }],
    toDOM(node) { return ["pre", bagToDOM(node), ["code", node.attrs.codeAttrs || {}, 0]] },
  },

  ordered_list: {
    group: "block",
    content: "list_item+",
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "ol", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["ol", bagToDOM(node), 0] },
  },

  bullet_list: {
    group: "block",
    content: "list_item+",
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "ul", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["ul", bagToDOM(node), 0] },
  },

  list_item: {
    content: "paragraph block*",
    defining: true,
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "li", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["li", bagToDOM(node), 0] },
  },

  horizontal_rule: {
    group: "block",
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "hr", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["hr", bagToDOM(node)] },
  },

  // Generic preserved container: keeps the tag name and every attribute of
  // div/section/article/etc. while letting you edit the content inside.
  container: {
    group: "block",
    content: "block+",
    defining: true,
    attrs: { tag: { default: "div" }, attrs: { default: {} } },
    parseDOM: CONTAINER_TAGS.map(tag => ({
      tag,
      getAttrs: d => ({ tag, attrs: bagFromDOM(d) }),
    })),
    toDOM(node) { return [node.attrs.tag, bagToDOM(node), 0] },
  },

  image: {
    group: "inline",
    inline: true,
    draggable: true,
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "img", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["img", bagToDOM(node)] },
  },

  figure_caption: {
    group: "block",
    content: "inline*",
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "figcaption", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(node) { return ["figcaption", bagToDOM(node), 0] },
  },

  hard_break: {
    group: "inline",
    inline: true,
    selectable: false,
    parseDOM: [{ tag: "br" }],
    toDOM() { return ["br"] },
  },

  // Protected islands for markup we don't model. Round-trips byte-for-byte.
  html_block: {
    group: "block",
    atom: true,
    selectable: true,
    draggable: true,
    attrs: { html: { default: "" } },
    parseDOM: [{
      tag: "ashokan-raw",
      getAttrs: d => ({ html: decodeURIComponent(d.getAttribute("data-html") || "") }),
    }],
    toDOM(node) { return rawElementFor(node.attrs.html, false) },
  },

  html_inline: {
    group: "inline",
    inline: true,
    atom: true,
    selectable: true,
    attrs: { html: { default: "" } },
    parseDOM: [{
      tag: "ashokan-raw-inline",
      getAttrs: d => ({ html: decodeURIComponent(d.getAttribute("data-html") || "") }),
    }],
    toDOM(node) { return rawElementFor(node.attrs.html, true) },
  },

  text: { group: "inline" },
}

// Build a DOM element from preserved raw HTML, for serialization.
// ProseMirror's serializer only accepts elements, so preserved HTML comments
// travel in a carrier element that serializeBodyHTML converts back into a
// real comment node.
function rawElementFor(html, inline) {
  if (html.trimStart().startsWith("<!--")) {
    const carrier = document.createElement("ashokan-comment-node")
    carrier.setAttribute("data-html", encodeURIComponent(html))
    return carrier
  }
  const tpl = document.createElement("template")
  tpl.innerHTML = html
  const el = tpl.content.firstElementChild
  if (el) return el
  return document.createElement(inline ? "span" : "div")
}

const marks = {
  link: {
    attrs: { attrs: { default: {} } },
    inclusive: false,
    parseDOM: [{ tag: "a", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["a", bagToDOM(mark), 0] },
  },

  strong: {
    attrs: { attrs: { default: {} } },
    parseDOM: [
      { tag: "strong", getAttrs: d => ({ attrs: bagFromDOM(d) }) },
      { tag: "b", getAttrs: d => ({ attrs: bagFromDOM(d) }) },
    ],
    toDOM(mark) { return ["strong", bagToDOM(mark), 0] },
  },

  em: {
    attrs: { attrs: { default: {} } },
    parseDOM: [
      { tag: "em", getAttrs: d => ({ attrs: bagFromDOM(d) }) },
      { tag: "i", getAttrs: d => ({ attrs: bagFromDOM(d) }) },
    ],
    toDOM(mark) { return ["em", bagToDOM(mark), 0] },
  },

  code: {
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "code", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["code", bagToDOM(mark), 0] },
  },

  underline: {
    attrs: { attrs: { default: {} } },
    parseDOM: [{ tag: "u", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["u", bagToDOM(mark), 0] },
  },

  strike: {
    attrs: { attrs: { default: {} } },
    parseDOM: ["s", "strike"].map(tag => ({
      tag, getAttrs: d => ({ attrs: bagFromDOM(d) }),
    })),
    toDOM(mark) { return ["s", bagToDOM(mark), 0] },
  },

  // Tracked changes: standard HTML ins/del, so pending edits render
  // (underline/strikethrough) in any browser, no Ashokan required.
  ins: {
    attrs: { attrs: { default: {} } },
    inclusive: true,
    parseDOM: [{ tag: "ins", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["ins", bagToDOM(mark), 0] },
  },

  del: {
    attrs: { attrs: { default: {} } },
    inclusive: false,
    parseDOM: [{ tag: "del", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["del", bagToDOM(mark), 0] },
  },

  // Comments: <mark title="…"> so hovering shows the comment in any browser.
  comment: {
    attrs: { attrs: { default: {} } },
    inclusive: false,
    excludes: "",
    parseDOM: [{ tag: "mark", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["mark", bagToDOM(mark), 0] },
  },

  // Styled spans (very common in generated documents) keep their attributes.
  span: {
    attrs: { attrs: { default: {} } },
    excludes: "",
    parseDOM: [{ tag: "span", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
    toDOM(mark) { return ["span", bagToDOM(mark), 0] },
  },

  // Preserved generic inline tags: sub, sup, mark, kbd, small, abbr, cite, etc.
  generic_inline: {
    attrs: { tag: { default: "span" }, attrs: { default: {} } },
    excludes: "",
    parseDOM: ["sub", "sup", "small", "kbd", "abbr", "cite", "dfn", "var", "samp", "time", "q"].map(tag => ({
      tag, getAttrs: d => ({ tag, attrs: bagFromDOM(d) }),
    })),
    toDOM(mark) { return [mark.attrs.tag, bagToDOM(mark), 0] },
  },
}

// Table support with attribute preservation on the <table> element itself.
const tables = tableNodes({
  tableGroup: "block",
  cellContent: "block+",
  cellAttributes: {
    attrs: {
      default: {},
      getFromDOM(dom) { return bagFromDOM(dom, ["colspan", "rowspan", "data-colwidth"]) },
      setDOMAttr(value, domAttrs) { Object.assign(domAttrs, value || {}) },
    },
  },
})

tables.table = {
  ...tables.table,
  attrs: { attrs: { default: {} } },
  parseDOM: [{ tag: "table", getAttrs: d => ({ attrs: bagFromDOM(d) }) }],
  toDOM(node) { return ["table", bagToDOM(node), 0] },
}

Object.assign(nodes, tables)

const schema = new Schema({ nodes, marks })

// ---------------------------------------------------------------------------
// Preprocessing: before ProseMirror parses incoming HTML, replace anything we
// don't model with placeholder elements carrying the exact original markup.
// ---------------------------------------------------------------------------

const KNOWN_TAGS = new Set([
  "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code",
  "ol", "ul", "li", "hr", "img", "br", "figcaption",
  "table", "thead", "tbody", "tfoot", "tr", "th", "td",
  "a", "strong", "b", "em", "i", "u", "s", "strike", "del", "ins", "span",
  "sub", "sup", "small", "mark", "kbd", "abbr", "cite", "dfn", "var", "samp", "time", "q",
  ...CONTAINER_TAGS,
])

// Unknown tags that should be treated as inline islands.
const INLINE_RAW_TAGS = new Set(["wbr", "label", "output", "data", "bdi", "bdo", "ruby", "button", "input", "select"])

// Parents that establish a phrasing (inline) context.
const PHRASING_PARENTS = new Set([
  "p", "h1", "h2", "h3", "h4", "h5", "h6", "a", "span", "em", "i", "strong", "b",
  "u", "s", "li", "td", "th", "code", "small", "mark", "sub", "sup",
])

function preprocess(root) {
  for (const child of Array.from(root.childNodes)) {
    if (child.nodeType === Node.COMMENT_NODE) {
      // HTML comments carry agent instructions and annotations; preserve
      // them as invisible islands instead of letting the parser drop them.
      const parentTag = child.parentElement ? child.parentElement.tagName.toLowerCase() : ""
      const inline = PHRASING_PARENTS.has(parentTag)
      const placeholder = document.createElement(inline ? "ashokan-raw-inline" : "ashokan-raw")
      placeholder.setAttribute("data-html", encodeURIComponent("<!--" + child.data + "-->"))
      child.replaceWith(placeholder)
      continue
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue
    const tag = child.tagName.toLowerCase()
    if (KNOWN_TAGS.has(tag)) {
      preprocess(child)
    } else {
      const parentTag = child.parentElement ? child.parentElement.tagName.toLowerCase() : ""
      const inline = INLINE_RAW_TAGS.has(tag) || PHRASING_PARENTS.has(parentTag)
      const placeholder = document.createElement(inline ? "ashokan-raw-inline" : "ashokan-raw")
      placeholder.setAttribute("data-html", encodeURIComponent(child.outerHTML))
      child.replaceWith(placeholder)
    }
  }
}

function parseBodyHTML(html) {
  const container = document.createElement("div")
  container.innerHTML = html
  preprocess(container)
  return PMDOMParser.fromSchema(schema).parse(container)
}

// ---------------------------------------------------------------------------
// Serialization back to clean body HTML.
// ---------------------------------------------------------------------------

function serializeBodyHTML(doc) {
  const frag = DOMSerializer.fromSchema(schema).serializeFragment(doc.content)
  const wrap = document.createElement("div")
  wrap.appendChild(frag)

  // Preserved HTML comments come back out of their carrier elements.
  for (const carrier of wrap.querySelectorAll("ashokan-comment-node")) {
    const html = decodeURIComponent(carrier.getAttribute("data-html") || "").trim()
    const data = html.startsWith("<!--") && html.endsWith("-->")
      ? html.slice(4, -3)
      : html
    carrier.replaceWith(document.createComment(data))
  }

  // ProseMirror models list items and table cells as containing paragraphs.
  // If the only content is a single attribute-less <p>, unwrap it so
  // `<li>text</li>` round-trips as written instead of gaining a <p>.
  for (const holder of wrap.querySelectorAll("li, td, th")) {
    if (holder.children.length === 1 &&
        holder.children[0].tagName === "P" &&
        holder.children[0].attributes.length === 0 &&
        holder.childNodes.length === 1) {
      const p = holder.children[0]
      p.replaceWith(...p.childNodes)
    }
  }

  // ProseMirror-tables drops thead/tbody wrappers; reconstruct them so
  // stylesheets targeting `thead th` keep working.
  for (const table of wrap.querySelectorAll("table")) {
    const rows = Array.from(table.querySelectorAll(":scope > tr"))
    if (!rows.length) continue
    const headRows = []
    while (rows.length && rows[0].children.length &&
           Array.from(rows[0].children).every(c => c.tagName === "TH")) {
      headRows.push(rows.shift())
    }
    if (headRows.length) {
      const thead = document.createElement("thead")
      headRows.forEach(r => thead.appendChild(r))
      table.insertBefore(thead, table.firstChild)
    }
    if (rows.length) {
      const tbody = document.createElement("tbody")
      rows.forEach(r => tbody.appendChild(r))
      table.appendChild(tbody)
    }
  }

  return Array.from(wrap.childNodes)
    .map(n => {
      if (n.nodeType === Node.ELEMENT_NODE) return n.outerHTML
      if (n.nodeType === Node.COMMENT_NODE) return "<!--" + n.textContent + "-->"
      return n.textContent
    })
    .join("\n")
}

// ---------------------------------------------------------------------------
// Node views: show raw islands as protected, subtly-outlined content.
// ---------------------------------------------------------------------------

function rawNodeView(node) {
  const inline = node.type.name === "html_inline"
  const dom = document.createElement(inline ? "span" : "div")
  dom.className = "ashokan-raw" + (inline ? " ashokan-raw--inline" : "")
  dom.contentEditable = "false"
  dom.innerHTML = node.attrs.html
  dom.title = "Preserved HTML — edit in Source view"
  return { dom }
}

// Image node view: renders the img plus a corner drag-handle that writes the
// chosen width back into the node's attribute bag (plain HTML width attr, so
// it renders identically outside the editor).
function imageNodeView(node, view, getPos) {
  let current = node
  const wrap = document.createElement("span")
  wrap.className = "ashokan-image"
  const img = document.createElement("img")
  const applyAttrs = n => {
    for (const a of Array.from(img.attributes)) img.removeAttribute(a.name)
    for (const [k, v] of Object.entries(n.attrs.attrs || {})) img.setAttribute(k, v)
  }
  applyAttrs(node)
  const handle = document.createElement("span")
  handle.className = "ashokan-image-handle"
  wrap.append(img, handle)

  handle.addEventListener("mousedown", e => {
    e.preventDefault()
    e.stopPropagation()
    const startX = e.clientX
    const startW = img.getBoundingClientRect().width
    const move = ev => {
      img.style.width = Math.max(40, startW + ev.clientX - startX) + "px"
    }
    const up = () => {
      document.removeEventListener("mousemove", move)
      document.removeEventListener("mouseup", up)
      const w = Math.round(img.getBoundingClientRect().width)
      img.style.width = ""
      const attrs = { ...current.attrs.attrs, width: String(w) }
      delete attrs.height
      view.dispatch(view.state.tr.setNodeMarkup(getPos(), null, { attrs }))
    }
    document.addEventListener("mousemove", move)
    document.addEventListener("mouseup", up)
  })

  return {
    dom: wrap,
    update(n) {
      if (n.type !== current.type) return false
      current = n
      applyAttrs(n)
      return true
    },
  }
}

function insertImageFile(file, view) {
  if (!file || !file.type.startsWith("image/")) return false
  const reader = new FileReader()
  reader.onload = () => {
    const attrs = { src: reader.result }
    if (file.name && !file.name.startsWith("image.")) attrs.alt = file.name.replace(/\.[a-z]+$/i, "")
    view.dispatch(imageInsertTr(view.state, attrs).scrollIntoView())
  }
  reader.readAsDataURL(file)
  return true
}

// In suggesting mode the image arrives as a tracked insertion.
function imageInsertTr(state, attrs) {
  const marks = suggesting
    ? [schema.marks.ins.create({ attrs: suggestionBag() })]
    : null
  const node = schema.nodes.image.create({ attrs }, null, marks)
  const tr = state.tr.replaceSelectionWith(node)
  if (suggesting) tr.setMeta(SUGGEST_META, true)
  return tr
}

// ---------------------------------------------------------------------------
// Input rules: Markdown-style shortcuts while typing.
// ---------------------------------------------------------------------------

function buildInputRules() {
  return inputRules({
    rules: [
      textblockTypeInputRule(/^(#{1,6})\s$/, schema.nodes.heading,
        m => ({ level: m[1].length })),
      textblockTypeInputRule(/^```$/, schema.nodes.code_block),
      wrappingInputRule(/^\s*>\s$/, schema.nodes.blockquote),
      wrappingInputRule(/^\s*([-+*])\s$/, schema.nodes.bullet_list),
      wrappingInputRule(/^(\d+)\.\s$/, schema.nodes.ordered_list),
    ],
  })
}

// ---------------------------------------------------------------------------
// Editor setup and the bridge to Swift.
// ---------------------------------------------------------------------------

let view = null
let loading = false
let isMarkdownDoc = false

const turndown = new TurndownService({
  headingStyle: "atx",
  codeBlockStyle: "fenced",
  emDelimiter: "*",
})
turndown.use(gfm)
// Keep constructs Markdown can't express as inline HTML (valid in Markdown).
turndown.keep(["figure", "figcaption", "details", "summary", "ins", "del", "mark", "u", "sub", "sup", "kbd"])

function post(type, payload) {
  try {
    window.webkit.messageHandlers.ashokan.postMessage({ type, ...payload })
  } catch (e) { /* not running inside the app shell */ }
}

function wordCount(doc) {
  const text = doc.textBetween(0, doc.content.size, " ", " ")
  const words = text.trim().split(/\s+/).filter(Boolean)
  return words.length
}

function notifyChange(state) {
  if (loading) return
  const bodyHTML = serializeBodyHTML(state.doc)
  const payload = {
    bodyHTML,
    words: wordCount(state.doc),
    changes: collectChanges(state.doc).length,
    comments: collectComments(state.doc).length,
  }
  if (isMarkdownDoc) payload.markdown = turndown.turndown(bodyHTML)
  post("docChanged", payload)
}

// ---------------------------------------------------------------------------
// Review mode: tracked changes and comments.
//
// Suggesting mode intercepts typing, deletion, and pasting, and records them
// as standard <ins>/<del> markup instead of applying them. Anything it can't
// represent as a suggestion is blocked while suggesting (a strict guarantee:
// no edit sneaks through untracked). Structural Enter is allowed untracked.
// ---------------------------------------------------------------------------

let suggesting = false
let reviewAuthor = ""

function suggestionBag() {
  const bag = { "data-ashokan-ts": new Date().toISOString() }
  if (reviewAuthor) bag["data-ashokan-author"] = reviewAuthor
  return bag
}

const SUGGEST_META = "ashokan-suggestion"

function reviewPlugin() {
  return new Plugin({
    filterTransaction(tr) {
      if (!suggesting || !tr.docChanged) return true
      if (tr.getMeta(SUGGEST_META) || tr.getMeta("history$")) return true
      return false
    },
  })
}

/// True when every inline leaf in [from, to] carries the given mark.
function rangeEntirelyMarked(doc, from, to, markType) {
  let all = true
  doc.nodesBetween(from, to, node => {
    if (node.isInline && !markType.isInSet(node.marks)) all = false
  })
  return all
}

function suggestReplace(view, from, to, text) {
  const { state } = view
  const insType = schema.marks.ins
  const delType = schema.marks.del
  const tr = state.tr
  tr.setMeta(SUGGEST_META, true)

  let insertAt = from
  if (from !== to) {
    if (rangeEntirelyMarked(state.doc, from, to, insType)) {
      // Deleting one's own pending insertion really deletes it.
      tr.delete(from, to)
    } else {
      tr.addMark(from, to, delType.create({ attrs: suggestionBag() }))
      insertAt = to
    }
  }
  if (text) {
    tr.insertText(text, insertAt, insertAt)
    tr.addMark(insertAt, insertAt + text.length, insType.create({ attrs: suggestionBag() }))
    tr.setSelection(TextSelection.create(tr.doc, insertAt + text.length))
  } else if (from !== to && insertAt === to) {
    tr.setSelection(TextSelection.create(tr.doc, to))
  }
  view.dispatch(tr.scrollIntoView())
  return true
}

function suggestDeleteKey(view, forward) {
  const { state } = view
  const { from, to, empty } = state.selection
  if (!empty) return suggestReplace(view, from, to, "")
  const $pos = state.selection.$from
  const target = forward
    ? [from, Math.min(from + 1, $pos.end())]
    : [Math.max(from - 1, $pos.start()), from]
  if (target[0] === target[1]) return true // block-boundary joins stay untracked; swallow
  const insType = schema.marks.ins
  const delType = schema.marks.del
  const tr = state.tr
  tr.setMeta(SUGGEST_META, true)
  if (rangeEntirelyMarked(state.doc, target[0], target[1], insType)) {
    tr.delete(target[0], target[1])
  } else if (rangeEntirelyMarked(state.doc, target[0], target[1], delType)) {
    // Already marked deleted: just step over it.
    tr.setSelection(TextSelection.create(tr.doc, forward ? target[1] : target[0]))
  } else {
    tr.addMark(target[0], target[1], delType.create({ attrs: suggestionBag() }))
    tr.setSelection(TextSelection.create(tr.doc, forward ? target[1] : target[0]))
  }
  view.dispatch(tr.scrollIntoView())
  return true
}

/// Contiguous ins/del runs, in document order.
function collectChanges(doc) {
  const changes = []
  doc.descendants((node, pos) => {
    if (!node.isInline) return
    for (const markName of ["ins", "del"]) {
      const mark = schema.marks[markName].isInSet(node.marks)
      if (!mark) continue
      const last = changes[changes.length - 1]
      if (last && last.type === markName && last.to === pos) {
        last.to = pos + node.nodeSize
      } else {
        changes.push({
          from: pos,
          to: pos + node.nodeSize,
          type: markName,
          author: (mark.attrs.attrs || {})["data-ashokan-author"] || "",
        })
      }
    }
  })
  return changes
}

function collectComments(doc) {
  const comments = []
  doc.descendants((node, pos) => {
    if (!node.isInline) return
    const mark = schema.marks.comment.isInSet(node.marks)
    if (!mark) return
    const last = comments[comments.length - 1]
    if (last && last.to === pos && last.text === ((mark.attrs.attrs || {}).title || "")) {
      last.to = pos + node.nodeSize
    } else {
      const bag = mark.attrs.attrs || {}
      comments.push({
        from: pos,
        to: pos + node.nodeSize,
        text: bag.title || "",
        author: bag["data-ashokan-author"] || "",
      })
    }
  })
  return comments
}

/// Locates an exact quote within a single text block; returns {from, to}.
function findQuote(doc, quote) {
  let result = null
  doc.descendants((node, pos) => {
    if (result) return false
    if (!node.isTextblock) return true
    let text = ""
    const map = []
    node.forEach((child, offset) => {
      if (child.isText) {
        for (let i = 0; i < child.text.length; i++) map.push(pos + 1 + offset + i)
        text += child.text
      } else {
        map.push(-1)
        text += "\u{0}"
      }
    })
    const index = text.indexOf(quote)
    if (index >= 0 && map[index] >= 0) {
      result = { from: map[index], to: map[index + quote.length - 1] + 1 }
    }
    return !result
  })
  return result
}

// ---------------------------------------------------------------------------
// Comments margin: every comment rendered as a card in the right margin,
// aligned with its anchor text, stacked to avoid overlap.
// ---------------------------------------------------------------------------

let commentsMargin = false
let commentRail = null

function setCommentsMargin(on) {
  commentsMargin = !!on
  document.body.classList.toggle("ashokan-comments-margin", commentsMargin)
  layoutCommentMargin()
}

function layoutCommentMargin() {
  if (commentRail) { commentRail.remove(); commentRail = null }
  if (!commentsMargin || !view) return
  const comments = collectComments(view.state.doc)
  if (!comments.length) return

  commentRail = document.createElement("div")
  commentRail.id = "ashokan-comment-rail"
  document.body.appendChild(commentRail)

  let previousBottom = 0
  for (const comment of comments) {
    let anchorTop = 0
    try {
      anchorTop = view.coordsAtPos(comment.from).top + window.scrollY
    } catch (e) { /* position went stale mid-layout */ }

    const card = document.createElement("div")
    card.className = "ashokan-comment-card"
    const author = document.createElement("div")
    author.className = "ashokan-comment-card-author"
    author.textContent = comment.author || "Comment"
    const text = document.createElement("div")
    text.textContent = comment.text
    card.append(author, text)
    card.addEventListener("mousedown", event => {
      event.preventDefault()
      selectRange(comment.from, comment.to)
    })
    commentRail.appendChild(card)
    const top = Math.max(anchorTop, previousBottom + 8)
    card.style.top = top + "px"
    previousBottom = top + card.offsetHeight
  }
}

window.addEventListener("resize", () => layoutCommentMargin())

// ---------------------------------------------------------------------------
// Hover chip: mousing over a tracked change offers accept/reject in place.
// ---------------------------------------------------------------------------

let hoverChip = null
let hoverChange = null
let hoverHideTimer = null

function chipButton(label, tooltip, accept) {
  const button = document.createElement("button")
  button.textContent = label
  button.title = tooltip
  button.className = accept ? "ashokan-chip-accept" : "ashokan-chip-reject"
  button.addEventListener("mousedown", event => {
    event.preventDefault()
    event.stopPropagation()
    if (hoverChange) resolveChange(hoverChange, accept)
    hideHoverChip()
  })
  return button
}

function ensureHoverChip() {
  if (hoverChip) return hoverChip
  hoverChip = document.createElement("div")
  hoverChip.id = "ashokan-change-chip"
  hoverChip.append(
    chipButton("✓", "Accept this change", true),
    chipButton("✕", "Reject this change", false),
  )
  hoverChip.addEventListener("mouseenter", () => clearTimeout(hoverHideTimer))
  hoverChip.addEventListener("mouseleave", scheduleHideHoverChip)
  document.body.appendChild(hoverChip)
  return hoverChip
}

function showHoverChip(element, change) {
  hoverChange = change
  const chip = ensureHoverChip()
  const rect = element.getBoundingClientRect()
  chip.style.display = "flex"
  chip.style.left = Math.max(4, rect.left + window.scrollX) + "px"
  chip.style.top = (rect.top + window.scrollY - 30) + "px"
}

function scheduleHideHoverChip() {
  clearTimeout(hoverHideTimer)
  hoverHideTimer = setTimeout(hideHoverChip, 300)
}

function hideHoverChip() {
  if (hoverChip) hoverChip.style.display = "none"
  hoverChange = null
}

function changeAtOrAfter(items, pos, wrap) {
  if (!items.length) return null
  return items.find(c => c.to > pos) || (wrap ? items[0] : null)
}

function selectRange(from, to) {
  view.dispatch(view.state.tr
    .setSelection(TextSelection.create(view.state.doc, from, to))
    .scrollIntoView())
  view.focus()
}

function resolveChange(change, accept) {
  const tr = view.state.tr
  tr.setMeta(SUGGEST_META, true)
  const keep = (change.type === "ins") === accept
  if (keep) {
    tr.removeMark(change.from, change.to, schema.marks[change.type])
  } else {
    tr.delete(change.from, change.to)
  }
  view.dispatch(tr)
}

function editorKeymap() {
  return keymap({
    "Mod-b": toggleMark(schema.marks.strong),
    "Mod-i": toggleMark(schema.marks.em),
    "Mod-u": toggleMark(schema.marks.underline),
    "Mod-e": toggleMark(schema.marks.code),
    "Mod-z": undo,
    "Shift-Mod-z": redo,
    // In suggesting mode structural splits pass through untracked (with the
    // suggestion meta so the review filter allows them).
    "Enter": (state, dispatch, viewArg) => {
      const wrapped = dispatch && suggesting
        ? (tr => dispatch(tr.setMeta(SUGGEST_META, true)))
        : dispatch
      return chainCommands(
        splitListItem(schema.nodes.list_item),
        newlineInCode, createParagraphNear, liftEmptyBlock, splitBlock
      )(state, wrapped, viewArg)
    },
    "Mod-[": liftListItem(schema.nodes.list_item),
    "Mod-]": sinkListItem(schema.nodes.list_item),
    "Tab": goToNextCell(1),
    "Shift-Tab": goToNextCell(-1),
    "Shift-Enter": chainCommands(exitCode, (state, dispatch) => {
      if (dispatch) {
        dispatch(state.tr.replaceSelectionWith(schema.nodes.hard_break.create()).scrollIntoView())
      }
      return true
    }),
  })
}

function createState(doc) {
  return EditorState.create({
    doc,
    plugins: [
      buildInputRules(),
      editorKeymap(),
      keymap(baseKeymap),
      history(),
      dropCursor(),
      gapCursor(),
      columnResizing(),
      tableEditing(),
      reviewPlugin(),
    ],
  })
}

function mount(doc) {
  const place = document.getElementById("editor")
  if (view) { view.destroy(); view = null }
  view = new EditorView(place, {
    state: createState(doc),
    nodeViews: {
      html_block: rawNodeView,
      html_inline: rawNodeView,
      image: imageNodeView,
    },
    transformPastedHTML(html) {
      const container = document.createElement("div")
      container.innerHTML = html
      preprocess(container)
      return container.innerHTML
    },
    handleClickOn(view, pos, node, nodePos, event, direct) {
      // Clicking a comment highlight surfaces the comment in the app shell.
      const $pos = view.state.doc.resolve(pos)
      const marks = $pos.marks()
      const mark = schema.marks.comment.isInSet(marks)
      if (!mark) return false
      const bag = mark.attrs.attrs || {}
      const coords = view.coordsAtPos(pos)
      post("commentClicked", {
        text: bag.title || "",
        author: bag["data-ashokan-author"] || "",
        left: coords.left, top: coords.top, bottom: coords.bottom,
      })
      return false
    },
    handleTextInput(view, from, to, text) {
      if (!suggesting) return false
      return suggestReplace(view, from, to, text)
    },
    handleKeyDown(view, event) {
      if (!suggesting || event.metaKey || event.altKey || event.ctrlKey) return false
      if (event.key === "Backspace") return suggestDeleteKey(view, false)
      if (event.key === "Delete") return suggestDeleteKey(view, true)
      return false
    },
    handlePaste(view, event) {
      if (!suggesting) return false
      const text = event.clipboardData?.getData("text/plain")
      const { from, to } = view.state.selection
      if (text) suggestReplace(view, from, to, text)
      return true // rich paste can't be tracked; plain text was
    },
    handleDOMEvents: {
      mouseover(view, event) {
        const target = event.target instanceof Element ? event.target.closest("ins, del") : null
        if (!target || !view.dom.contains(target)) return false
        let pos
        try { pos = view.posAtDOM(target, 0) } catch (e) { return false }
        const change = collectChanges(view.state.doc)
          .find(c => c.from <= pos && pos < c.to)
        if (change) {
          clearTimeout(hoverHideTimer)
          showHoverChip(target, change)
        }
        return false
      },
      mouseout(view, event) {
        const target = event.target instanceof Element ? event.target.closest("ins, del") : null
        if (target) scheduleHideHoverChip()
        return false
      },
      paste(view, event) {
        for (const item of event.clipboardData?.items || []) {
          if (item.type.startsWith("image/")) {
            event.preventDefault()
            insertImageFile(item.getAsFile(), view)
            return true
          }
        }
        return false
      },
      drop(view, event) {
        const files = Array.from(event.dataTransfer?.files || [])
          .filter(f => f.type.startsWith("image/"))
        if (!files.length) return false
        event.preventDefault()
        const drop = view.posAtCoords({ left: event.clientX, top: event.clientY })
        if (drop) {
          view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(drop.pos))))
        }
        files.forEach(f => insertImageFile(f, view))
        return true
      },
    },
    dispatchTransaction(tr) {
      const newState = view.state.apply(tr)
      view.updateState(newState)
      if (tr.docChanged) {
        notifyChange(newState)
        layoutCommentMargin()
        hideHoverChip()   // positions are stale after any edit
      }
    },
  })
}

function applyHeadHTML(headHTML) {
  const holder = document.getElementById("ashokan-doc-styles")
  holder.innerHTML = ""
  if (!headHTML) return
  const range = document.createRange()
  range.selectNode(document.head)
  holder.appendChild(range.createContextualFragment(headHTML))
}

function applyBodyAttrs(attrs) {
  const body = document.body
  for (const name of Array.from(body.attributes).map(a => a.name)) {
    if (name.startsWith("data-ashokan")) continue
    body.removeAttribute(name)
  }
  for (const [k, v] of Object.entries(attrs || {})) body.setAttribute(k, v)
}

function run(command) {
  if (!view) return
  view.focus()
  command(view.state, view.dispatch, view)
}

window.Ashokan = {
  // payload: { bodyHTML | markdown, headHTML, bodyAttrs: {..},
  //            hasOwnStyles: bool, isMarkdown: bool }
  loadDocument(payload) {
    loading = true
    try {
      if (payload.author) reviewAuthor = payload.author
      isMarkdownDoc = !!payload.isMarkdown
      const bodyHTML = isMarkdownDoc
        ? marked.parse(payload.markdown || "", { gfm: true })
        : (payload.bodyHTML || "")
      applyHeadHTML(payload.headHTML || "")
      applyBodyAttrs(payload.bodyAttrs || {})
      document.body.classList.toggle("ashokan-default-theme", isMarkdownDoc || !payload.hasOwnStyles)
      mount(parseBodyHTML(bodyHTML))
    } finally {
      loading = false
    }
    layoutCommentMargin()
    if (view) {
      post("stats", {
        words: wordCount(view.state.doc),
        changes: collectChanges(view.state.doc).length,
        comments: collectComments(view.state.doc).length,
      })
    }
  },

  getBodyHTML() {
    return view ? serializeBodyHTML(view.state.doc) : ""
  },

  getMarkdown() {
    return view ? turndown.turndown(serializeBodyHTML(view.state.doc)) : ""
  },

  bold() { run(toggleMark(schema.marks.strong)) },
  italic() { run(toggleMark(schema.marks.em)) },
  underline() { run(toggleMark(schema.marks.underline)) },
  strike() { run(toggleMark(schema.marks.strike)) },
  inlineCode() { run(toggleMark(schema.marks.code)) },

  setHeading(level) { run(setBlockType(schema.nodes.heading, { level })) },
  setParagraph() { run(setBlockType(schema.nodes.paragraph)) },
  toggleCodeBlock() { run(setBlockType(schema.nodes.code_block)) },
  bulletList() { run(wrapInList(schema.nodes.bullet_list)) },
  orderedList() { run(wrapInList(schema.nodes.ordered_list)) },
  blockquote() { run(wrapIn(schema.nodes.blockquote)) },
  lift() { run(lift) },
  horizontalRule() {
    run((state, dispatch) => {
      dispatch(state.tr.replaceSelectionWith(schema.nodes.horizontal_rule.create()).scrollIntoView())
      return true
    })
  },

  setLink(href) {
    if (!href) { run(toggleMark(schema.marks.link)); return }
    run(toggleMark(schema.marks.link, { attrs: { href } }))
  },

  insertImage(src, alt) {
    const attrs = { src }
    if (alt) attrs.alt = alt
    run((state, dispatch) => {
      dispatch(imageInsertTr(state, attrs).scrollIntoView())
      return true
    })
  },

  // mode: "inline" | "left" | "right" | "center"
  alignImage(mode) {
    if (!view) return
    const { selection } = view.state
    const node = selection.node
    if (!node || node.type !== schema.nodes.image) return
    const attrs = { ...node.attrs.attrs }
    let style = (attrs.style || "")
      .split(";").map(s => s.trim())
      .filter(s => s && !/^(float|display|margin)\s*:/.test(s))
      .join("; ")
    const extra = {
      inline: "",
      left: "float: left; margin: 0.3em 1.2em 0.6em 0",
      right: "float: right; margin: 0.3em 0 0.6em 1.2em",
      center: "display: block; margin: 1em auto",
    }[mode] || ""
    style = [style, extra].filter(Boolean).join("; ")
    if (style) attrs.style = style; else delete attrs.style
    view.dispatch(view.state.tr.setNodeMarkup(selection.from, null, { attrs }))
    view.focus()
  },

  insertTable(rows, cols) {
    rows = Math.max(2, rows || 3)
    cols = Math.max(1, cols || 3)
    const { table, table_row, table_cell, table_header } = schema.nodes
    const makeRow = cellType =>
      table_row.create(null, Array.from({ length: cols }, () => cellType.createAndFill()))
    const rowNodes = [makeRow(table_header)]
    for (let r = 1; r < rows; r++) rowNodes.push(makeRow(table_cell))
    run((state, dispatch) => {
      dispatch(state.tr.replaceSelectionWith(table.create(null, rowNodes)).scrollIntoView())
      return true
    })
  },

  tableCommand(name) {
    const commands = {
      addColumnBefore, addColumnAfter, deleteColumn,
      addRowBefore, addRowAfter, deleteRow,
      mergeCells, splitCell, toggleHeaderRow, deleteTable,
    }
    if (commands[name]) run(commands[name])
  },

  undo() { run(undo) },
  redo() { run(redo) },

  focus() { if (view) view.focus() },

  // --- Review mode ---

  setSuggesting(on) { suggesting = !!on },
  isSuggesting() { return suggesting },
  setReviewAuthor(name) { reviewAuthor = name || "" },

  nextChange() {
    if (!view) return
    const change = changeAtOrAfter(collectChanges(view.state.doc), view.state.selection.to, true)
    if (change) selectRange(change.from, change.to)
  },

  previousChange() {
    if (!view) return
    const changes = collectChanges(view.state.doc)
    if (!changes.length) return
    const before = changes.filter(c => c.from < view.state.selection.from)
    const change = before[before.length - 1] || changes[changes.length - 1]
    selectRange(change.from, change.to)
  },

  acceptChange() { this._resolveNearest(true) },
  rejectChange() { this._resolveNearest(false) },

  _resolveNearest(accept) {
    if (!view) return
    const changes = collectChanges(view.state.doc)
    const pos = view.state.selection.from
    const change = changes.find(c => c.from <= pos && pos <= c.to)
      || changeAtOrAfter(changes, pos, true)
    if (change) resolveChange(change, accept)
  },

  acceptAllChanges() { this._resolveAll(true) },
  rejectAllChanges() { this._resolveAll(false) },

  _resolveAll(accept) {
    if (!view) return
    const changes = collectChanges(view.state.doc)
    if (!changes.length) return
    const tr = view.state.tr
    tr.setMeta(SUGGEST_META, true)
    for (const change of changes.slice().reverse()) {
      const keep = (change.type === "ins") === accept
      if (keep) {
        tr.removeMark(change.from, change.to, schema.marks[change.type])
      } else {
        tr.delete(change.from, change.to)
      }
    }
    view.dispatch(tr)
  },

  // --- Comments ---

  addComment(text) {
    if (!view || !text) return
    const { from, to, empty } = view.state.selection
    if (empty) return
    const bag = { ...suggestionBag(), title: text }
    const tr = view.state.tr
    tr.setMeta(SUGGEST_META, true)
    tr.addMark(from, to, schema.marks.comment.create({ attrs: bag }))
    view.dispatch(tr)
    view.focus()
  },

  // Returns {text, author} for the comment at the selection, else null.
  commentAtSelection() {
    if (!view) return null
    const pos = view.state.selection.from
    const comment = collectComments(view.state.doc)
      .find(c => c.from <= pos && pos <= c.to)
    return comment ? { text: comment.text, author: comment.author } : null
  },

  removeComment() {
    if (!view) return
    const pos = view.state.selection.from
    const comment = collectComments(view.state.doc)
      .find(c => c.from <= pos && pos <= c.to)
    if (!comment) return
    const tr = view.state.tr
    tr.setMeta(SUGGEST_META, true)
    tr.removeMark(comment.from, comment.to, schema.marks.comment)
    view.dispatch(tr)
  },

  editComment(newText) {
    if (!view || !newText) return
    const pos = view.state.selection.from
    const comment = collectComments(view.state.doc)
      .find(c => c.from <= pos && pos <= c.to)
    if (!comment) return
    const $pos = view.state.doc.resolve(Math.min(comment.from + 1, comment.to))
    const existing = schema.marks.comment.isInSet($pos.marks())
    const bag = { ...(existing ? existing.attrs.attrs : {}), title: newText }
    const tr = view.state.tr
    tr.setMeta(SUGGEST_META, true)
    tr.removeMark(comment.from, comment.to, schema.marks.comment)
    tr.addMark(comment.from, comment.to, schema.marks.comment.create({ attrs: bag }))
    view.dispatch(tr)
  },

  // --- Agent edits: apply a model's quote-anchored suggestions as tracked
  //     changes. Robust by construction: the document is never regenerated;
  //     each edit is located by its exact quoted text and applied locally. ---

  getDocText() {
    return view ? view.state.doc.textBetween(0, view.state.doc.content.size, "\n", " ") : ""
  },

  // edits: [{quote, replacement?, comment?}]; author labels the suggestions.
  applyAgentEdits(edits, author) {
    if (!view) return { applied: 0, failed: [] }
    let applied = 0
    const failed = []
    for (const edit of edits || []) {
      if (!edit || !edit.quote) continue
      const range = findQuote(view.state.doc, edit.quote)
      if (!range) { failed.push(edit.quote); continue }
      const bag = { "data-ashokan-ts": new Date().toISOString() }
      if (author) bag["data-ashokan-author"] = author
      const tr = view.state.tr
      tr.setMeta(SUGGEST_META, true)
      if (typeof edit.replacement === "string" && edit.replacement !== edit.quote) {
        if (edit.replacement.length) {
          tr.addMark(range.from, range.to, schema.marks.del.create({ attrs: bag }))
          tr.insertText(edit.replacement, range.to, range.to)
          tr.addMark(range.to, range.to + edit.replacement.length,
                     schema.marks.ins.create({ attrs: bag }))
        } else {
          tr.addMark(range.from, range.to, schema.marks.del.create({ attrs: bag }))
        }
      }
      if (edit.comment) {
        tr.addMark(range.from, range.to,
                   schema.marks.comment.create({ attrs: { ...bag, title: edit.comment } }))
      }
      if (tr.steps.length) {
        view.dispatch(tr)
        applied++
      } else {
        failed.push(edit.quote)
      }
    }
    return { applied, failed }
  },

  setCommentsMargin(on) { setCommentsMargin(on) },

  nextComment() {
    if (!view) return
    const comment = changeAtOrAfter(collectComments(view.state.doc), view.state.selection.to, true)
    if (comment) selectRange(comment.from, comment.to)
  },

  previousComment() {
    if (!view) return
    const comments = collectComments(view.state.doc)
    if (!comments.length) return
    const before = comments.filter(c => c.from < view.state.selection.from)
    const comment = before[before.length - 1] || comments[comments.length - 1]
    selectRange(comment.from, comment.to)
  },
}

document.addEventListener("DOMContentLoaded", () => {
  post("ready", {})
})
