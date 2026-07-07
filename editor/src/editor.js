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
import { EditorState, TextSelection } from "prosemirror-state"
import { EditorView } from "prosemirror-view"
import { history, undo, redo } from "prosemirror-history"
import { keymap } from "prosemirror-keymap"
import {
  baseKeymap, toggleMark, setBlockType, wrapIn, lift, chainCommands, exitCode,
} from "prosemirror-commands"
import { wrapInList, splitListItem, liftListItem, sinkListItem } from "prosemirror-schema-list"
import { inputRules, wrappingInputRule, textblockTypeInputRule } from "prosemirror-inputrules"
import { dropCursor } from "prosemirror-dropcursor"
import { gapCursor } from "prosemirror-gapcursor"
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

// Build a real DOM element from preserved raw HTML, for serialization.
function rawElementFor(html, inline) {
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
    parseDOM: ["s", "strike", "del"].map(tag => ({
      tag, getAttrs: d => ({ attrs: bagFromDOM(d) }),
    })),
    toDOM(mark) { return ["s", bagToDOM(mark), 0] },
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
    parseDOM: ["sub", "sup", "small", "mark", "kbd", "abbr", "cite", "dfn", "var", "samp", "time", "q"].map(tag => ({
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
  "a", "strong", "b", "em", "i", "u", "s", "strike", "del", "span",
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
  for (const child of Array.from(root.children)) {
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
    .map(n => n.nodeType === Node.ELEMENT_NODE ? n.outerHTML : n.textContent)
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
    const node = schema.nodes.image.create({ attrs })
    view.dispatch(view.state.tr.replaceSelectionWith(node).scrollIntoView())
  }
  reader.readAsDataURL(file)
  return true
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

function post(type, payload) {
  try {
    window.webkit.messageHandlers.ashokan.postMessage({ type, ...payload })
  } catch (e) { /* not running inside the app shell */ }
}

function notifyChange(state) {
  if (loading) return
  post("docChanged", { bodyHTML: serializeBodyHTML(state.doc) })
}

function editorKeymap() {
  return keymap({
    "Mod-b": toggleMark(schema.marks.strong),
    "Mod-i": toggleMark(schema.marks.em),
    "Mod-u": toggleMark(schema.marks.underline),
    "Mod-e": toggleMark(schema.marks.code),
    "Mod-z": undo,
    "Shift-Mod-z": redo,
    "Enter": splitListItem(schema.nodes.list_item),
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
    handleDOMEvents: {
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
      if (tr.docChanged) notifyChange(newState)
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
  // payload: { bodyHTML, headHTML, bodyAttrs: {..}, hasOwnStyles: bool }
  loadDocument(payload) {
    loading = true
    try {
      applyHeadHTML(payload.headHTML || "")
      applyBodyAttrs(payload.bodyAttrs || {})
      document.body.classList.toggle("ashokan-default-theme", !payload.hasOwnStyles)
      mount(parseBodyHTML(payload.bodyHTML || ""))
    } finally {
      loading = false
    }
  },

  getBodyHTML() {
    return view ? serializeBodyHTML(view.state.doc) : ""
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
      dispatch(state.tr.replaceSelectionWith(schema.nodes.image.create({ attrs })).scrollIntoView())
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
}

document.addEventListener("DOMContentLoaded", () => {
  post("ready", {})
})
