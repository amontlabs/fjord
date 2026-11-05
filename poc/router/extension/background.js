// Relays between Fjord's claude.ai tab and the native host: the page sends events, the host sends commands. It reads nothing of the
// page; it only says when the adopted page's port drops (`pageGone`), and keeps the commands that come while there is no page, collapsed,
// for the next one (`queue`). An open native port keeps this worker alive, so no keepalive is needed while the host is linked; with none,
// the worker may stop, and the reconnect alarm or the page's next connect starts it again.
// The tab is Fjord's own: its id is kept in `storage.session`, which survives the worker's stops but not a browser restart or an extension
// reload (tab ids restart small with the browser, so an old id could name one of your restored tabs); then the tagged tab is found again.
const HOST = "dev.fjord.router";
const BASE = "https://claude.ai";
const PIN_URL = BASE + "/code/projects/browse#fjord";
const TAG = "#fjord";
const atCode = (url) => /^https:\/\/claude\.ai\/code(?:[/?#]|$)/.test(url ?? "");  // the Claude Code page, `/code` itself too

let host = null;
let page = null; // the content script's port, from the adopted tab's top frame (frameId 0)
let waitingForPage = []; // commands that arrived before the tab had a script

const stamp = (event) => ({ path: null, thread: null, ...event });
const session = chrome.storage.session;

// ---- Frames (router-watch-and-briefs.md 1.2). The top frame of Fjord's tab keeps hidden same-origin <iframe>s, one per watched project
// (and per watched thread); each runs content.js in watch mode. A frame's identity is the <iframe>'s `name`, `fjord:<project>:<thread|->`,
// read by its script from `window.name` (`frame_hello`) or by `executeScript` (`frame_loaded`), never from its address: a project frame
// jumps to `?thread=` on load. The set of frames is the engine's alone: the worker relays its `frames` to the top frame and never adds,
// drops or reloads a frame of its own accord.
const parseName = (name) => {
  const m = /^fjord:(chan_[^:]+):([^:]+)$/.exec(name ?? "");
  return m ? { project: m[1], thread: m[2] === "-" ? null : m[2] } : null;
};
const frameKey = (f) => (f ? `${f.project}|${f.thread ?? "-"}` : "");
// Frame ports, keyed `${tabId}:${frameId}:${documentId}` (a frame's documentId changes with each navigation). Each entry:
// { port, key, tabId, frameId, frame: {project, thread, frameId}, inFlight: Map(id -> answer sent there, no `done` yet), dropped }.
const framePorts = new Map();
const waitingForFrame = new Map();  // frameKey -> commands for a frame whose port isn't in the table yet (an `answer`)
const frameOf = new Map();  // `${tabId}:${frameId}` -> frame, as last named (for `frame_blank` after its document failed)
let lastHave = [];  // the top frame's latest `frames {have}`: the nodes it shows, with each one's `name` and `src`

// The latest port for a frame (a new document's port can connect before the old one's drop is seen).
function portFor(key) {
  let found = null;
  for (const entry of framePorts.values()) if (!entry.dropped && frameKey(entry.frame) === key) found = entry;
  return found;
}

// ---- The budget and the handover (1.7). Frame loads grow the renderer and are never given back; the worker counts them per tab and asks
// routerd for a handover (`handover_wanted`) from HANDOVER_AT on, at every further load. State kept across worker stops: `budget`,
// `wantedFrames` (the last `frames {want}` relayed), `createdInstance` (the top document the worker made: {tabId, loaded, expect}), and
// `handover` ({newTabId, since}).
const HANDOVER_AT = 6;
let serial = Promise.resolve();  // budget bookkeeping in arrival order
const inOrder = (work) => (serial = serial.then(work).catch(() => {}));

function countLoads(message) {
  inOrder(async () => {
    const { budget = 0, wantedFrames = [] } = await session.get(["budget", "wantedFrames"]);
    let loads = 0;
    if (message.kind === "frames") {
      const before = new Set(wantedFrames.map(frameKey));
      // A base set is the first set of a new document: it counts nothing (its frames were counted, or are the tab's first).
      if (!message.base) loads = (message.want ?? []).filter((f) => !before.has(frameKey(f))).length;
      await session.set({ wantedFrames: message.want ?? [] });
    } else if (message.kind === "reload") loads = 1;
    if (!loads) return;
    await session.set({ budget: budget + loads });
    if (budget + loads >= HANDOVER_AT) toHost(stamp({ type: "handover_wanted", budget: budget + loads }));
  });
}

// The worker is about to load the top document itself (a new tab, a reload): the next `loaded` is its own.
const expectLoad = (tabId) => session.set({ createdInstance: { tabId, loaded: null, expect: true } });

// A top-frame `page` whose document the worker didn't load (Chrome reloaded the tab, a sign-in came back) means uncounted loads: a
// handover is wanted.
function checkLoaded(event, tabId) {
  if (!event.loaded || tabId === undefined) return;
  inOrder(async () => {
    const { createdInstance: made, budget = 0 } = await session.get(["createdInstance", "budget"]);
    if (made?.tabId === tabId && !made.expect && made.loaded === event.loaded) return;
    if (made?.tabId === tabId && !made.expect) toHost(stamp({ type: "handover_wanted", budget, reloaded: true }));
    await session.set({ createdInstance: { tabId, loaded: event.loaded, expect: false } });
  });
}

// With no host, the event is dropped: the next link's snapshot says what the page shows, and asks again for its wakes still to come.
// `tell`: as connectHost's, false when the event itself tells the host what there is (`pageGone`).
function toHost(event, tell = true) {
  if (!host && !retrying) connectHost(tell);
  try { host?.postMessage(event); } catch { hostLost(); }
}

// The host's port is gone: the reconnect alarm tries again, and until it does nothing else connects (`retrying`).
function hostLost() {
  try { host?.disconnect(); } catch {}  // a port that failed a post may still be open: it is closed, not left behind
  host = null;
  retrying = true;
  chrome.alarms.create("reconnect", { delayInMinutes: 0.5 });
}

// Tells routerd there is no page, and why when the tab says (`away`, `signed_in`): its runs pause with that cause (`do.blocked`).
const noPage = (why = {}) => toHost(stamp({ type: "page", signed_in: null, page_ok: false, ...why }));

// A load is counted when its command reaches the page (`frames`, `reload`), never when it is queued: a superseded one loads nothing.
function toPage(command) {
  try { page.postMessage(command); } catch { pageGone(page); return false; }
  if (command.kind === "frames" || command.kind === "reload") countLoads(command);
  return true;
}

// The page's port dropped (its tab closed, reloaded or navigated away): routerd is told at once, as when there is no page, so its runs
// pause (`do.blocked`) instead of waiting on a page that is gone. A page that connects again says what it shows. `gone`: what routerd
// sent so far went to this page, so the next page's snapshot answers for it (a command it doesn't list was lost with this one); what
// routerd sends from now waits in `waitingForPage`, and reaches the next page before its snapshot does.
function pageGone(port) {
  if (!port || page !== port) return;  // a port that was already replaced says nothing of the adopted page
  page = null;
  toHost(stamp({ type: "page", signed_in: null, page_ok: false, gone: true }), false);  // not a no-page `page` ahead of it
}

// Commands wait here while there is no page, collapsed as the page collapses its waiting steps: a newer command of the same kind on the
// same side replaces a queued one (its `done` says `superseded`), and a `cancel` removes its queued target and isn't queued itself (a
// tool step's `done` says it didn't finish, as the page's cut-off one does; a send or open, cut off, sends none). A cancel whose target
// isn't queued is queued: the target may still wait in the page, whose script outlives its port. When no tab can be had (`ensureTab`
// failed), every queued command but a cancel fails at once (`done` with the error); the cancels wait on, and never get a `done`. A cancel
// queued CANCEL_KEEP_MS ago or more is dropped (`freshCancels`): the page script it was for has long gone quiet or been told since.
const TOOL_STEPS = new Set(["create_project", "set_field", "add_repo", "preapprove_folder", "remove_folder", "read_settings"]);  // content.js's `sequence` steps
const CANCEL_KEEP_MS = 20_000;
const queuedAt = new WeakMap();  // when each queued command was queued
const freshCancels = (commands) => commands.filter((command) => command.kind !== "cancel" || Date.now() - (queuedAt.get(command) ?? 0) < CANCEL_KEEP_MS);
function queue(command) {
  waitingForPage = freshCancels(waitingForPage);
  // A `reload` names a frame of the document that went: it isn't queued (the next document's base set loads every frame anyway).
  if (command.kind === "reload") return;
  if (command.kind === "cancel") {
    const target = waitingForPage.findIndex((queued) => queued.id === command.target);
    if (target >= 0) {
      const [cut] = waitingForPage.splice(target, 1);
      if (TOOL_STEPS.has(cut.kind)) failed(cut, "the step didn't finish");
      return;
    }
  } else {
    // `reload` names its frame: one frame's reload doesn't replace another's. `frames` is the whole set each time: the newer replaces.
    for (const queued of waitingForPage.filter((q) => q.kind === command.kind && q.side === command.side && frameKey(q.frame) === frameKey(command.frame))) {
      waitingForPage.splice(waitingForPage.indexOf(queued), 1);
      failed(queued, "superseded");
    }
  }
  queuedAt.set(command, Date.now());
  waitingForPage.push(command);
}

// A command with no id (`frames`, `reload`) has no `done`: dropped, it is simply gone (the engine sends `frames` whole again for a new document).
function failed(command, error) {
  if (command.id === undefined || command.id === null) return;
  toHost(stamp({ type: "done", id: command.id, ok: false, error }));
}

// ---- Routing down to frames. An `answer` goes to its thread frame's port; with none in the table yet (the engine put the frame in its
// `frames {want}` when it issued the answer) it waits in that frame's list, collapsed as `queue` does (a newer answer replaces an older,
// whose `done` says `superseded`), until the port connects. A `wake` with a `frame` goes to that frame's port, or nowhere.
function postFrame(entry, command) {
  try { entry.port.postMessage(command); } catch { return false; }
  if (command.kind === "answer") entry.inFlight.set(command.id, command);
  return true;
}
function toFrame(command, keep) {
  const key = frameKey(command.frame ?? command);
  const entry = portFor(key);
  if (entry && postFrame(entry, command)) return;
  if (!keep) return;
  const list = waitingForFrame.get(key) ?? [];
  for (const queued of list.filter((q) => q.kind === command.kind)) { list.splice(list.indexOf(queued), 1); failed(queued, "superseded"); }
  list.push(command);
  waitingForFrame.set(key, list);
}
// A cancel of an answer: removed if it still waits here (no `done`, as for a cut-off send), else told to the frame that has it.
function cancelFrame(message) {
  for (const list of waitingForFrame.values()) {
    const at = list.findIndex((queued) => queued.id === message.target);
    if (at >= 0) { list.splice(at, 1); return true; }
  }
  for (const entry of framePorts.values()) {
    if (!entry.inFlight.has(message.target)) continue;
    entry.inFlight.delete(message.target);
    postFrame(entry, message);
    return true;
  }
  return false;
}

// routerd's `frame_inject {frame, frameId}` (its own deadline found no `page` from a loaded frame): inject once. A second miss is blank in
// the engine; a refused injection says nothing more here.
async function inject(message) {
  const { tabId } = await session.get("tabId");
  if (!tabId || !(message.frameId > 0)) return;
  await chrome.scripting.executeScript({ target: { tabId, frameIds: [message.frameId] }, files: ["content.js"] }).catch(() => {});
}

// The Port to the host. When it drops (host missing, crashed or Chrome closed it), the reconnect alarm tries again; while it is pending
// (`retrying`), only it, a startup event or a page's adoption connects, never a message from the page: each try with no page adopted
// tells the host, and with one asks the page for a snapshot, whose events would try again at once, a loop at the pace of a failing host's
// spawn (and each drop would put the alarm off again). What the page says meanwhile is dropped: the next link's snapshot says it all.
// `tell`: false when a page is being adopted, which sends its own snapshot after the events and commands that wait for it (it would
// otherwise be sent twice, the first ahead of them).
let retrying = false;
function connectHost(tell = true) {
  if (host) return;
  retrying = false;
  let mine;
  try { mine = host = chrome.runtime.connectNative(HOST); } catch { hostLost(); return; }  // the alarm tries again, as for a drop
  host.onMessage.addListener(fromHost);
  host.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (host !== mine) return;  // a port already dropped (a failed post) and replaced: the live one stays
    hostLost();
  });
  // Tell the host there is a page, or that there is none, so it never has to ask.
  if (!tell) return;
  if (page) toPage({ kind: "snapshot" });
  else {
    noPage();
    ensure().catch(() => {});
  }
}

