// The worker (background.js) against a stubbed `chrome`: the frame port table, routing to frames, frame loads and blanks, the alive check,
// the budget and the handover (router-watch-and-briefs.md 1.2, 1.7, 6). Run: node worker.test.js [case…]; prints one JSON line per case.
"use strict";
const fs = require("fs"), path = require("path"), vm = require("vm");
const SOURCE = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");
const PIN = "https://claude.ai/code/projects/browse#fjord";

function event() {
  const fns = [];
  return { addListener: (f) => fns.push(f), removeListener: (f) => fns.splice(fns.indexOf(f), 1), fire: (...a) => fns.map((f) => f(...a)), fns };
}

function world({ storage = { tabId: 7 }, tabs = [{ id: 7, url: PIN, status: "complete", windowId: 1 }], alive = () => null, inject = async () => [] } = {}) {
  const w = { hostGot: [], created: [], removed: [], injected: [], asked: [], storage: JSON.parse(JSON.stringify(storage)) };
  const tabMap = new Map(tabs.map((t) => [t.id, { ...t }]));
  let nextTab = 8;
  const hostIn = event(), hostDrop = event();
  const ev = {};
  for (const name of ["connect", "startup", "installed", "msg", "alarm", "activated", "removed", "updated", "wcreated", "navDone", "navError"]) ev[name] = event();
  const keys = (k) => (k === undefined ? Object.keys(w.storage) : Array.isArray(k) ? k : [k]);
  w.chrome = {
    runtime: { onConnect: ev.connect, onStartup: ev.startup, onInstalled: ev.installed, onMessage: ev.msg, reload() {}, lastError: undefined,
      connectNative: () => ({ postMessage: (m) => w.hostGot.push(JSON.parse(JSON.stringify(m))), disconnect() {}, onMessage: hostIn, onDisconnect: hostDrop }) },
    alarms: { create() {}, onAlarm: ev.alarm },
    storage: { session: {
      get: async (k) => Object.fromEntries(keys(k).filter((key) => key in w.storage).map((key) => [key, JSON.parse(JSON.stringify(w.storage[key]))])),
      set: async (o) => { Object.assign(w.storage, JSON.parse(JSON.stringify(o))); },
      remove: async (k) => { for (const key of keys(k)) delete w.storage[key]; },
    } },
    tabs: {
      query: async () => [...tabMap.values()],
      get: async (id) => { if (!tabMap.has(id)) throw new Error("no tab"); return { ...tabMap.get(id) }; },
      update: async (id, props) => ({ ...Object.assign(tabMap.get(id) ?? {}, props.url ? { url: props.url } : {}) }),
      create: async (props) => { const tab = { id: nextTab++, url: props.url, status: "loading", windowId: props.windowId ?? 1 }; tabMap.set(tab.id, tab); w.created.push({ ...props, id: tab.id }); return { ...tab }; },
      remove: async (ids) => { for (const id of [].concat(ids)) { if (!tabMap.delete(id)) continue; w.removed.push(id); ev.removed.fire(id, { isWindowClosing: false, windowId: 1 }); } },
      reload: async () => {},
      sendMessage: async (id, message, opts) => { w.asked.push({ id, message, opts }); const r = alive(id, opts); if (!r) throw new Error("no receiver"); return r; },
      onActivated: ev.activated, onRemoved: ev.removed, onUpdated: ev.updated,
    },
    windows: { getAll: async () => [{ id: 1, focused: true, type: "normal" }], onCreated: ev.wcreated },
    scripting: { executeScript: async (opts) => { w.injected.push(JSON.parse(JSON.stringify({ ...opts, func: opts.func ? "func" : undefined }))); return inject(opts); } },
    webNavigation: { onCompleted: ev.navDone, onErrorOccurred: ev.navError },
  };
  w.tabMap = tabMap;
  w.ev = ev;
  w.fromHost = (m) => hostIn.fire(m);
  w.load = () => {
    const ctx = vm.createContext({ chrome: w.chrome, console: { log() {}, warn() {}, error() {} }, setTimeout: (f, ms) => setTimeout(f, Math.min(ms, 30)), clearTimeout, URL, Date, Promise, Map, Set, WeakMap, JSON, Math, Error, Array, Object, Number, String });
    vm.runInContext(SOURCE, ctx);
    return w;
  };
  // A port as the worker sees it: `say` delivers a message from the script, `drop` its disconnect; `got` what the worker posted to it.
  w.port = ({ tab = 7, frameId = 0, documentId = "d" + Math.random(), name = "fjord-page-tagged", url } = {}) => {
    const onMessage = event(), onDisconnect = event();
    const port = { name, sender: { tab: { ...(tabMap.get(tab) ?? { id: tab }), id: tab }, frameId, documentId, url }, got: [], onMessage, onDisconnect,
      postMessage: (m) => port.got.push(JSON.parse(JSON.stringify(m))), disconnect() { port.disconnected = true; },
      say: (m) => onMessage.fire(m), drop: () => onDisconnect.fire() };
    ev.connect.fire(port);
    return port;
  };
  return w;
}

