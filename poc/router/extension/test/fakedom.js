// A minimal DOM for running content.js in node: elements, text, attributes, a small CSS selector engine (type, `*`, `.class`, `#id`,
// `[attr]`, `[attr=v]`, `^=`, `*=`, `$=`, the `i` flag, `:not(…)`, descendant and `>` combinators, comma lists), and the globals the
// script touches at start. Enough for its watch paths; not a browser.
"use strict";

class Text {
  constructor(data) { this.data = String(data); this.parentNode = null; this.nodeType = 3; }
  get textContent() { return this.data; }
  cloneNode() { return new Text(this.data); }
  remove() { this.parentNode?._drop(this); }
}

class Element {
  constructor(tag, doc) {
    this.tagName = tag.toUpperCase(); this.ownerDocument = doc; this.attrs = new Map(); this.childNodes = []; this.parentNode = null;
    this.nodeType = 1; this.clicks = 0; this.srcSets = 0;
  }
  get children() { return this.childNodes.filter((n) => n.nodeType === 1); }
  get parentElement() { return this.parentNode?.nodeType === 1 ? this.parentNode : null; }
  getAttribute(name) { return this.attrs.has(name) ? this.attrs.get(name) : null; }
  setAttribute(name, value) { this.attrs.set(name, String(value)); }
  hasAttribute(name) { return this.attrs.has(name); }
  removeAttribute(name) { this.attrs.delete(name); }
  get name() { return this.getAttribute("name") ?? ""; }
  set name(v) { this.setAttribute("name", v); }
  get src() { return this.getAttribute("src") ?? ""; }
  set src(v) { this.srcSets++; this.setAttribute("src", v); }
  get disabled() { return this.hasAttribute("disabled"); }
  get href() { return new URL(this.getAttribute("href") ?? "", "https://claude.ai").href; }
  get textContent() { return this.childNodes.map((n) => n.textContent).join(""); }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(new Text(v)); }
  get innerText() { return this.textContent; }
  get isConnected() { let n = this; while (n.parentNode) n = n.parentNode; return n === this.ownerDocument; }
  getClientRects() { return this.isConnected ? [{}] : []; }
  focus() { this.ownerDocument.activeElement = this; }
  click() { this.clicks++; this.onclick?.(); }
  appendChild(node) { node.parentNode?._drop(node); node.parentNode = this; this.childNodes.push(node); return node; }
  _drop(node) { const i = this.childNodes.indexOf(node); if (i >= 0) this.childNodes.splice(i, 1); node.parentNode = null; }
  remove() { this.parentNode?._drop(this); }
  cloneNode(deep) {
    const copy = new Element(this.tagName, this.ownerDocument);
    for (const [k, v] of this.attrs) copy.attrs.set(k, v);
    if (deep) for (const child of this.childNodes) copy.appendChild(child.cloneNode(true));
    return copy;
  }
  contains(node) { for (let n = node; n; n = n.parentNode) if (n === this) return true; return false; }
  *_descendants() { for (const child of this.children) { yield child; yield* child._descendants(); } }
  matches(selector) { return compile(selector)(this); }
  closest(selector) { const test = compile(selector); for (let n = this; n && n.nodeType === 1; n = n.parentNode) if (test(n)) return n; return null; }
  querySelectorAll(selector) { const test = compile(selector); return [...this._descendants()].filter(test); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
}

