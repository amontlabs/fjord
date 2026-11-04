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
let page = null; // the content script's port, from the adopted tab
let waitingForPage = []; // commands that arrived before the tab had a script

const stamp = (event) => ({ path: null, thread: null, ...event });

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

function toPage(command) {
  try { page.postMessage(command); return true; } catch { pageGone(page); return false; }
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
  if (command.kind === "cancel") {
    const target = waitingForPage.findIndex((queued) => queued.id === command.target);
    if (target >= 0) {
      const [cut] = waitingForPage.splice(target, 1);
      if (TOOL_STEPS.has(cut.kind)) failed(cut, "the step didn't finish");
      return;
    }
  } else {
    for (const queued of waitingForPage.filter((q) => q.kind === command.kind && q.side === command.side)) {
      waitingForPage.splice(waitingForPage.indexOf(queued), 1);
      failed(queued, "superseded");
    }
  }
  queuedAt.set(command, Date.now());
  waitingForPage.push(command);
}

function failed(command, error) {
  toHost(stamp({ type: "done", id: command.id, ok: false, error }));
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
  if (message.kind === "reload_tab") return void findTab().then((tab) => tab && (tab.url === PIN_URL ? chrome.tabs.reload(tab.id) : chrome.tabs.update(tab.id, { url: PIN_URL, active: false }))).catch(() => {});
  // native_host.py sends it each time routerd links: routerd has just started or come back. With no page, routerd is told so, as
  // connectHost does: it links on the first event it gets.
  if (message.kind === "snapshot") {
    if (page) return toPage(message);
    noPage();
    return void ensure().catch(() => {});
  }
  if (message.kind === "wake") return void (page && toPage(message));  // only for a live page: it wakes nothing else, so it is never queued and never opens a tab
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
const ensure = (except) => (ensuring ??= ensureTab(except).finally(() => { ensuring = null; }));

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
    await chrome.storage.session.set({ tabId: tab.id });
  } else if (!atCode(tab.url)) {
    noPage(awayFrom(tab.url));
    return;
  }
  await chrome.tabs.update(tab.id, { autoDiscardable: false }).catch(() => {});
  // Restored after a restart, never loaded: load the projects page, not its last address, which may be a project link.
  if (!page && (tab.discarded || tab.status === "unloaded")) { await chrome.tabs.update(tab.id, { url: PIN_URL, active: false }); return; }
  if (page || tab.status !== "complete") return; // a loading tab gets the manifest's script
  const alive = await chrome.tabs.sendMessage(tab.id, { kind: "hello" }).catch(() => null);  // no answer: no script, or one told to stop (it removed its listener)
  if (!alive?.ok) await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
}

// A second Fjord tab comes from a restart: Chrome restores one, unloaded, while startup makes another. Only tagged tabs go.
async function closeOthers(id) {
  const tabs = await chrome.tabs.query({ url: BASE + "/code*" });
  const extra = tabs.filter((tab) => tab.id !== id && tab.url?.endsWith(TAG)).map((tab) => tab.id);
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

// A page connects. Only the adopted tab stays; any other is told to stop, so its script goes quiet. The listeners come first, so a
// drop while the tab is checked is seen. A check that fails (storage, the tab gone) drops the port: the page connects again later.
chrome.runtime.onConnect.addListener(async (port) => {
  let adopted = false, closed = false;
  // The page is muted from its connect until its snapshot, so nothing arrives before the adoption: an early event is dropped.
  port.onMessage.addListener((event) => { if (adopted) toHost(event); });
  port.onDisconnect.addListener(() => { void chrome.runtime.lastError; closed = true; pageGone(port); });
  const tab = port.sender?.tab;
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
  closeOthers(tab.id);
  port.postMessage({ kind: "tagged" }); // it may have loaded without the tag: it needs it for the next restart
  if (!host) connectHost(false);
  // A command the page didn't take (its port dropped meanwhile: `pageGone`) goes back on the queue with those after it, in order, for the next page.
  const pending = freshCancels(waitingForPage.splice(0));
  const lost = pending.findIndex((command) => !toPage(command));
  if (lost >= 0) waitingForPage.unshift(...pending.slice(lost));
  toPage({ kind: "snapshot" }); // whatever routerd missed while the worker was away
});

// Fjord's tab closed (or lost): it is opened again at once, pinned in the background. Only a removal does it: a navigation (a sign-in
// redirect drops the port each time) must not pull the tab back in a loop. One closed with its window is opened in another normal
// window if there is one; with none it is never opened in a new window you just closed: the next window you open does (`noWindow`).
// With no host linked nothing needs the tab: the host's link opens it. When the browser quits, the host goes and no window is left.
chrome.tabs.onRemoved.addListener(async (id, { isWindowClosing, windowId }) => {
  const { tabId } = await chrome.storage.session.get("tabId");
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