function fromHost(message) {
  if (message.kind === "reload_extension") return chrome.runtime.reload();  // a dev step: picks up edited scripts, as the Reload button does
  // A dev step: a fresh page, at the projects page, never a project link. A tab already at PIN_URL is reloaded: an update to the same
  // `#fjord` address would only be a fragment navigation, no load.
  if (message.kind === "reload_tab") return void findTab().then(async (tab) => { if (!tab) return; await expectLoad(tab.id); return tab.url === PIN_URL ? chrome.tabs.reload(tab.id) : chrome.tabs.update(tab.id, { url: PIN_URL, active: false }); }).catch(() => {});
  // native_host.py sends it each time routerd links: routerd has just started or come back. With no page, routerd is told so, as
  // connectHost does: it links on the first event it gets.
  if (message.kind === "snapshot") {
    if (page) return toPage(message);
    noPage();
    return void ensure().catch(() => {});
  }
  // Only for a live page: it wakes nothing else, so it is never queued and never opens a tab. One with a `frame` (the `wake_me` came from a
  // frame) goes to that frame's port; one without, to the top frame.
  if (message.kind === "wake") return void (message.frame ? toFrame(message, false) : page && toPage(message));
  if (message.kind === "answer") return toFrame(message, true);
  if (message.kind === "cancel" && cancelFrame(message)) return;
  if (message.kind === "frame_inject") return void inject(message).catch(() => {});
  if (message.kind === "handover") return void startHandover().catch(() => {});
  if (message.kind === "handover_abort") return void abortHandover().catch(() => {});
  if (page && toPage(message)) return;
  queue(message);
  if (message.kind === "cancel") return;  // kept queued for a page that connects on its own: it opens no tab
  ensure().catch((error) => {
    // No tab to be had: the queued commands fail (routerd opens again at the run's deadline, and fails the run on a second failed open
    // in a row), but a queued cancel stays, since its target may still wait in a page's script, and a cancel has no `done` of its own.
    const cancels = freshCancels(waitingForPage).filter((command) => command.kind === "cancel");
    for (const command of waitingForPage.splice(0)) if (command.kind !== "cancel") failed(command, String(error));
    waitingForPage.push(...cancels);
  });
}