// ---- selectors
function splitTop(text, at) {
  const out = []; let depth = 0, quote = null, start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) { if (c === quote) quote = null; continue; }
    if (c === '"' || c === "'") quote = c;
    else if (c === "[" || c === "(") depth++;
    else if (c === "]" || c === ")") depth--;
    else if (depth === 0 && at(c, i)) { out.push(text.slice(start, i)); start = i + 1; }
  }
  out.push(text.slice(start));
  return out;
}
const cache = new Map();
function compile(selector) {
  if (cache.has(selector)) return cache.get(selector);
  const alts = splitTop(selector, (c) => c === ",").map((s) => s.trim()).filter(Boolean).map(complex);
  const test = (el) => alts.some((alt) => alt(el));
  cache.set(selector, test);
  return test;
}
function complex(text) {
  // Tokens: compounds and combinators, split at depth 0 on whitespace and `>`.
  const parts = []; let buf = "", depth = 0, quote = null, comb = null;
  const push = () => { if (buf.trim()) { parts.push({ test: compound(buf.trim()), comb }); comb = null; } buf = ""; };
  for (const c of text) {
    if (quote) { buf += c; if (c === quote) quote = null; continue; }
    if (c === '"' || c === "'") { quote = c; buf += c; continue; }
    if (c === "[" || c === "(") depth++;
    if (c === "]" || c === ")") depth--;
    if (depth === 0 && (c === " " || c === ">")) { const had = buf.trim(); push(); if (c === ">") comb = ">"; else if (had && comb === null) comb = " "; continue; }
    buf += c;
  }
  push();
  for (let i = 1; i < parts.length; i++) parts[i].comb ??= " ";
  const match = (el, i) => {
    if (!el || el.nodeType !== 1 || !parts[i].test(el)) return false;
    if (i === 0) return true;
    if (parts[i].comb === ">") return match(el.parentElement, i - 1);
    for (let up = el.parentElement; up; up = up.parentElement) if (match(up, i - 1)) return true;
    return false;
  };
  return (el) => match(el, parts.length - 1);
}
function compound(text) {
  const tests = []; let rest = text, m;
  while (rest) {
    if ((m = /^(\*|[a-zA-Z][\w-]*)/.exec(rest))) { const tag = m[1].toUpperCase(); if (tag !== "*") tests.push((el) => el.tagName === tag); }
    else if ((m = /^\.([\w-]+)/.exec(rest))) { const cls = m[1]; tests.push((el) => (el.getAttribute("class") ?? "").split(/\s+/).includes(cls)); }
    else if ((m = /^#([\w-]+)/.exec(rest))) { const id = m[1]; tests.push((el) => el.getAttribute("id") === id); }
    else if ((m = /^\[\s*([\w-]+)\s*(?:([\^*$]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\]\s]+))\s*(i)?)?\s*\]/.exec(rest))) {
      const [, name, op, a, b, c, flag] = m, raw = a ?? b ?? c;
      const norm = (v) => (flag ? v.toLowerCase() : v);
      tests.push((el) => {
        if (!el.hasAttribute(name)) return false;
        if (!op) return true;
        const v = norm(el.getAttribute(name)), want = norm(raw);
        return op === "=" ? v === want : op === "^=" ? v.startsWith(want) : op === "*=" ? v.includes(want) : v.endsWith(want);
      });
    } else if ((m = /^:not\(/.exec(rest))) {
      let depth = 1, i = 5;
      for (; i < rest.length && depth; i++) { if (rest[i] === "(") depth++; if (rest[i] === ")") depth--; }
      const inner = compile(rest.slice(5, i - 1));
      tests.push((el) => !inner(el));
      rest = rest.slice(i);
      continue;
    } else throw new Error(`fakedom: selector not supported: ${text}`);
    rest = rest.slice(m[0].length);
  }
  return (el) => tests.every((t) => t(el));
}

class Document extends Element {
  constructor() {
    super("#document", null);
    this.ownerDocument = this;
    this.documentElement = this.appendChild(new Element("html", this));
    this.body = this.documentElement.appendChild(new Element("body", this));
    this.activeElement = this.body;
  }
  get isConnected() { return true; }
  createElement(tag) { return new Element(tag, this); }
  execCommand() { return false; }
  querySelectorAll(selector) { const test = compile(selector); return [this.documentElement, ...this.documentElement._descendants()].filter(test); }
}

// h("div", {"data-testid": "x"}, child, "text")
function h(doc, tag, attrs = {}, ...children) {
  const el = doc.createElement(tag);
  for (const [k, v] of Object.entries(attrs ?? {})) if (v !== false && v != null) el.setAttribute(k, v === true ? "" : v);
  for (const child of children.flat()) if (child != null) el.appendChild(typeof child === "string" ? new Text(child) : child);
  return el;
}

module.exports = { Document, Element, Text, h };
