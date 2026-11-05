// content.js in a fake DOM: watch mode in frames (identity from window.name after a `?thread=` jump, the overview move, `listed` and
// departures, thread-frame cards and dock, the answer click's guards) and the top frame's frame set (router-watch-and-briefs.md 1, 3.5, 6).
// Run: node content.test.js [case…]; prints one JSON line per case.
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm");
const { Document, h: make } = require("./fakedom");
const SOURCE = fs.readFileSync(path.join(__dirname, "..", "content.js"), "utf8");

// One document with content.js loaded in it. `name`: the window's name (a frame when `frame`). `build(h)` fills the body.
function page({ url, name = "", frame = false, build = () => [] }) {
  const doc = new Document();
  const h = (...a) => make(doc, ...a);
  for (const node of [].concat(build(h))) doc.body.appendChild(node);
  const clock = { t: 1000 };
  let loc = new URL(url);
  const location = {
    get href() { return loc.href; }, get pathname() { return loc.pathname; }, get search() { return loc.search; },
    get hash() { return loc.hash; }, get origin() { return loc.origin; },
  };
  const env = { doc, h, clock, sent: [], pushed: [], popstates: 0, mutations: null, resources: null, onMessage: [], portName: null };
  const history = {
    state: null,
    pushState(state, _t, to) { loc = new URL(to, loc.href); env.pushed.push(loc.pathname + loc.search); this.state = state; },
    replaceState(state, _t, to) { loc = new URL(to, loc.href); this.state = state; },
  };
  const port = {
    postMessage: (m) => env.sent.push(JSON.parse(JSON.stringify(m))),
    disconnect() {},
    onMessage: { addListener: (f) => env.onMessage.push(f) },
    onDisconnect: { addListener() {} },
  };
  const ctx = {
    document: doc, location, history, console: { log() {}, warn() {}, error() {} }, URL, URLSearchParams, JSON, Math, Date, Promise, Map, Set,
    WeakMap, Array, Object, Number, String, Error, RegExp, Symbol,
    CSS: { escape: (s) => String(s).replace(/"/g, '\\"') },
    crypto: { randomUUID: () => "inst-" + Math.random().toString(16).slice(2) },
    performance: { now: () => clock.t, timeOrigin: 1700000000000, getEntriesByType: () => [], memory: { usedJSHeapSize: 123 } },
    setTimeout: () => 0, clearTimeout() {}, queueMicrotask: (f) => Promise.resolve().then(f),
    dispatchEvent: () => { env.popstates++; env.onPop?.(); return true; },
    PopStateEvent: class { constructor(type, init) { this.type = type; this.state = init?.state; } },
    MutationObserver: class { constructor(cb) { env.mutations = cb; } observe(_target, options) { env.observed = options; } disconnect() {} },
    PerformanceObserver: class { constructor(cb) { env.resources = cb; } observe() {} disconnect() {} },
    chrome: { runtime: { id: "ext", connect: ({ name: portName }) => { env.portName = portName; return port; }, onMessage: { addListener() {}, removeListener() {} } } },
  };
  const context = vm.createContext(ctx);
  context.window = context;  // `window` is the global, as in a page: `window !== window.top` tells a frame
  context.top = frame ? {} : context;
  context.name = name;
  vm.runInContext(SOURCE, context);
  env.say = (message) => env.onMessage.forEach((f) => f(message));
  // A flush of the page's observer after a change: `target` the changed node.
  env.flush = (target = doc.body, added = []) => { clock.t += 10; env.mutations([{ target, addedNodes: added }]); };
  env.wake = (ms = 0) => { clock.t += ms; env.say({ kind: "wake" }); };
  env.timeline = (project, end = clock.t) => env.resources({ getEntries: () => [{ name: `https://claude.ai/v1/code/channels/${project}/timeline?limit=200`, startTime: end - 100, responseEnd: end }] });
  env.events = (type) => env.sent.filter((m) => m.type === type);
  env.go = (to) => { loc = new URL(to, loc.href); };
  return env;
}

const tick = () => new Promise((r) => setImmediate(r));
function assert(cond, message) { if (!cond) throw new Error(message); }
function eq(a, b, message) { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`${message}: ${x} !== ${y}`); }

// The overview of a project: its composer, then the thread list.
function overview(h, rows, { ready = true, emptyLine = false } = {}) {
  const active = h("section", { "data-home-section": "active" }, ...rows.filter((r) => r.section === "active").map((r) => row(h, r)),
    emptyLine ? h("section", { "data-testid": "home-empty-band" }, h("div", { "data-home-empty-line": "true" })) : null);
  const running = rows.some((r) => r.section === "running")
    ? h("section", { "data-home-group": "running" }, h("div", { "data-home-section": "running" }, ...rows.filter((r) => r.section === "running").map((r) => row(h, r)))) : null;
  return [
    h("div", { "data-testid": "transcript-sizer" }),
    h("div", { "data-testid": "code-prompt-input" }),
    h("div", { "data-testid": "overview-tab-strip" }),
    running,
    h("section", { "data-home-group": "default" }, h("div", ready ? { "data-home-sort": "priority", "data-home-state": "ready" } : {}, active)),
    h("section", { "data-home-group": "done" }, h("div", { "data-home-section": "done" }, ...rows.filter((r) => r.section === "done").map((r) => row(h, r)))),
  ].filter(Boolean);
}
function row(h, { id, mark = "dashed", spin = false, unread = false }) {
  return h("div", { "data-testid": "overview-thread-row", "data-home-card": id },
    h("span", { "data-home-title": "" }, unread ? h("bdi", { class: "text-prose-semibold" }, "Title ", h("span", { class: "sr-only" }, "unread")) : h("bdi", { class: "text-prose-medium" }, "Title")),
    spin ? h("span", { class: "animate-spin", "data-cds": "Icon" }) : h("span", { "data-home-status-mark": mark }),
    h("time", { datetime: "2026-11-05T10:00:00Z" }, "now"));
}

// A thread view: the project's pane, then the thread's pane with its rows, composer and dock.
// `measured`: the buttons as the page draws them (live, 2026-11-05): a letter, a label and a badge, a consequence line, named by
// `aria-labelledby` and `aria-describedby`; `options` then holds [label, consequence] pairs.
function threadView(h, { card = "cmsg_K", state = null, busy = false, stop = false, options = ["Yes", "No"], measured = false } = {}) {
  const buttons = options.map((text, i) => h("li", {}, measured
    ? h("button", { type: "button", "aria-labelledby": `r-cap-${i} r-label-${i}`, "aria-describedby": `r-badge-${i} r-consequence-${i}` },
      h("span", { id: `r-cap-${i}` }, "AB"[i]),
      h("span", {}, h("span", {}, h("span", { id: `r-label-${i}` }, h("bdi", {}, text[0])), i === 0 ? h("span", { "data-cds": "Badge", id: `r-badge-${i}` }, h("span", {}, "Recommandé")) : null),
        h("span", { id: `r-consequence-${i}` }, h("bdi", {}, text[1]))),
      h("span", {}, h("span", { "data-cds": "Icon", "aria-hidden": "true" }, "")))
    : h("button", { type: "button", ...(busy && i === 0 ? { "aria-busy": "true", "aria-disabled": "true" } : {}) },
      i === 0 ? h("span", { "data-cds": "Badge" }, "Recommended") : null, text)));
  const decision = h("div", { "data-testid": "decision-card", ...(state ? { "data-state": state } : {}) }, h("ul", { role: "list" }, ...buttons));
  return [
    h("div", { id: "project-pane" }, h("div", { "data-testid": "transcript-sizer" }), h("div", { "data-testid": "rail-composer-dock" }, h("div", { "data-testid": "code-prompt-input" }))),
    h("div", { id: "thread-pane" },
      h("div", { "data-testid": "overview-thread-crumb-back" }),
      h("div", { "data-testid": "transcript-sizer" },
        h("div", { "data-testid": "transcript-row", "data-perf-row": "human", "data-index": "0" }, h("div", { "data-entry-key": "cmsg_T" }, h("div", { "data-testid": "user-message" }, "Do it"))),
        h("div", { "data-testid": "transcript-row", "data-perf-row": "assistant", "data-index": "1" }, h("div", { "data-entry-key": card }, h("div", { "data-testid": "assistant-message" }, "Pick one", decision)))),
      h("div", { "data-testid": "rail-composer-dock" }, h("div", { "data-testid": "code-prompt-input" }), stop ? h("button", { "data-testid": "code-prompt-stop" }) : null)),
  ];
}
const cardOf = (env) => env.doc.querySelector('[data-testid="decision-card"]');

const cases = {
  async project_frame_identity_after_thread_jump() {
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_Old", name: "fjord:chan_A:-", frame: true, build: (h) => threadView(h) });
    eq(env.portName, "fjord-frame", "a frame connects as fjord-frame");
    eq(env.sent[0], { type: "frame_hello", name: "fjord:chan_A:-" }, "and speaks first with its name");
    eq(env.pushed, ["/code/project/chan_A"], "it moved itself to the overview at load");
    eq(env.popstates, 1, "with a popstate");
    env.say({ kind: "snapshot" });
    const later = env.sent.slice(1);
    assert(later.length && later.every((m) => JSON.stringify(m.frame) === JSON.stringify({ project: "chan_A", thread: null })), "every event carries its frame from the name");
    assert(!later.some((m) => m.type === "composer" || m.type === "projects"), "a frame says no composer, no projects");
    assert(!later.some((m) => m.type === "rows" && m.side === "thread"), "a project frame says no thread side");
    eq(later[0].type, "commands", "commands first");
  },

  async project_frame_crumb_then_stuck() {
    // The address moved but the page kept showing the thread view: the crumb, once, then frame_stuck.
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_Old", name: "fjord:chan_A:-", frame: true, build: (h) => threadView(h) });
    env.say({ kind: "snapshot" });
    const crumb = env.doc.querySelector('[data-testid="overview-thread-crumb-back"]');
    env.wake(1600);
    eq(crumb.clicks, 1, "the crumb clicked by test id after the grace");
    env.wake(1600);
    env.wake(1600);
    eq(crumb.clicks, 1, "once");
    eq(env.events("frame_stuck").length, 1, "then frame_stuck, once");
  },

  async listed_and_departures() {
    const rows = [{ id: "cmsg_1", section: "active" }, { id: "cmsg_2", section: "running", spin: true }, { id: "cmsg_3", section: "done", mark: "icon" }];
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => overview(h, rows) });
    env.say({ kind: "snapshot" });
    const first = env.events("threads");
    eq(first.map((e) => e.listed), [false], "no listed before this visit's /timeline fetch ended");
    env.clock.t += 50;
    env.timeline("chan_A");
    const listed = env.events("threads").filter((e) => e.listed);
    eq(listed.length, 1, "a listed whole read once loaded by structure");
    eq(listed[0].threads.map((t) => [t.thread, t.state, t.section]), [["cmsg_2", "working", "running"], ["cmsg_1", "paused", "active"], ["cmsg_3", "done", "done"]], "states and sections");
    const n = env.events("threads").length;
    env.doc.querySelector('[data-home-card="cmsg_2"]').remove();
    env.doc.querySelector('[data-home-card="cmsg_3"]').remove();
    env.flush();
    const delta = env.events("threads").slice(n);
    eq(delta.map((e) => [e.threads, e.listed]), [[[{ thread: "cmsg_2", gone: true }], false]], "a departure among others; a done row dropping out says nothing");
  },

  async project_with_no_thread_is_on_its_overview() {
    // Measured live 2026-11-05: a project that never had a thread shows `threads-empty-explainer` and no `data-home-section`.
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => [
      h("div", { "data-testid": "transcript-sizer" }), h("div", { "data-testid": "code-prompt-input" }),
      h("div", { "data-testid": "overview-tab-strip" }), h("div", { "data-testid": "threads-empty-explainer" })] });
    env.say({ kind: "snapshot" });
    for (let i = 0; i < 4; i++) env.wake(1600);
    eq(env.events("frame_stuck").length, 0, "never stuck");
    eq(env.pushed, [], "never moved");
    eq(env.events("threads").filter((e) => e.listed).length, 0, "not listed before this visit's /timeline fetch ended");
    env.clock.t += 50;
    env.timeline("chan_A");
    const listed = env.events("threads").filter((e) => e.listed);
    eq(listed.map((e) => e.threads), [[]], "then listed, with no thread");
  },

  async listed_by_structure_only() {
    // Loading: the tab strip and an empty active section, no rows, no empty line.
    const loading = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => overview(h, [], { ready: false }) });
    loading.say({ kind: "snapshot" }); loading.clock.t += 50; loading.timeline("chan_A");
    eq(loading.events("threads").filter((e) => e.listed).length, 0, "the tab strip alone is not listed");
    // `ready` over done rows only, the active list still loading: not listed.
    const doneOnly = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => {
      const nodes = overview(h, [{ id: "cmsg_9", section: "done", mark: "icon" }], { ready: false });
      nodes.at(-1).firstChild = null;
      const done = nodes.at(-1); const inner = done.children[0]; done.childNodes = [];
      done.appendChild(h("div", { "data-home-sort": "priority", "data-home-state": "ready" }, inner));
      return nodes;
    } });
    doneOnly.say({ kind: "snapshot" }); doneOnly.clock.t += 50; doneOnly.timeline("chan_A");
    eq(doneOnly.events("threads").filter((e) => e.listed).length, 0, "ready on done rows only never passes");
    // Loaded empty: the empty line in `active`, one non-done group.
    const empty = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => overview(h, [{ id: "cmsg_8", section: "done", mark: "icon" }], { ready: false, emptyLine: true }) });
    empty.say({ kind: "snapshot" }); empty.clock.t += 50; empty.timeline("chan_A");
    eq(empty.events("threads").filter((e) => e.listed).map((e) => e.threads.map((t) => t.thread)), [["cmsg_8"]], "an overview with no active thread is listed");
  },

  async thread_frame_cards_and_dock() {
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_T", name: "fjord:chan_A:cmsg_T", frame: true, build: (h) => threadView(h, { stop: true }) });
    eq(env.pushed, [], "a thread frame never moves");
    env.say({ kind: "snapshot" });
    assert(!env.events("threads").length, "a thread frame says no threads");
    const rows = env.events("rows");
    assert(rows.length && rows.every((e) => e.side === "thread"), "only its thread side");
    const card = rows[0].rows.find((r) => r.key === "cmsg_K");
    eq([card.decision, card.answered, card.options], [true, false, ["Yes", "No"]], "a pending card with its options as data");
    eq([rows[0].stop, rows[0].approval], [true, null], "the dock's stop");
    cardOf(env).setAttribute("data-state", "answered");
    cardOf(env).querySelector("ul").remove();
    env.flush(cardOf(env));
    const after = env.events("rows").at(-1).rows.find((r) => r.key === "cmsg_K");
    eq([after.answered, after.options], [true, []], "answered, no controls left");
  },

  async card_options_by_their_references() {
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_T", name: "fjord:chan_A:cmsg_T", frame: true,
      build: (h) => threadView(h, { measured: true, options: [["Red", "This thread replies with exactly Red and stops."], ["Blue", "This thread replies with exactly Blue."]] }) });
    env.say({ kind: "snapshot" });
    const card = env.events("rows")[0].rows.find((r) => r.key === "cmsg_K");
    eq(card.options, ["Red — This thread replies with exactly Red and stops.", "Blue — This thread replies with exactly Blue."], "label — consequence, no letter, no badge");
  },

  async answer_clicks_the_nth_option() {
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_T", name: "fjord:chan_A:cmsg_T", frame: true, build: (h) => threadView(h) });
    env.say({ kind: "snapshot" });
    env.say({ kind: "answer", id: "a1", project: "chan_A", thread: "cmsg_T", card: "cmsg_K", option: 2 });
    eq(env.events("done").length, 0, "waits for the settled read");
    env.wake(1500);
    const buttons = cardOf(env).querySelectorAll("button");
    eq(buttons.map((b) => b.clicks), [0, 1], "option 2 clicked, once");
    eq(env.events("done").map((d) => [d.id, d.ok, d.clicked]), [["a1", true, true]], "done, clicked");
  },

  async answer_guards() {
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_T", name: "fjord:chan_A:cmsg_T", frame: true, build: (h) => threadView(h, { busy: true }) });
    env.say({ kind: "snapshot" });
    env.wake(1500);
    const done = () => env.events("done").map((d) => [d.id, d.ok, d.error]);
    env.say({ kind: "answer", id: "b1", project: "chan_A", thread: "cmsg_T", card: "cmsg_K", option: 1 });
    eq(done(), [], "a busy card is never clicked: it waits");
    assert(cardOf(env).querySelectorAll("button").every((b) => b.clicks === 0), "nothing clicked");
    cardOf(env).setAttribute("data-state", "answered");
    env.flush(cardOf(env));
    eq(done(), [["b1", false, "already answered"]], "then refused once the card shows answered");
    env.say({ kind: "answer", id: "b2", project: "chan_A", thread: "cmsg_T", card: "cmsg_K", option: 1 });
    env.say({ kind: "answer", id: "b3", project: "chan_A", thread: "cmsg_T", card: "cmsg_none", option: 1 });
    env.say({ kind: "answer", id: "b4", project: "chan_A", thread: "cmsg_Other", card: "cmsg_K", option: 1 });
    env.say({ kind: "send", id: "b5", side: "thread", project: "chan_A", thread: "cmsg_T", text: "x" });
    eq(done().slice(1), [["b2", false, "already answered"], ["b3", false, "card gone"], ["b4", false, "not this thread's frame"], ["b5", false, "a watching frame only reports"]], "the guards");
    const env2 = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_T", name: "fjord:chan_A:cmsg_T", frame: true, build: (h) => threadView(h) });
    env2.say({ kind: "snapshot" }); env2.wake(1500);
    env2.say({ kind: "answer", id: "c1", project: "chan_A", thread: "cmsg_T", card: "cmsg_K", option: 5 });
    eq(env2.events("done").map((d) => d.error), ["no such option"], "an option past the last");
    assert(env2.events("done").every((d) => d.refused), "all refused");
  },

  async thread_frame_off_its_thread_is_stuck() {
    const env = page({ url: "https://claude.ai/code/project/chan_A?thread=cmsg_X", name: "fjord:chan_A:cmsg_T", frame: true, build: (h) => threadView(h) });
    env.say({ kind: "snapshot" });
    env.wake(1600);
    eq(env.pushed, [], "never moved");
    eq(env.events("frame_stuck").length, 1, "frame_stuck");
  },

  async top_frame_applies_frames() {
    const env = page({ url: "https://claude.ai/code/projects/browse#fjord", build: () => [] });
    eq(env.portName, "fjord-page-tagged", "the top frame connects as the page");
    env.say({ kind: "snapshot" });
    eq(env.sent.slice(0, 2).map((m) => m.type), ["commands", "frames"], "frames {have} with every snapshot, after commands");
    eq(env.events("frames")[0].have, [], "none yet");
    env.say({ kind: "frames", want: [{ project: "chan_A", thread: null }, { project: "chan_A", thread: "cmsg_T" }], base: true });
    const nodes = () => env.doc.documentElement.children.filter((n) => n.tagName === "IFRAME");
    eq(nodes().map((n) => [n.name, n.src, n.getAttribute("aria-hidden")]), [
      ["fjord:chan_A:-", "https://claude.ai/code/project/chan_A", "true"],
      ["fjord:chan_A:cmsg_T", "https://claude.ai/code/project/chan_A?thread=cmsg_T", "true"]], "iframes on documentElement, named");
    assert(!env.doc.body.children.some((n) => n.tagName === "IFRAME"), "outside the page's root");
    eq(env.events("frames").at(-1).have.map((f) => [f.name, f.project, f.thread]), [["fjord:chan_A:-", "chan_A", null], ["fjord:chan_A:cmsg_T", "chan_A", "cmsg_T"]], "have");
    const kept = nodes()[0];
    env.say({ kind: "frames", want: [{ project: "chan_A", thread: null }], base: false });
    eq(nodes().map((n) => n.name), ["fjord:chan_A:-"], "the thread frame removed");
    assert(nodes()[0] === kept, "the kept one untouched");
    eq(kept.srcSets, 1, "not reloaded");
    env.say({ kind: "reload", frame: { project: "chan_A", thread: null } });
    eq(kept.srcSets, 2, "reload sets its src again");
    env.say({ kind: "answer", id: "t1", project: "chan_A", thread: "cmsg_T", card: "k", option: 1 });
    eq(env.events("done").map((d) => d.error), ["only a frame runs that"], "the top frame never answers");
    assert(env.events("page").at(-1).heap === 123, "the heap rides on the top frame's page");
  },

  async departures_only_from_a_listed_overview() {
    const rows = [{ id: "cmsg_1", section: "active" }, { id: "cmsg_2", section: "running", spin: true }];
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => overview(h, rows) });
    env.say({ kind: "snapshot" });  // no /timeline fetch yet: not listed
    env.doc.querySelector('[data-home-card="cmsg_2"]').remove();
    env.flush();
    assert(!env.events("threads").some((e) => e.threads.some((t) => t.gone)), "a row leaving an overview not yet listed is no departure");
  },

  async a_thread_jump_starts_the_overviews_threads_again() {
    const rows = [{ id: "cmsg_1", section: "active" }, { id: "cmsg_2", section: "running", spin: true }];
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "", build: (h) => overview(h, rows) });
    env.say({ kind: "snapshot" });
    env.clock.t += 50;
    env.timeline("chan_A");
    eq(env.events("threads").filter((e) => e.listed).length, 1, "listed");
    env.go("https://claude.ai/code/project/chan_A?thread=cmsg_2");
    env.flush();
    env.doc.querySelector('[data-home-card="cmsg_2"]').remove();
    env.go("https://claude.ai/code/project/chan_A");
    const n = env.events("threads").length;
    env.flush();
    const back = env.events("threads").slice(n);
    assert(!back.some((e) => e.threads.some((t) => t.gone)), "rows told before the jump make no departure");
    eq(back.filter((e) => e.listed).map((e) => e.threads.map((t) => t.thread)), [["cmsg_1"]], "the arrival's whole listed read says the list");
  },

  async observer_watches_card_and_list_states() {
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => overview(h, []) });
    for (const attr of ["data-state", "aria-busy", "aria-disabled", "data-glyph", "data-home-state"]) {
      assert(env.observed.attributeFilter.includes(attr), attr + " is observed");
    }
  },

  async overview_command_is_gone() {
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "fjord:chan_A:-", frame: true, build: (h) => overview(h, []) });
    env.say({ kind: "snapshot" });
    env.say({ kind: "overview", id: "o1" });
    eq(env.events("done").map((d) => [d.id, d.error]), [["o1", "unknown command"]], "no overview command");
  },

  async foreign_frame_runs_nothing() {
    const env = page({ url: "https://claude.ai/code/project/chan_A", name: "", frame: true, build: (h) => overview(h, []) });
    eq(env.portName, null, "a frame not named by Fjord never connects");
  },
};

(async () => {
  const only = process.argv.slice(2);
  for (const [name, run] of Object.entries(cases)) {
    if (only.length && !only.includes(name)) continue;
    try { await run(); await tick(); console.log(JSON.stringify({ name, ok: true })); }
    catch (error) { console.log(JSON.stringify({ name, ok: false, error: String(error?.stack ?? error).slice(0, 1500) })); }
  }
  process.exit(0);
})();