// Fjord's tab: the remembered id, or else the one tagged `#fjord` (after a browser restart or an extension reload, which clear the
// remembered id). Nothing else is adopted.
async function findTab() {
  const { tabId } = await chrome.storage.session.get("tabId");
  const known = tabId ? await chrome.tabs.get(tabId).catch(() => null) : null;
  if (known) return known; // ids stay unique within a browser session, and the session's storage goes with it
  const tagged = (await chrome.tabs.query({ url: BASE + "/code*" })).find((tab) => atCode(tab.url) && tab.url.endsWith(TAG));
  if (tagged) await chrome.storage.session.set({ tabId: tagged.id });
  return tagged ?? null;
}

// Whether a tab is Fjord's: the remembered one, or, when that one is gone, a tagged one, which then becomes the remembered one. A tab
// is tagged only by its address's `#fjord` or by its script's port name, which says the tab loaded with `#fjord` (tag.js) or was told
// it is Fjord's: only the tab the worker made, or one you gave the tag yourself, so your own Claude Code tabs are never adopted.
async function isFjord(tab, tagged) {
  if (!tab) return false;
  const { tabId } = await chrome.storage.session.get("tabId");
  if (tab.id === tabId) return true; // set only from a created or tagged tab, within this browser session
  if (!tagged && !tab.url?.endsWith(TAG)) return false;
  const known = tabId ? await chrome.tabs.get(tabId).catch(() => null) : null;
  if (known) return false;
  await chrome.storage.session.set({ tabId: tab.id });
  return true;
}