const tick = () => new Promise((r) => setImmediate(r));
const settle = async (n = 30) => { for (let i = 0; i < n; i++) await tick(); };
const kinds = (port) => port.got.map((m) => m.kind);
const typesTo = (w, type) => w.hostGot.filter((m) => m.type === type);
function assert(cond, message) { if (!cond) throw new Error(message); }
function eq(a, b, message) { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`${message}: ${x} !== ${y}`); }

async function adopted(opts) {
  const w = world(opts).load();
  await settle();
  const page = w.port();
  await settle();
  assert(kinds(page).includes("snapshot"), "the top frame is adopted");
  return { w, page };
}
async function frame(w, { tab = 7, frameId = 3, name = "fjord:chan_A:-", url } = {}) {
  const port = w.port({ tab, frameId, name: "fjord-frame", url });
  port.say({ type: "frame_hello", name });
  await settle();
  return port;
}

const cases = {
  async frame_mid_send_leaves_page_alone() {
    const { w, page } = await adopted();
    w.fromHost({ kind: "send", id: "c1", side: "project", project: "chan_A", text: "hi" });
    eq(kinds(page).filter((k) => k === "send").length, 1, "the send went to the page");
    const before = page.got.length, gone = typesTo(w, "page").filter((m) => m.gone).length;
    const f = await frame(w);
    eq(kinds(f), ["snapshot"], "the frame gets its own snapshot only");
    eq(page.got.length, before, "the page got nothing more");
    assert(!page.disconnected, "the page stays adopted");
    eq(typesTo(w, "page").filter((m) => m.gone).length, gone, "no page-gone");
    w.fromHost({ kind: "send", id: "c2", side: "project", project: "chan_A", text: "again" });
    eq(kinds(page).filter((k) => k === "send").length, 2, "the next send goes to the page");
    eq(kinds(f), ["snapshot"], "never to the frame");
    f.say({ type: "page", signed_in: true, page_ok: true, loaded: 5, path: "/code/project/chan_A", thread: null });
    await settle();
    const up = typesTo(w, "page").at(-1);
    eq(up.frame, { project: "chan_A", thread: null, frameId: 3 }, "frame events carry their provenance");
  },

  async answer_routed_and_queued() {
    const { w, page } = await adopted();
    const answer = { kind: "answer", id: "a1", project: "chan_A", thread: "cmsg_T", card: "cmsg_K", option: 2 };
    w.fromHost(answer);
    assert(!kinds(page).includes("answer"), "an answer never goes to the top frame");
    const other = await frame(w, { frameId: 4, name: "fjord:chan_A:-" });
    assert(!kinds(other).includes("answer"), "nor to the project's frame");
    const f = await frame(w, { frameId: 5, name: "fjord:chan_A:cmsg_T" });
    eq(kinds(f), ["answer", "snapshot"], "queued for its frame, sent before its snapshot");
    f.drop();
    await settle();
    eq(typesTo(w, "frame_gone").map((m) => m.frame), [{ project: "chan_A", thread: "cmsg_T", frameId: 5 }], "frame_gone with its frame");
    const again = await frame(w, { frameId: 5, name: "fjord:chan_A:cmsg_T" });
    eq(kinds(again), ["answer", "snapshot"], "an answer with no done goes to the frame's next port");
    again.say({ type: "done", id: "a1", ok: true, clicked: true });
    again.drop();
    await settle();
    const third = await frame(w, { frameId: 5, name: "fjord:chan_A:cmsg_T" });
    eq(kinds(third), ["snapshot"], "a done answer is not sent again");
  },

  async answer_queue_collapses() {
    const { w } = await adopted();
    w.fromHost({ kind: "answer", id: "a1", project: "chan_A", thread: "cmsg_T", card: "k", option: 1 });
    w.fromHost({ kind: "answer", id: "a2", project: "chan_A", thread: "cmsg_T", card: "k", option: 2 });
    eq(typesTo(w, "done").map((m) => [m.id, m.error]), [["a1", "superseded"]], "the older waiting answer is superseded");
    const f = await frame(w, { frameId: 5, name: "fjord:chan_A:cmsg_T" });
    eq(f.got.filter((m) => m.kind === "answer").map((m) => m.id), ["a2"], "only the newer is sent");
  },

  async wake_goes_to_asking_port() {
    const { w, page } = await adopted();
    const f = await frame(w);
    w.fromHost({ kind: "wake", frame: { project: "chan_A", thread: null } });
    eq(kinds(f).filter((k) => k === "wake").length, 1, "the frame's wake to the frame");
    assert(!kinds(page).includes("wake"), "not to the page");
    w.fromHost({ kind: "wake" });
    eq(kinds(page).filter((k) => k === "wake").length, 1, "a wake with no frame to the page");
    eq(kinds(f).filter((k) => k === "wake").length, 1, "and not to the frame");
  },

  async foreign_tab_frames_stopped() {
    const { w } = await adopted({ tabs: [{ id: 7, url: PIN, status: "complete", windowId: 1 }, { id: 9, url: "https://claude.ai/code", status: "complete", windowId: 1 }] });
    const f = await frame(w, { tab: 9 });
    eq(kinds(f), ["stop"], "a frame of another tab is told to stop");
    const odd = await frame(w, { name: "something-else" });
    eq(kinds(odd), ["stop"], "a frame whose name isn't Fjord's is told to stop");
  },

  async identity_after_thread_jump() {
    const names = new Map([[3, "fjord:chan_A:-"]]);
    const { w } = await adopted({ inject: async (opts) => (opts.func ? [{ result: names.get(opts.target.frameIds[0]) }] : []) });
    const f = await frame(w, { url: "https://claude.ai/code/project/chan_A?thread=cmsg_Old" });
    f.say({ type: "rows", side: "project", rows: [], path: "/code/project/chan_A", thread: "cmsg_Old" });
    await settle();
    eq(typesTo(w, "rows").at(-1).frame, { project: "chan_A", thread: null, frameId: 3 }, "named by window.name, not its address");
    w.ev.navDone.fire({ tabId: 7, frameId: 3, parentFrameId: 0, url: "https://claude.ai/code/project/chan_A?thread=cmsg_Old" });
    await settle();
    eq(typesTo(w, "frame_loaded").map((m) => [m.frame, m.frameId]), [[{ project: "chan_A", thread: null, frameId: 3 }, 3]], "frame_loaded by executeScript's window.name");
    const read = w.injected.find((i) => i.func);
    eq(read.target, { tabId: 7, frameIds: [3] }, "the name read in that frame only");
  },

  async worker_never_invents_frames() {
    const { w, page } = await adopted();
    page.say({ type: "page", signed_in: true, page_ok: true, loaded: 100, instance: "i1" });
    page.drop();
    await settle();
    const fresh = w.port();
    await settle();
    fresh.say({ type: "commands", waiting: [], done: [], instance: "i2" });
    fresh.say({ type: "page", signed_in: true, page_ok: true, loaded: 200, instance: "i2" });
    await settle();
    assert(!kinds(page).includes("frames") && !kinds(fresh).includes("frames"), "no frames without the engine");
    const want = [{ project: "chan_A", thread: null }, { project: "chan_B", thread: null }];
    w.fromHost({ kind: "frames", want, base: true });
    eq(fresh.got.filter((m) => m.kind === "frames"), [{ kind: "frames", want, base: true }], "exactly the engine's set, relayed");
  },

  async blank_frames() {
    const { w, page } = await adopted({ inject: async (opts) => { if (opts.func) throw new Error("cannot access a chrome-error page"); return []; } });
    page.say({ type: "frames", have: [{ name: "fjord:chan_A:-", project: "chan_A", thread: null, src: "https://claude.ai/code/project/chan_A" }] });
    await settle();
    w.ev.navDone.fire({ tabId: 7, frameId: 4, parentFrameId: 0, url: "https://claude.ai/code/project/chan_A" });
    await settle();
    eq(typesTo(w, "frame_blank").map((m) => m.frame), [{ project: "chan_A", thread: null, frameId: 4 }], "an unscriptable load is blank, named from have");
    w.ev.navError.fire({ tabId: 7, frameId: 4, parentFrameId: 0, url: "https://claude.ai/code/project/chan_A", error: "net::ERR_ABORTED" });
    await settle();
    eq(typesTo(w, "frame_blank").length, 1, "an aborted load is not blank");
    w.ev.navError.fire({ tabId: 7, frameId: 4, parentFrameId: 0, url: "https://claude.ai/code/project/chan_A", error: "net::ERR_FAILED" });
    await settle();
    eq(typesTo(w, "frame_blank").length, 2, "a failed load is blank at once");
    w.ev.navError.fire({ tabId: 7, frameId: 6, parentFrameId: 0, url: "https://claude.ai/code/project/chan_Z", error: "net::ERR_FAILED" });
    w.ev.navError.fire({ tabId: 9, frameId: 4, parentFrameId: 0, url: "https://claude.ai/code/project/chan_A", error: "net::ERR_FAILED" });
    await settle();
    eq(typesTo(w, "frame_blank").length, 2, "a frame not shown, or of another tab, says nothing");
    w.fromHost({ kind: "frame_inject", frame: { project: "chan_A", thread: null }, frameId: 4 });
    await settle();
    eq(w.injected.filter((i) => i.files && i.target.frameIds).map((i) => i.target), [{ tabId: 7, frameIds: [4] }], "frame_inject injects once into that frame");
  },

  async ensure_tab_alive_check_is_top_frame() {
    // Only a frame's script would answer: asked with {frameId: 0}, nothing answers, so the top frame is injected.
    const w = world({ alive: (_id, opts) => (opts?.frameId === 0 ? null : { ok: true }) }).load();
    await settle(60);
    assert(w.asked.length && w.asked.every((a) => a.opts?.frameId === 0), "the alive check asks frameId 0");
    const inj = w.injected.find((i) => i.files);
    assert(inj, "injected");
    eq(inj.target, { tabId: 7, allFrames: true }, "into every frame");
  },

  async budget_and_handover_wanted() {
    const { w } = await adopted();
    w.fromHost({ kind: "frames", want: [1, 2, 3].map((n) => ({ project: "chan_" + n, thread: null })), base: true });
    await settle();
    eq(typesTo(w, "handover_wanted").length, 0, "a base set counts nothing");
    w.fromHost({ kind: "frames", want: [1, 2, 3].map((n) => ({ project: "chan_" + n, thread: null })).concat([{ project: "chan_1", thread: "t1" }, { project: "chan_1", thread: "t2" }]) });
    await settle();
    eq(w.storage.budget, 2, "two thread frames opened");
    for (let i = 0; i < 3; i++) w.fromHost({ kind: "reload", frame: { project: "chan_2", thread: null } });
    await settle();
    eq(w.storage.budget, 5, "reloads count");
    w.fromHost({ kind: "reload", frame: { project: "chan_3", thread: null } });
    await settle();
    eq(typesTo(w, "handover_wanted").map((m) => m.budget), [6], "wanted at 6");
  },

  async uncounted_reload_wants_handover() {
    const { w, page } = await adopted();
    page.say({ type: "page", signed_in: true, page_ok: true, loaded: 100, instance: "i1" });
    await settle();
    eq(typesTo(w, "handover_wanted").length, 0, "the first document seen is known");
    page.say({ type: "page", signed_in: true, page_ok: true, loaded: 100, instance: "i2" });
    await settle();
    eq(typesTo(w, "handover_wanted").length, 0, "an extension reload keeps the document");
    page.say({ type: "page", signed_in: true, page_ok: true, loaded: 300, instance: "i3" });
    await settle();
    eq(typesTo(w, "handover_wanted").length, 1, "a document the worker didn't load wants a handover");
  },

  async handover_while_old_tab_known() {
    const { w, page } = await adopted();
    const oldFrame = await frame(w);
    w.fromHost({ kind: "handover" });
    await settle();
    eq(w.created.map((c) => [c.url, c.pinned, c.active]), [[PIN, true, false]], "one new pinned, inactive tab");
    const fresh = w.port({ tab: 8 });
    await settle();
    eq(kinds(fresh), ["snapshot"], "the new tab's page is sent a snapshot, never stop");
    fresh.say({ type: "page", signed_in: true, page_ok: true, loaded: 1 });
    w.fromHost({ kind: "send", id: "c3", side: "project", project: "chan_A", text: "meanwhile" });
    assert(kinds(page).includes("send") && !kinds(fresh).includes("send"), "until it takes over, the old page acts");
    eq(typesTo(w, "page").filter((m) => m.loaded === 1).length, 0, "the new page says nothing before its commands");
    fresh.say({ type: "commands", waiting: [], done: [], instance: "i-new" });
    fresh.say({ type: "page", signed_in: true, page_ok: true, loaded: 2, instance: "i-new" });
    await settle();
    eq(typesTo(w, "handover_done"), [{ path: null, thread: null, type: "handover_done", tabId: 8, instance: "i-new" }], "handover_done");
    const order = w.hostGot.map((m) => m.type);
    assert(order.indexOf("commands") < order.indexOf("handover_done"), "its commands come first");
    eq(w.storage.tabId, 8, "tabId re-pointed");
    assert(!("handover" in w.storage), "handover cleared");
    eq(w.removed, [7], "the old tab closed after");
    eq(w.created.length, 1, "no third tab");
    eq(typesTo(w, "frame_gone").length, 0, "the old tab's frames leave without a word");
    oldFrame.drop();
    await settle();
    eq(typesTo(w, "frame_gone").length, 0, "even when their ports drop");
    w.fromHost({ kind: "send", id: "c4", side: "project", project: "chan_A", text: "after" });
    eq(fresh.got.filter((m) => m.kind === "send").map((m) => m.id), ["c4"], "the next send goes to the new page");
    eq(typesTo(w, "page").filter((m) => m.loaded === 2).length, 1, "the new page's events flow");
  },

  async handover_failure_keeps_old() {
    const { w, page } = await adopted();
    w.fromHost({ kind: "handover" });
    await settle();
    const fresh = w.port({ tab: 8 });
    await settle();
    w.fromHost({ kind: "handover_abort" });
    await settle();
    eq(w.removed, [8], "the new tab closed");
    eq(w.storage.tabId, 7, "the old tab stays Fjord's");
    assert(!("handover" in w.storage), "handover cleared");
    fresh.say({ type: "commands", waiting: [], done: [], instance: "late" });
    await settle();
    eq(typesTo(w, "handover_done").length, 0, "a late commands takes nothing over");
    w.fromHost({ kind: "send", id: "c5", side: "project", project: "chan_A", text: "x" });
    assert(kinds(page).includes("send"), "the old page still acts");
    eq(w.created.length, 1, "no other tab");
  },

  async restart_mid_handover_resumes() {
    const tabs = [{ id: 7, url: PIN, status: "complete", windowId: 1 }, { id: 8, url: PIN, status: "complete", windowId: 1 }];
    const w = world({ storage: { tabId: 7, handover: { newTabId: 8, since: 1 } }, tabs, alive: () => null }).load();
    await settle(60);
    assert(w.injected.some((i) => i.files && i.target.tabId === 8 && i.target.allFrames), "the new tab with no script gets one");
    const fresh = w.port({ tab: 8 });
    await settle();
    eq(kinds(fresh), ["snapshot"], "its page isn't stopped");
    fresh.say({ type: "commands", waiting: [], done: [], instance: "n" });
    await settle();
    eq(typesTo(w, "handover_done").length, 1, "and takes over");
    eq(w.storage.tabId, 8, "re-pointed");
  },

  async restart_with_missing_new_tab_clears() {
    const w = world({ storage: { tabId: 7, handover: { newTabId: 8, since: 1 } } }).load();
    await settle(60);
    assert(!("handover" in w.storage), "a handover whose new tab is gone is cleared");
  },
};

(async () => {
  const only = process.argv.slice(2);
  for (const [name, run] of Object.entries(cases)) {
    if (only.length && !only.includes(name)) continue;
    try { await run(); console.log(JSON.stringify({ name, ok: true })); }
    catch (error) { console.log(JSON.stringify({ name, ok: false, error: String(error?.stack ?? error) })); }
  }
  process.exit(0);
})();