// One ensureTab at a time: callers that come while one runs share it, so two never both find no tab and each create one.
let ensuring = null;
const ensure = (except) => (ensuring ??= ensureTab(except).finally(() => { ensuring = null; watchAdoption(); resumeHandover().catch(() => {}); }));

// Nothing may stay stuck without a page (after an extension reload, say): an ensure that failed (a tab not ready, an injection refused) or
// that left no adopted page (a script that never connected, or one dropped) is tried again after a wait that doubles, a bounded number of
// times, each one a one-shot timer (not a poll) that a page's adoption cancels. A tab left away from /code isn't retried: nothing to inject.
const RETRY_MS = 1000, RETRY_MAX = 6;
let retryTimer = null, retries = 0;
function watchAdoption() {
  clearTimeout(retryTimer);
  if (page || retries >= RETRY_MAX) return;
  retryTimer = setTimeout(() => { retries++; ensure().catch(() => {}); }, RETRY_MS * 2 ** retries);
}
const adoptedPage = () => { clearTimeout(retryTimer); retries = 0; };

// Where a tab that left the Claude Code page is, by its address's structure alone: routerd is told why it has no page. A sign-in
// (claude.ai's /login, or another origin: an identity provider) is `signed_in: false`; any other page of claude.ai is `away`.
function awayFrom(url) {
  let at;
  try { at = new URL(url); } catch { return {}; }
  if (at.origin !== BASE) return { signed_in: false };
  return at.pathname.startsWith("/login") ? { signed_in: false } : { away: true };
}

// Finds or creates the tab. A tab without a live script gets one injected, never a reload, so a draft survives. A tab that left the
// Claude Code page (a sign-in, another site) is left alone, never navigated, and routerd is told why (`awayFrom`): no page until it
// comes back, when the manifest's script connects. With no normal window open (you closed the last one), none is opened just to hold
// the tab: the next window (`noWindow`) or the next command tries again. `except`: a window that is closing, which can't hold it.
let noWindow = false;
async function ensureTab(except) {
  let tab = await findTab();
  if (!tab) {
    // The tab opens in the window you work in, never a popup.
    const open = (await chrome.windows.getAll({ windowTypes: ["normal"] }).catch(() => [])).filter((w) => w.id !== except);
    const win = open.find((w) => w.focused) ?? open[0];
    noWindow = !win;
    if (!win) throw new Error("no browser window is open");
    tab = await chrome.tabs.create({ url: PIN_URL, pinned: true, active: false, windowId: win.id });
    await chrome.storage.session.set({ tabId: tab.id, budget: 0, wantedFrames: [] });  // a fresh renderer: its budget starts again
    await expectLoad(tab.id);
  } else if (!atCode(tab.url)) {
    noPage(awayFrom(tab.url));
    return;
  }
  await chrome.tabs.update(tab.id, { autoDiscardable: false }).catch(() => {});
  // Restored after a restart, never loaded: load the projects page, not its last address, which may be a project link.
  if (!page && (tab.discarded || tab.status === "unloaded")) { await expectLoad(tab.id); await chrome.tabs.update(tab.id, { url: PIN_URL, active: false }); return; }
  if (page || tab.status !== "complete") return; // a loading tab gets the manifest's script
  await aliveOrInject(tab.id);
}

// The top frame's script answers `hello`; asked of frameId 0 only, so a frame's script (which never answers it anyway) can't stand in for
// a top frame that has none. No answer: no script, or one told to stop (it removed its listener): inject into every frame (each frame's
// script that is already alive keeps running and the injected copy returns at once).
async function aliveOrInject(tabId) {
  const alive = await chrome.tabs.sendMessage(tabId, { kind: "hello" }, { frameId: 0 }).catch(() => null);
  if (!alive?.ok) await chrome.scripting.executeScript({ target: { tabId, allFrames: true }, files: ["content.js"] });
}

// A tab that was still loading when ensureTab looked (an extension reload during a navigation) gets no script from the manifest if its
// document had already begun: when it completes with no page adopted, it is ensured again.
chrome.tabs.onUpdated.addListener(async (id, change) => {
  const { tabId, handover } = await chrome.storage.session.get(["tabId", "handover"]);
  // A handover's new tab that left the Claude Code page (a sign-in redirect) can't take over: abort, the old tab stays. One that loaded
  // with no script connected gets one.
  if (handover && id === handover.newTabId) {
    if (change.url && !atCode(change.url)) return void abortHandover().catch(() => {});
    if (change.status === "complete" && !handoverPort) resumeHandover().catch(() => {});
    return;
  }
  if (change.status !== "complete" || page) return;
  if (id === tabId) ensure().catch(() => {});
});

// A second Fjord tab comes from a restart: Chrome restores one, unloaded, while startup makes another. Only tagged tabs go.
async function closeOthers(id) {
  const tabs = await chrome.tabs.query({ url: BASE + "/code*" });
  const { handover } = await chrome.storage.session.get("handover");  // a handover's new tab is not an extra
  const extra = tabs.filter((tab) => tab.id !== id && tab.id !== handover?.newTabId && tab.url?.endsWith(TAG)).map((tab) => tab.id);
  if (!extra.length) return;
  // Closing a tab selects a neighbour, which can be Fjord's own: the tab each window showed is put back if it was. When the one it showed
  // was itself a removed extra, the tab it showed before that (`shownTabs`) is, if one is known; else Fjord's stays in front.
  const before = new Map((await chrome.tabs.query({ active: true }).catch(() => [])).map((tab) => [tab.windowId, tab.id]));
  await chrome.tabs.remove(extra).catch(() => {});
  for (const tab of await chrome.tabs.query({ active: true }).catch(() => [])) {
    const prev = before.get(tab.windowId);
    if (tab.id !== id || prev === undefined || prev === id) continue;
    const back = extra.includes(prev) ? (shownTabs.get(tab.windowId) ?? []).findLast((other) => other !== id && !extra.includes(other)) : prev;
    if (back !== undefined && await chrome.tabs.get(back).catch(() => null)) chrome.tabs.update(back, { active: true }).catch(() => {});
  }
}

// The tabs each window last showed, latest last (a few): what `closeOthers` puts back. Only what this worker saw since it started.
const shownTabs = new Map();

// DIAG: says when Fjord's tab becomes the selected one, so a live trace shows when and after what. routerd's handle() sends unknown
// event types through the page's place and rows, so this only warns here and sends nothing. It also keeps `shownTabs`.
chrome.tabs.onActivated.addListener(async ({ tabId, windowId }) => {
  shownTabs.set(windowId, [...(shownTabs.get(windowId) ?? []).filter((other) => other !== tabId), tabId].slice(-8));
  const { tabId: mine } = await chrome.storage.session.get("tabId");
  if (tabId === mine) console.warn("tab_front", { type: "tab_front", windowId, at: Date.now() });
});

// What the adopted top frame says goes to routerd. The worker notes two things on the way: the top frame's `frames {have}` (to tell which
// frame a failed document was, `frame_blank`), and each `page`'s `loaded` (a document the worker didn't load wants a handover).
function fromPage(event, port) {
  if (event?.type === "frames" && Array.isArray(event.have)) {
    lastHave = event.have;
    // a frame no longer shown is named by nothing any more
    const shown = new Set(lastHave.map((h) => frameKey(parseName(h.name))));
    for (const [at, frame] of frameOf) if (!shown.has(frameKey(frame))) frameOf.delete(at);
  }
  if (event?.type === "page") checkLoaded(event, port.sender?.tab?.id);
  toHost(event);
}

// A command the page didn't take (its port dropped meanwhile: `pageGone`) goes back on the queue with those after it, in order, for the next page.
function replayToPage() {
  const pending = freshCancels(waitingForPage.splice(0));
  const lost = pending.findIndex((command) => !toPage(command));
  if (lost >= 0) waitingForPage.unshift(...pending.slice(lost));
}

// A page connects. Only the adopted tab's top frame (frameId 0) is the page; any other tab's is told to stop, so its script goes quiet. A
// frame's port (frameId > 0) goes to the port table (`frameConnected`), never adopted. The handover's new tab is neither stopped nor
// adopted at once: it is sent a snapshot, and adopted on its `commands` (`takeOver`). The listeners come first, so a drop while the tab is
// checked is seen. A check that fails (storage, the tab gone) drops the port: the page connects again later.
chrome.runtime.onConnect.addListener(async (port) => {
  if (port.name === "fjord-frame" || (port.sender?.frameId ?? 0) > 0) return frameConnected(port);
  let adopted = false, closed = false, candidate = null, taking = false;
  const early = [];  // a new tab's events after its `commands`, while the takeover runs
  // The page is muted from its connect until its snapshot, so nothing arrives before the adoption: an early event is dropped.
  port.onMessage.addListener((event) => {
    if (adopted) return fromPage(event, port);
    if (!candidate) return;
    if (taking) return void early.push(event);
    if (event?.type !== "commands" || handoverPort !== port) return;  // an aborted handover's port takes nothing over
    taking = true;
    takeOver(port, candidate, event).then(() => {
      adopted = true;
      for (const later of early.splice(0)) fromPage(later, port);
    }, () => { taking = false; });
  });
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    closed = true;
    if (port === handoverPort) handoverPort = null;
    pageGone(port);
  });
  await handoverReady;
  const tab = port.sender?.tab;
  const { handover } = await session.get("handover").catch(() => ({}));
  if (handover && tab?.id === handover.newTabId) {
    if (closed) return;
    candidate = handover;
    handoverPort = port;
    port.postMessage({ kind: "snapshot" });
    return;
  }
  const mine = await isFjord(tab, port.name === "fjord-page-tagged").catch(() => null);
  if (mine === null) {
    if (!closed) port.disconnect();
    return;
  }
  if (!mine) {
    if (!closed) port.postMessage({ kind: "stop" });
    return;
  }
  if (closed) return;
  chrome.tabs.update(tab.id, { autoDiscardable: false }).catch(() => {});
  // A live page replaced: routerd is told it went (`pageGone`), as when its port drops, so what it sent there is answered by this one's snapshot.
  const old = page;
  pageGone(old);
  old?.disconnect();
  page = port;
  adopted = true;
  adoptedPage();
  closeOthers(tab.id);
  port.postMessage({ kind: "tagged" }); // it may have loaded without the tag: it needs it for the next restart
  if (!host) connectHost(false);
  replayToPage();
  toPage({ kind: "snapshot" }); // whatever routerd missed while the worker was away
});

// ---- The frame ports (1.2). A frame of Fjord's tab (or of the handover's new tab) speaks first with `frame_hello {name}`, its
// `window.name`; its entry is then made, the answers waiting for that frame are sent to it, then its own `snapshot` (so its `commands`
// lists only its own waiting commands and `done`s). Everything it sends goes up stamped with its `frame` ({project, thread, frameId}). A
// frame of any other tab, or one whose name isn't Fjord's, is told to stop. A frame port that drops is removed and reported `frame_gone`,
// its answers not yet done going back to its list for the next port of that frame (whose `commands` then lists them as waiting).
async function frameConnected(port) {
  const { tab, frameId, documentId } = port.sender ?? {};
  let entry = null, checked = false, closed = false;
  const early = [];
  const take = (event) => {
    if (entry) return fromFrame(entry, event);
    if (event?.type !== "frame_hello") return;
    const frame = parseName(event.name);
    if (!frame) { try { port.postMessage({ kind: "stop" }); } catch {} return; }
    entry = { port, key: `${tab.id}:${frameId}:${documentId ?? ""}`, tabId: tab.id, frameId, documentId, frame: { ...frame, frameId }, inFlight: new Map(), dropped: false };
    const key = frameKey(frame);
    // A new document's port can connect before the old one's drop: the old one's answers in flight move here (its document is going).
    const moved = [];
    for (const other of framePorts.values()) {
      if (other.dropped || frameKey(other.frame) !== key) continue;
      moved.push(...other.inFlight.values());
      other.inFlight.clear();
    }
    framePorts.set(entry.key, entry);
    frameOf.set(`${tab.id}:${frameId}`, frame);
    const list = [...moved, ...(waitingForFrame.get(key) ?? [])];
    waitingForFrame.delete(key);
    const lost = list.findIndex((command) => !postFrame(entry, command));
    if (lost >= 0) waitingForFrame.set(key, list.slice(lost));
    try { port.postMessage({ kind: "snapshot" }); } catch {}
  };
  port.onMessage.addListener((event) => (checked ? take(event) : early.push(event)));
  port.onDisconnect.addListener(() => { void chrome.runtime.lastError; closed = true; if (entry) frameGone(entry); });
  await handoverReady;
  const s = await session.get(["tabId", "handover"]).catch(() => null);
  if (closed) return;
  if (!s || !tab || (tab.id !== s.tabId && tab.id !== s.handover?.newTabId)) { try { port.postMessage({ kind: "stop" }); } catch {} return; }
  checked = true;
  for (const event of early.splice(0)) take(event);
}

// Each event goes up with its frame and its document (`documentId`: a `frame_loaded` of a document whose `page` came is no wait).
function fromFrame(entry, event) {
  if (event?.type === "done") entry.inFlight.delete(event.id);
  toHost({ ...stamp(event), frame: entry.frame, ...(entry.documentId ? { documentId: entry.documentId } : {}) });
}

// A port drops. Its answers not done go to the frame's live port if a newer document has one, else back on its list. `frame_gone` is
// said only when no live document of that frame remains.
function frameGone(entry) {
  if (framePorts.get(entry.key) === entry) framePorts.delete(entry.key);
  const key = frameKey(entry.frame);
  const pending = [...entry.inFlight.values()];
  entry.inFlight.clear();
  const live = entry.dropped ? null : portFor(key);
  const lost = live ? pending.filter((command) => !postFrame(live, command)) : pending;
  if (lost.length) waitingForFrame.set(key, [...lost, ...(waitingForFrame.get(key) ?? [])]);
  if (entry.dropped || live) return;  // its tab was handed over, or a newer document of it is live: nothing went
  toHost(stamp({ type: "frame_gone", frame: entry.frame }));
}

// A tab's frames leave the table without a word (a handover: `handover_done` says the document is new; an abort: the new tab's frames).
function dropFramesOf(tabId) {
  for (const entry of [...framePorts.values()]) {
    if (entry.tabId !== tabId) continue;
    entry.dropped = true;
    framePorts.delete(entry.key);
  }
  for (const at of [...frameOf.keys()]) if (at.startsWith(`${tabId}:`)) frameOf.delete(at);
}

// ---- Frame loads (1.2), by `webNavigation`: a frame of Fjord's tab that completed a load is named by `executeScript` (which runs where
// the content script didn't) and reported `frame_loaded`; routerd's own deadline then asks for `frame_inject` when no `page` came from it.
// A frame whose document can't be scripted (a `chrome-error://` page) or whose load failed is `frame_blank`, named by its last known
// name or by the `src` the top frame set (`frames {have}`), never by its address alone; a frame no longer in `have` (removed) says nothing.
const ourTab = async (tabId) => {
  const { tabId: mine, handover } = await session.get(["tabId", "handover"]);
  return tabId === mine || tabId === handover?.newTabId;
};
const sameAddress = (a, b) => { try { return new URL(a, BASE).href === new URL(b, BASE).href; } catch { return false; } };
const framed = (d) => d.frameId > 0 && d.parentFrameId === 0;  // the top frame's own <iframe>s only

function blank(d) {
  const node = lastHave.find((h) => sameAddress(h.src, d.url));
  const frame = frameOf.get(`${d.tabId}:${d.frameId}`) ?? parseName(node?.name);
  if (!frame || !lastHave.some((h) => h.name && frameKey(parseName(h.name)) === frameKey(frame))) return;
  toHost(stamp({ type: "frame_blank", frame: { ...frame, frameId: d.frameId } }));
}

chrome.webNavigation?.onCompleted.addListener(async (d) => {
  if (!framed(d) || !(await ourTab(d.tabId).catch(() => false))) return;
  let name;
  try {
    const [result] = await chrome.scripting.executeScript({ target: { tabId: d.tabId, frameIds: [d.frameId] }, func: () => window.name });
    name = result?.result;
  } catch { name = undefined; }
  if (typeof name !== "string") return blank(d);
  const frame = parseName(name);
  if (!frame || !atCode(d.url)) return;  // not one of Fjord's frames, or its first about:blank
  frameOf.set(`${d.tabId}:${d.frameId}`, frame);
  toHost(stamp({ type: "frame_loaded", frame: { ...frame, frameId: d.frameId }, frameId: d.frameId, ...(d.documentId ? { documentId: d.documentId } : {}) }));
});

chrome.webNavigation?.onErrorOccurred.addListener(async (d) => {
  // An aborted load is a newer navigation of the frame (a `reload`) or its removal, not a failure.
  if (!framed(d) || d.error === "net::ERR_ABORTED" || !(await ourTab(d.tabId).catch(() => false))) return;
  blank(d);
});

// ---- The handover (1.7): a fresh tab takes over from Fjord's grown one, granted by routerd (`handover`).
//   1. A new pinned, inactive tab at PIN_URL; `handover: {newTabId, since}` stored.
//   2. Its top frame connects: neither stopped nor adopted; it is sent a snapshot.
//   3. On its `commands`: `tabId := newTabId`, `handover` cleared, the old page gone (`pageGone`), the new port adopted, `waitingForPage`
//      replayed into it, routerd told `handover_done {tabId, instance}`, then the old tab closed (`onRemoved` sees it isn't `tabId`).
//   4. `handover_abort` (routerd's deadline), or the new tab leaving the Claude Code page: the new tab closed, `handover` cleared, the old
//      tab kept. A worker restart mid-handover reads `handover` and goes on (`resumeHandover`); a new tab that is gone clears it.
let handoverPort = null;  // the new tab's top-frame port, until it is adopted
let handoverReady = Promise.resolve();  // the new tab's creation: a connect waits for it, so the new tab is never told to stop
let takingOver = false;

async function startHandover() {
  const { handover, tabId } = await session.get(["handover", "tabId"]);
  if (handover || takingOver) return;
  const old = tabId ? await chrome.tabs.get(tabId).catch(() => null) : null;
  if (!old) return;  // no tab to hand over: routerd's deadline aborts, and the next page is a new tab anyway
  const making = (async () => {
    const tab = await chrome.tabs.create({ url: PIN_URL, pinned: true, active: false, windowId: old.windowId });
    await session.set({ handover: { newTabId: tab.id, since: Date.now() } });
  })();
  handoverReady = making.catch(() => {});
  await making;
}

async function takeOver(port, handover, commands) {
  takingOver = true;
  try {
    const { tabId: oldId } = await session.get("tabId");
    await session.set({ tabId: handover.newTabId, budget: 0, wantedFrames: [], createdInstance: { tabId: handover.newTabId, loaded: null, expect: true } });
    await session.remove("handover");
    handoverPort = null;
    dropFramesOf(oldId);
    const old = page;
    pageGone(old);
    old?.disconnect();
    page = port;
    adoptedPage();
    chrome.tabs.update(handover.newTabId, { autoDiscardable: false }).catch(() => {});
    port.postMessage({ kind: "tagged" });
    if (!host) connectHost(false);
    toHost(commands);
    replayToPage();
    toHost(stamp({ type: "handover_done", tabId: handover.newTabId, instance: commands.instance ?? null }));
    if (oldId !== undefined && oldId !== handover.newTabId) await chrome.tabs.remove(oldId).catch(() => {});
  } finally {
    takingOver = false;
  }
}

async function abortHandover() {
  await handoverReady;
  const { handover } = await session.get("handover");
  // Checked after the awaits: the new tab may have begun taking over meanwhile, too late to abort (`handover_done` follows).
  if (!handover || takingOver) return;
  const port = handoverPort;
  handoverPort = null;  // at once: its `commands` now takes nothing over
  await session.remove("handover");
  try { port?.disconnect(); } catch {}
  dropFramesOf(handover.newTabId);
  await chrome.tabs.remove(handover.newTabId).catch(() => {});
}

async function resumeHandover() {
  const { handover } = await session.get("handover");
  if (!handover || handoverPort || takingOver) return;
  const tab = await chrome.tabs.get(handover.newTabId).catch(() => null);
  if (!tab) return void (await session.remove("handover"));
  if (tab.status === "complete" && atCode(tab.url)) await aliveOrInject(tab.id).catch(() => {});
}

// Fjord's tab closed (or lost): it is opened again at once, pinned in the background. Only a removal does it: a navigation (a sign-in
// redirect drops the port each time) must not pull the tab back in a loop. One closed with its window is opened in another normal
// window if there is one; with none it is never opened in a new window you just closed: the next window you open does (`noWindow`).
// With no host linked nothing needs the tab: the host's link opens it. When the browser quits, the host goes and no window is left.
// A handover's new tab closed before it took over ends the handover: the old tab stays.
chrome.tabs.onRemoved.addListener(async (id, { isWindowClosing, windowId }) => {
  const { tabId, handover } = await chrome.storage.session.get(["tabId", "handover"]);
  if (handover && id === handover.newTabId && !takingOver) {
    await chrome.storage.session.remove("handover");
    handoverPort = null;
    dropFramesOf(id);
    return;
  }
  if (id !== tabId) return;
  await chrome.storage.session.remove("tabId");
  if (!host) return;
  if (!isWindowClosing) return void ensure().catch(() => {});
  const others = await chrome.windows.getAll({ windowTypes: ["normal"] }).catch(() => []);
  if (others.some((win) => win.id !== windowId)) ensure(windowId).catch(() => {});
  else noWindow = true;
});

// A window opens after one was wanted for the tab (`noWindow`): the tab opens in it, if the host is linked. The wish ends with an
// ensure that worked (a failed one sets it again).
chrome.windows.onCreated.addListener((win) => {
  if (win.type !== "normal" || !noWindow || !host) return;
  ensure().then(() => { noWindow = false; }, () => {});
});

chrome.alarms.onAlarm.addListener(() => connectHost());
chrome.runtime.onStartup.addListener(() => {
  connectHost();
  ensure().catch(() => {});
});
chrome.runtime.onInstalled.addListener(() => {
  connectHost();
  ensure().catch(() => {});
});
connectHost();
