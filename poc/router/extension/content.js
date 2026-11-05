// Watches the page and tells the worker what changed; acts in the real composer when told. Selects by test id and structure,
// never by visible text. No polling: a step runs on each flush of the observer. A step that waits for no page change is woken by routerd
// (`wakeAfter`: `wake_me` / `wake`, which run the scan and the steps; the tab's own `setTimeout(woken)` is only the fallback), since a hidden tab throttles timers. An orphaned instance (its extension reloaded, its runtime gone) stops itself on its next observer, resource or timer callback. A repository search's answer wakes the step through the resource observer.
(() => {
let stopped = false;
// This script's own run in the document: an extension reload keeps the document (and its `loaded`) but injects a fresh script, whose
// `recent` starts empty. Every `page` and `commands` event carries it, so routerd tells the two apart by (`loaded`, `instance`).
const INSTANCE = crypto.randomUUID();
// Watch mode (router-watch-and-briefs.md 1.1): in one of the hidden <iframe>s Fjord's top frame keeps, the script only reports, and runs
// only `wake` and, in a thread frame, `answer`: it never types, never clicks a composer, never opens a place. Its identity is
// the <iframe>'s name, `fjord:<project>:<thread|->` (`window.name`), never its address: a project frame jumps to `?thread=` as it loads.
// A frame whose name isn't Fjord's (the page's own) runs nothing.
const FRAME = window !== window.top;
const parseName = (name) => {
  const m = /^fjord:(chan_[^:]+):([^:]+)$/.exec(name ?? "");
  return m ? { project: m[1], thread: m[2] === "-" ? null : m[2] } : null;
};
const NAME = FRAME ? parseName(window.name) : null;
if (FRAME && !NAME) return;
const THREAD_FRAME = !!NAME?.thread;
const alive =() => { try { return !stopped && !!chrome.runtime.id; } catch { return false; } };
// A script left behind by a reloaded extension can't see its runtime any more, so it doesn't count. It is stopped (observers, waiting
// steps) before this one takes over, in case it still runs in the same isolated world; if a reload doesn't share the world, there is
// nothing to stop and this is harmless.
const older = globalThis.__fjordRouter;
if (older?.alive()) return;
try { older?.stop?.(); } catch { /* a dead instance's failing teardown must not keep this one from starting */ }
globalThis.__fjordRouter = { alive, stop: () => stop() };

const all = (id, root = document) => [...root.querySelectorAll(`[data-testid="${id}"]`)];
const squash = (text) => (text ?? "").replace(/\s+/g, " ").trim();
// Letters and digits only: `textContent` drops the line breaks between an editor's blocks.
const loose = (text) => (text ?? "").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "") || squash(text);

const composers = () => all("code-prompt-input");
const threadParam = () => new URLSearchParams(location.search).get("thread");
const shownProject = () => location.pathname.match(/^\/code\/project\/(chan_[^/]+)/)?.[1] ?? null;

// The project's composer is the first one. In a thread view the second belongs to the thread.
// With a thread open and only one composer mounted, it may be the thread's (its pane mounts first, or a narrow layout shows only it):
// neither side can be told apart yet, so the project side has none.
const halfMounted = () => !!threadParam() && composers().length < 2;

function box(which) {
  const boxes = composers();
  if (which === "thread") return boxes.length >= 2 ? boxes[boxes.length - 1] : null;
  return halfMounted() ? null : boxes[0] ?? null;
}

// Where the page offers no composer, it shows a note in the composer's place (`data-composer-stand-in`, role="note"): an archived
// project's sides show one with a button to unarchive it (measured). A side's note is in the composer's slot `box` would read: the first
// slot for the project side, the last of two for the thread's. Its text goes to routerd as written, as a notice does, never read here.
const standIns = () => [...document.querySelectorAll("[data-composer-stand-in]")];
function standIn(which) {
  const slots = [...document.querySelectorAll('[data-testid="code-prompt-input"], [data-composer-stand-in]')];
  const slot = which === "thread" ? (slots.length >= 2 ? slots.at(-1) : null) : (threadParam() && slots.length < 2 ? null : slots[0]);
  return slot?.hasAttribute("data-composer-stand-in") ? slot : null;
}
function noComposer(note) {
  const copy = note.cloneNode(true);
  copy.querySelectorAll('button, [aria-hidden="true"]').forEach((node) => node.remove());
  const words = squash([...copy.querySelectorAll("*")].filter((node) => !node.children.length).map((node) => node.textContent).join(" "));
  return { ok: false, refused: true, error: `the page shows a note instead of the composer: ${words || squash(copy.textContent)}` };
}

// The Send button that shares the nearest ancestor with the composer, or else the one at the same position.
function sendFor(composer) {
  for (let node = composer?.parentElement; node; node = node.parentElement) {
    const found = all("code-prompt-send", node);
    if (found.length) return found[found.length - 1];
  }
  const index = composers().indexOf(composer);
  return all("code-prompt-send")[index] ?? null;
}

// A row's section is the `data-home-section` of its ancestor (measured: `needs`, `running`, `active`, `done`). `needs` holds rows that
// need you; `running` (in a `data-home-group=running` that exists only while a thread runs) and an `active` row with the spinner are
// working; an `active` row with the `dashed` mark has ended a turn (idle, or waiting on a card: only the thread view tells, so `paused`);
// `done` (the collapsed `data-home-group=done`) is finished. Anything else is unknown.
const ACTIVE_SECTIONS = new Set(["needs", "running", "active"]);
const sectionOf = (row) => (row.closest("[data-home-section]")?.getAttribute("data-home-section") ?? "").toLowerCase() || null;
function rowState(row) {
  const section = sectionOf(row);
  if (section === "needs") return "needs_you";
  if (section === "done") return "done";
  if (section === "running" || (section === "active" && row.querySelector(".animate-spin"))) return "working";
  if (section === "active") return row.querySelector("[data-home-status-mark]")?.getAttribute("data-home-status-mark") === "dashed" ? "paused" : "unknown";
  return "unknown";
}

function rowTitle(row) {
  const title = row.querySelector("[data-home-title]")?.cloneNode(true);
  title?.querySelectorAll('.sr-only, [aria-hidden="true"]').forEach((node) => node.remove());
  return squash(title?.textContent);
}

function readThreads() {
  return all("overview-thread-row").map((row) => {
    const state = rowState(row);
    const line = row.querySelector("[data-home-status-line]");
    return {
      thread: row.getAttribute("data-home-card"),
      title: rowTitle(row),
      state,
      section: sectionOf(row),
      // The page's own read mark, as data (measured: unread is the title as `bdi.text-prose-semibold` with a `span.sr-only`).
      unread: !!row.querySelector("bdi.text-prose-semibold") && !!row.querySelector("span.sr-only"),
      time: row.querySelector("time[datetime]")?.getAttribute("datetime") ?? null,
      needs: squash(line?.innerText) || null,
      text: row.innerText.replace(/\n+/g, " | ").trim(),
    };
  }).filter((row) => row.thread);
}

// Whether the overview's active list is loaded, by structure alone (router-watch-and-briefs.md 2), judged on the active sections only:
// a `data-home-state=ready` that belongs to done rows never passes a still-loading active list. Loaded with rows: a row in `needs`,
// `running` or `active` outside the done group, with a `[data-home-sort=priority][data-home-state=ready]` over it or in its group. Loaded
// empty: `[data-home-section=active]` holding `section[data-testid=home-empty-band]` and `div[data-home-empty-line=true]`, no active row,
// and exactly one non-done `[data-home-group]`. Loaded with no thread ever (live 2026-11-05): `[data-testid=threads-empty-explainer]` in place
// of every `data-home-section`, and no row. Also needed: the project's composer, no thread open, and this visit's `/timeline` fetch
// ended. Only then may a whole `threads` read replace the project's active list (`listed: true`).
// A project that never had a thread shows `threads-empty-explainer` and no `data-home-section` at all (measured live 2026-11-05).
const noThreads = () => !!all("threads-empty-explainer")[0];
function overviewListed() {
  if (threadParam() !== null || !box("project")) return false;
  const project = shownProject();
  if (!timelines.some((t) => t.project === project && t.end >= told.arrived)) return false;
  const active = all("overview-thread-row").filter((row) => ACTIVE_SECTIONS.has(sectionOf(row)) && !row.closest('[data-home-group="done"]'));
  if (active.length) {
    const ready = [...document.querySelectorAll('[data-home-sort="priority"][data-home-state="ready"]')];
    return ready.some((node) => active.some((row) => node.contains(row) || !!row.closest("[data-home-group]")?.contains(node)));
  }
  if (noThreads()) return !all("overview-thread-row").length;
  const section = document.querySelector('[data-home-section="active"]');
  if (!section?.querySelector('section[data-testid="home-empty-band"]') || !section.querySelector('[data-home-empty-line="true"]')) return false;
  return [...document.querySelectorAll("[data-home-group]")].filter((group) => group.getAttribute("data-home-group") !== "done").length === 1;
}

// In a thread view, the thread's part of the page: the lowest ancestor of the thread's composer that does not also hold the project's
// composer. Null without two composers.
function threadScope() {
  const boxes = composers();
  if (boxes.length < 2) return null;
  let scope = null;
  for (let node = boxes[boxes.length - 1].parentElement; node; node = node.parentElement) {
    if (node.contains(boxes[0])) break;
    scope = node;
  }
  return scope;
}

// Rows of the project chat, or of the thread when `thread` is set. In a thread view the thread's rows are the ones in `threadScope`.
function chatRows(thread) {
  const rows = all("transcript-row");
  if (halfMounted()) return null;  // whose rows these are can't be told yet
  if (composers().length < 2) return thread ? [] : rows;
  const scope = threadScope();
  const inThread = scope ? rows.filter((row) => scope.contains(row)) : [];
  return thread ? inThread : rows.filter((row) => !inThread.includes(row));
}

// A side's transcript, once mounted: its column's container (`transcript-sizer`, which holds the rows), in the side's part of the page.
// The page can mount a composer before its transcript, so until then a side with no rows isn't known to be empty.
function sizerOf(thread) {
  if (halfMounted()) return null;
  const scope = threadScope(), sizers = all("transcript-sizer");
  return (thread ? scope && sizers.find((node) => scope.contains(node)) : sizers.find((node) => !scope?.contains(node))) ?? null;
}

// The settle wake each side has pending (when it is due, `performance.now()`; 0 for none). A side asks for one only when none is
// pending or the new one is due sooner: a pending one due earlier runs the scan, which asks again for what is still owed then, so the
// many scans of a render ask routerd for one `wake_me` rather than one each. Every wake clears them (`woken`): its scan asks again.
const settleWakes = { project: 0, thread: 0 };
function settleWake(side, ms) {
  const due = performance.now() + ms, pending = settleWakes[side];
  if (pending > performance.now() && pending <= due) return;
  settleWakes[side] = due;
  wakeAfter(ms);
}

// Whether a side with no rows is known to be empty. The page can mount the sizer before its rows, and show a placeholder in it while
// loading, so a mounted, quiet sizer alone isn't enough. On the project side the chat's own rows must have come: a fetch of its
// channel's `/timeline` that ended since the arrival on the page (`told.arrived`, as `settledRows`: a fetch from an earlier visit is no
// sign of this one's rows). Then that fetch's render must be over: a flush after it that touched the sizer (the render of the rows it
// fetched: an unrelated flush elsewhere in the page is no render), or RENDER_GRACE with no change in it since both that fetch and its
// last change (`since`) (an empty chat's render can change no DOM; the wake armed here runs the scan then, and the fetch's report scans
// at once, which arms it; only while the whole read is owed, `whole`: a side already told needs no settled read, and its bookkeeping
// alone goes on). Rows the page renders into it make the side not empty. The thread side can't be tied to its data: content.js never
// learns the thread's session id (the address and the row name only its `cmsg_` key), and another session's `/v1/sessions/<id>/events`
// can't be told from its own, so it keeps the flush rule: a later flush that doesn't touch the sizer, or the same grace, since its last
// change or when it was first seen (`mounted`) (routerd refuses an empty thread anyway: a thread always has its opening message). Until
// then no rows is the page still loading, and an empty baseline would make an old row of yours look new. A chat whose rows are never
// fetched since the arrival stays unknown, and the run's deadline (or routerd's `fresh` open) covers it.
function settledEmpty(side, now, sizer, whole) {
  if (now.length || !sizer) { told.quiet[side] = null; return false; }
  let quiet = told.quiet[side];
  // `changed` starts when it is first seen, so even the scan at start waits for a flush or the grace.
  if (quiet?.sizer !== sizer) quiet = told.quiet[side] = { sizer, mounted: lastFlush.at, changed: performance.now() };
  const touched = lastFlush.nodes.some((node) => node === sizer || sizer.contains(node)) || lastFlush.added.some((node) => node === sizer || node.contains(sizer));
  if (touched) quiet.changed = Math.max(quiet.changed, lastFlush.at);
  const project = shownProject();
  const fetched = side === "thread" ? quiet.mounted
    : Math.max(-Infinity, ...timelines.filter((t) => t.project === project && t.end >= told.arrived).map((t) => t.end));
  if (fetched === -Infinity) return false;  // its rows haven't come: the fetch's report runs the scan again
  const since = Math.max(fetched, quiet.changed);
  if (side === "thread" ? lastFlush.at > since && !touched : touched && lastFlush.at > fetched) return true;
  if (performance.now() - since >= RENDER_GRACE) return true;
  if (whole) settleWake(side, Math.max(0, RENDER_GRACE - (performance.now() - since)) + 50);
  return false;
}

// Whether a side's whole read with rows is its render done (`settled` on the event). A first render can lack the bottom rows, and routerd
// baselines a send to a chat it stores no rows of only from a settled read: an old row of yours in the next delta would look new. The
// rule is `settledEmpty`'s: on the project side a `/timeline` fetch of the chat must have ended since this arrival on the page
// (`told.arrived`: a re-open shows the page's cached rows at once, and a fetch from an earlier visit lacks the rows added while away,
// measured: that one is ~3 s old, this visit's ends ~0.33 s after the open), the rows having come with the first render being no
// sign; then a flush that touched the sizer after the latest such fetch ended (the render of what it fetched), or SETTLE_GRACE with no
// change in the sizer since the later of that fetch's end and its last change (or when it was first seen) (the fetch's report scans at
// once, and the wake armed here runs the scan then, armed only while the whole read is owed, `whole`: the change bookkeeping runs on
// every scan, but a side already told waits for nothing); on the thread side a later flush that doesn't touch the sizer, or RENDER_GRACE
// since its last change, or a last row that is `streaming` (the live reply is the bottom, and its flushes keep touching the sizer, so
// neither rule would hold until it ends). Before any such fetch ended it arms no wake: the fetch's report scans. A read that isn't
// settled leaves the whole read owed, so a later scan (a flush, the fetch's report, or the grace's wake) sends it again, settled. A chat
// whose rows are never fetched after the arrival stays unsettled until routerd's `fresh` open makes the page fetch them, else the run's
// deadline covers it.
function settledRows(side, sizer, rows, whole) {
  if (!sizer) return false;
  if (side === "thread" && rows.at(-1)?.streaming) return true;
  let quiet = told.settle[side];
  if (quiet?.sizer !== sizer) quiet = told.settle[side] = { sizer, changed: performance.now() };
  const touched = lastFlush.nodes.some((node) => node === sizer || sizer.contains(node)) || lastFlush.added.some((node) => node === sizer || node.contains(sizer));
  if (touched) quiet.changed = Math.max(quiet.changed, lastFlush.at);
  const project = shownProject();
  const fetched = side === "thread" ? -Infinity
    : Math.max(-Infinity, ...timelines.filter((t) => t.project === project && t.end >= told.arrived).map((t) => t.end));
  if (side === "project" && fetched === -Infinity) return false;  // this visit's rows haven't come: the fetch's report runs the scan again
  const since = Math.max(fetched, quiet.changed);
  if (side === "thread" ? lastFlush.at > since && !touched : touched && lastFlush.at > fetched) return true;
  const grace = side === "project" ? SETTLE_GRACE : RENDER_GRACE;
  if (performance.now() - since >= grace) return true;
  if (whole) settleWake(side, Math.max(0, grace - (performance.now() - since)) + 50);
  return false;
}
// The page renders a fetch's rows within ms of its end, even in a hidden tab (React's scheduler isn't timer-paced): a re-opened chat
// whose fetch changed nothing on screen is settled this long after it, rather than RENDER_GRACE (measured: switching sends' worst case
// went from 3.4 s to 1.7 s; the median stays ~1.0 s, the wait for the visit's own /timeline fetch).
const SETTLE_GRACE = 300;


// A row's message, without what only screen readers see, the times, and the day divider, which follow the page's language. The first
// row of a day carries that divider ("Aujourd’hui", "Hier") as a separator inside it (measured: it was read into the message's words).
function messageText(row) {
  const copy = (row.querySelector('[data-testid="assistant-message"], [data-testid="user-message"]') ?? row).cloneNode(true);
  copy.querySelectorAll('.sr-only, time, button, [aria-hidden="true"], [role="status"], [aria-live], [aria-busy="true"], [role="separator"], hr').forEach((node) => node.remove());
  // What a message holds but doesn't show as its words, by structure: math's markup copies, icons, code that isn't text, hidden and
  // closed parts, a folded details' body, and a decision card (the row says it has one: `decision`).
  copy.querySelectorAll('math, annotation, .katex-mathml, svg, style, script, template, noscript, [hidden], [inert], [data-closed], details:not([open]) > :not(summary), [data-testid="decision-card"]').forEach((node) => node.remove());
  return copy.textContent.replace(/[\ue000-\uf8ff]/g, "").trim();
}

// A row's id is the `data-entry-key` of a descendant: `cmsg_…` once the server has it, `cmsg_pending_…` for a message you just sent and
// `provisional:…` for a reply being written. `data-index` is only a position and is renumbered on reload.
const PENDING = ["cmsg_pending_", "provisional:"];

// `data-perf-row` is "assistant" for Claude, "human" for you, "marker" for rows that aren't messages.
// A message's key starts with its project's id (`cmsg_<id of chan_<id>>…`, true of every key seen). Right after the address
// changes, the page can still show the last project's rows for a render; a row whose key names another project is dropped.
// Whether a server id belongs to the open project. Only the server's ids (24 characters after `chan_`) are told apart, as page.py does.
function ownId(key) {
  const own = (location.pathname.split("/")[3] ?? "").slice("chan_".length);
  return own.length !== 24 || !key.startsWith("cmsg_") || key.startsWith(`cmsg_${own}`);
}

function ownRow(row) {
  return !row.key || row.pending || ownId(row.key);
}

// What a row holds besides its words, by structure, as data (router-watch-and-briefs.md 1.8, 2):
// - a decision card (`[data-testid=decision-card]`, a question or a plan alike): `answered` (it has a `data-state`; measured:
//   `answered`, and a pending card has none) and `options`, the texts of its `ul[role=list] button`s in the page's order (the first
//   one's badge left out), passed on as written, never read;
// - the coordinator's thread card (`channel-created-thread`): `card: {glyph}`, its glyph's `data-glyph` (`working`, then `CheckCircle`);
// - `entry_index`: the row's `data-epitaxy-entry-index`, where it has one (the coordinator's start row is the opening row's + 1).
// An option's words, by the button's own references (measured live 2026-11-05): `aria-labelledby` names its letter (the button's first
// child, left out: options go by position) and its label; `aria-describedby` names its badge (left out) and its consequence line. Told as
// "label — consequence". A button without those references: its whole text, badge and hidden parts left out.
const optionWords = (button) => {
  const refs = (attribute) => (button.getAttribute(attribute) ?? "").split(/\s+/).filter(Boolean).map((id) => button.ownerDocument.getElementById(id)).filter(Boolean);
  const label = refs("aria-labelledby").filter((node) => node !== button.firstElementChild).map((node) => squash(node.textContent)).filter(Boolean).join(" ");
  if (label) {
    const consequence = refs("aria-describedby").filter((node) => !node.matches('[data-cds="Badge"]')).map((node) => squash(node.textContent)).filter(Boolean).join(" ");
    return consequence ? `${label} — ${consequence}` : label;
  }
  const copy = button.cloneNode(true);
  copy.querySelectorAll('[data-cds="Badge"], .sr-only, svg, [aria-hidden="true"]').forEach((node) => node.remove());
  return squash(copy.textContent.replace(/[-]/g, ""));
};
function cardOf(row) {
  const more = {};
  const card = row.querySelector('[data-testid="decision-card"]');
  if (card) {
    more.answered = card.hasAttribute("data-state");
    more.options = [...card.querySelectorAll('ul[role="list"] button')].map(optionWords);
  }
  const glyph = row.querySelector('[data-testid="channel-created-thread-glyph"]');
  if (glyph) more.card = { glyph: glyph.getAttribute("data-glyph") };
  const entry = (row.hasAttribute("data-epitaxy-entry-index") ? row : row.querySelector("[data-epitaxy-entry-index]"))?.getAttribute("data-epitaxy-entry-index");
  if (entry != null && entry !== "") more.entry_index = Number(entry);
  return more;
}

// Null while every row on screen belongs to another project (the render right after an address change): the side isn't shown yet,
// which is not its being empty.
function rowsNow(thread) {
  const side = thread ? "thread" : "project";
  const shown = chatRows(thread);
  if (shown === null) return null;
  const rows = shown.filter((row) => row.getAttribute("data-perf-row") !== "marker").map((row) => {
    const key = row.querySelector("[data-entry-key]")?.getAttribute("data-entry-key") || null;
    return {
      key,
      pending: !!key && PENDING.some((prefix) => key.startsWith(prefix)),
      index: Number(row.getAttribute("data-index")),
      from: { assistant: "claude", human: "you" }[row.getAttribute("data-perf-row")] ?? "unknown",
      decision: !!row.querySelector('[data-testid="decision-card"]'),
      streaming: row.getAttribute("data-perf-row-streaming") === "true",
      text: messageText(row),
      ...cardOf(row),
    };
  // A card or a reply still being written can have no words yet. A keyed row told while streaming stays, words or not: one that settles
  // with none still sends its `streaming: false`. Any other told row with no words left is left out, as it was before it was told.
  }).filter((row) => row.text || row.decision || row.streaming || (!!row.key && !!told.rows[side].get(row.key)?.endsWith("|true")));
  const own = rows.filter(ownRow);
  // Rows with no server key can't tell whose they are: alone on screen they don't show this place yet either.
  const known = own.filter((row) => row.key && !row.pending);
  return rows.length && !known.length && rows.some((row) => row.key && !row.pending) ? null : own;
}

// Whether a side's turn is under way: its bottom Claude row on screen (by index, any key: pending or provisional too) is streaming.
// A row whose key names another project (the last view's, for a render after the address changed) is skipped, as `rowsNow` does, and
// so is one `rowsNow` leaves out: no words, no decision card, not streaming and not told while streaming.
function turningNow(thread) {
  const side = thread ? "thread" : "project";
  let bottom = null;
  for (const row of chatRows(thread) ?? []) {
    if (row.getAttribute("data-perf-row") !== "assistant") continue;
    const key = row.querySelector("[data-entry-key]")?.getAttribute("data-entry-key") || null;
    if (key && !PENDING.some((prefix) => key.startsWith(prefix)) && !ownId(key)) continue;
    const streaming = row.getAttribute("data-perf-row-streaming") === "true";
    if (!streaming && !row.querySelector('[data-testid="decision-card"]') && !(key && told.rows[side].get(key)?.endsWith("|true")) && !messageText(row)) continue;
    if (!bottom || Number(row.getAttribute("data-index")) > Number(bottom.getAttribute("data-index"))) bottom = row;
  }
  return !!bottom && bottom.getAttribute("data-perf-row-streaming") === "true";
}

function projects() {
  const seen = new Map();
  for (const link of document.querySelectorAll('a[href^="/code/project/chan_"]')) {
    const id = new URL(link.href).pathname.split("/")[3];
    const name = squash(link.innerText.replace(/[\ue000-\uf8ff]/g, "").split("\n").find((line) => line.trim()));
    if (id && !id.startsWith("chan_pending_") && !seen.has(id)) seen.set(id, { id, name });  // a project being created: not the server's yet
  }
  return [...seen.values()];
}

// The view the latest move left (`openStep`'s `go`): the transcript containers and composers mounted then. The address changes at once,
// the view a render later, so until all of them are out of the document (as the bounce waits for `away.sizers`) what shows can be the
// old view's: neither the projects page's own list nor its New project button counts. A node the page keeps mounted but hidden (no box:
// `getClientRects`) shows nothing and no longer counts, and the record is dropped when the open ends, done or cut off, its move gone
// before or not; superseded, the newer open keeps it (`ended`).
let oldView = [];
const oldViewGone = () => !(oldView = oldView.filter((node) => node.isConnected && node.getClientRects().length)).length;

// The projects page's own list shows: a project link outside the sidebar (the sidebar's are on every page), once the old view is gone.
const ownList = () => oldViewGone() && [...document.querySelectorAll('a[href^="/code/project/chan_"]')].some((link) => !link.closest('[data-testid="sidebar"]'));

function pageState() {
  // The tab left the Claude Code page by an in-page navigation (the script keeps running there; same rule as background.js's `atCode`):
  // told as `away`, as when the tab is found away with no page, and cleared by the next state once it is back on /code.
  if (location.pathname !== "/code" && !location.pathname.startsWith("/code/")) return { type: "page", signed_in: null, page_ok: false, away: true, loaded: Math.round(performance.timeOrigin), instance: INSTANCE };
  const sidebar = !!all("sidebar-projects")[0];
  const login = !!document.querySelector('input[type="email"], input[type="password"]');
  const known = sidebar || composers().length > 0;
  // `loaded`: when this document was loaded (ms since 1970). A document loaded after a goal went unproved read its goals from the server.
  // A frame says when its project side shows the composer's stand-in (an archived project: `data-composer-stand-in`, never read).
  return { type: "page", signed_in: known ? true : login ? false : null, page_ok: known || login, loaded: Math.round(performance.timeOrigin), instance: INSTANCE,
    ...(FRAME && standIn("project") ? { stand_in: true } : {}) };
}

// What the host has been told, so that only changes are sent.
let told = { rows: { project: new Map(), thread: new Map() }, owed: { project: true, thread: true }, empty: { project: false, thread: false }, quiet: { project: null, thread: null }, settle: { project: null, thread: null }, unsettled: { project: null, thread: null }, turning: { project: null, thread: null }, threads: new Map(), emptied: false, projects: "", composer: { project: "", thread: "" }, page: "", where: "", path: "", arrived: 0, notice: new Set() };
let port = null;

// A port the worker drops right after it connected (within QUICK_DROP_MS: say its check of the tab failed) is connected again after a
// wait that doubles each time, up to BACKOFF_MAX_MS, so the two can't loop hot; a port that lived longer reconnects at once. Until the
// wait is over (`connectAfter`) nothing connects, an `emit` neither.
const QUICK_DROP_MS = 1000, BACKOFF_MAX_MS = 30_000;
let connectedAt = 0, backoff = 0, connectAfter = 0;
function connect() {
  if (stopped || !alive() || performance.now() < connectAfter) return null;
  try { port = chrome.runtime.connect({ name: FRAME ? "fjord-frame" : tagged ? "fjord-page-tagged" : "fjord-page" }); } catch { return null; }
  // A frame speaks first with its name, before anything else and though muted: the worker ties its port to that name (`frame_hello`).
  if (FRAME) { try { port.postMessage({ type: "frame_hello", name: window.name }); } catch { port = null; return null; } }
  connectedAt = performance.now();
  muted = true;  // until this port's `snapshot`: it speaks first, `commands` before anything else
  port.onMessage.addListener(onMessage);
  // Only the current port's drop counts: one replaced already (a reconnect made since) says nothing. The worker answers a new port
  // with a `snapshot` once it adopts it, so no scan is sent here: it would reach a port not yet adopted, and be said again.
  const mine = port;
  port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (port !== mine) return;
    port = null;
    if (stopped || !alive()) return;
    backoff = performance.now() - connectedAt < QUICK_DROP_MS ? Math.min(backoff ? backoff * 2 : 250, BACKOFF_MAX_MS) : 0;
    if (!backoff) return void connect();
    connectAfter = performance.now() + backoff;
    setTimeout(() => { if (!port) connect(); }, backoff);
  });
  return port;
}

// Set from connect() until the worker's `snapshot` on that port arrives: nothing is sent before its `commands` (a `done` meanwhile is in
// `recent`, which it repeats; what the page shows, its scan says). The scan at start (below) so sends nothing.
let muted = false;
function emit(event) {
  if (muted) return;
  const open = port ?? connect();
  if (!open || muted) return;
  // A frame's events carry its identity (the worker adds its frameId): `frame`, from its name, never its address.
  const frame = NAME ? { frame: { project: NAME.project, thread: NAME.thread } } : {};
  try { open.postMessage({ ...event, path: location.pathname, thread: threadParam(), ...frame }); } catch { port = null; }
}

// A key or position change is a change: the row is sent again.
// A streaming row's text changes with every flush: it is sent when it starts and once settled, not as each snapshot.
// A card answered, its options or the coordinator card's glyph changing are changes too. The streaming flag stays last (`|true`).
const rowSignature = (row) => `${row.key}|${row.index}|${row.from}|${row.decision}|${row.answered ?? ""}|${JSON.stringify(row.options ?? null)}|${row.card?.glyph ?? ""}|${row.streaming ? "" : row.text}|${row.streaming}`;

// Fjord's tab carries `#fjord` in its address (the worker uses it to find the tab again after Chrome restarts). A tab that
// loaded with it gets it back after each in-page navigation; any other tab is never tagged.
const TAG = "#fjord";
let tagged = !FRAME && (globalThis.__fjordTagged || location.hash === "#fjord");  // a frame is never the tagged tab
function keepTag() {
  if (tagged && location.hash !== TAG) history.replaceState(history.state, "", location.pathname + location.search + TAG);
}

// Sends what differs from `told`, or everything on screen when `full`. Reads only the page; only the address's tag is written.
function scan(full) {
  keepTag();
  const where = location.pathname + "?" + (threadParam() ?? "");
  if (where !== told.where) {
    told.rows.project.clear(); told.rows.thread.clear(); told.where = where; full = true;
    // The arrival on this page: the latest flush, or 0 for the scan at start, so the buffered entry of this visit counts (`startTimeline`; it
    // comes in the resource observer's first callback, a later task, whose scan settles the start read). A project side
    // settles only on a `/timeline` fetch ended since (`settledRows`, `settledEmpty`). A thread's open or close keeps it and the project
    // side's settling with it: the page keeps the project's chat rendered beside the thread (routerd's `arrive` keeps it settled too).
    // Only the thread side starts again. The project side's whole read is still sent again, by the same rule.
    if (location.pathname !== told.path) {
      told.path = location.pathname; told.arrived = lastFlush.at;
      told.quiet.project = told.settle.project = null;
      told.threads.clear(); told.emptied = false;  // another project's Threads panel: this one's are sent whole anyway (`full`), and the map doesn't grow per visit
    }
    // Any arrival on an overview (a `?thread=` closed too) starts its threads again: a row told before the jump says nothing of now.
    if (threadParam() === null) told.threads.clear();
    told.owed = { project: true, thread: true }; told.empty = { project: false, thread: false }; told.quiet.thread = told.settle.thread = null; told.composer = { project: "", thread: "" };
    told.unsettled = { project: null, thread: null }; told.turning = { project: null, thread: null };
    told.listed = false; told.dock = null;
  }
  const page = JSON.stringify(pageState());
  // The top frame's JS heap rides on each of its `page` events, a logged measurement only (1.7), never part of what counts as a change.
  const heap = !FRAME && performance.memory?.usedJSHeapSize;
  if (full || page !== told.page) { told.page = page; emit({ ...JSON.parse(page), ...(heap ? { heap } : {}) }); }

  // The page's notices (a polite live region's open dialogs) are passed on as written: Fjord shows them, never reads them for meaning.
  // Only the dialogs that weren't up at the last scan: one left open (piled up in a hidden tab) isn't said again with each new one.
  const notices = new Set(document.querySelectorAll(`[aria-live] [role="dialog"]${OPEN}`));
  const notice = squash([...notices].filter((node) => !told.notice.has(node)).map((node) => node.textContent).join(" "));
  if (notice) emit({ type: "notice", text: notice });
  if (!muted) told.notice = notices;  // a muted scan said none of them: the snapshot's scan says those still up then

  // An open's move (`moving`): each composer mounted then is the old view's until it leaves the document, or until its side shows the
  // new place (`moveShown`, below: the page can keep a composer across a switch). The record goes with the last of them, or with its open.
  if (moving) moving.composers = moving.composers.filter((node) => node.isConnected);
  if (moving && !moving.composers.length) moving = null;
  const found = projects();

  // The projects page lists them all, so a project missing there is gone (deleted or archived); elsewhere only some are linked. Its
  // first render can hold the sidebar's links alone: the list counts as complete once the page's own list (outside the sidebar) shows,
  // and the view a move left is gone (`oldView`).
  // Frames render no sidebar and never list projects: only the top frame says `projects`.
  const complete = location.pathname === "/code/projects/browse" && ownList();
  const projectsKey = JSON.stringify([found, complete]);  // becoming complete is news even when the same projects show
  if (!FRAME && found.length && (full || projectsKey !== told.projects)) { told.projects = projectsKey; emit({ type: "projects", projects: found, complete }); }

  // A thread's id starts with its project's id too: right after an address change the Threads panel can still list the last project's.
  // A thread frame shows a thread's view, which has no thread rows: it says no `threads`.
  const listed = THREAD_FRAME ? [] : readThreads().filter((row) => ownId(row.thread));
  // `listed` (router-watch-and-briefs.md 2): the first read of this visit whose overview is loaded by structure (`overviewListed`) is sent
  // whole with `listed: true`, as is every full scan's while it holds: only such a read may replace the project's active list. Others are deltas.
  const isListed = !THREAD_FRAME && overviewListed();
  const whole = full || (isListed && !told.listed);
  if (isListed) told.listed = true;
  const threads = listed.filter((row) => whole || told.threads.get(row.thread) !== JSON.stringify(row));
  for (const row of threads) told.threads.set(row.thread, JSON.stringify(row));
  // Departures: a thread told in an active section (`needs`, `running`, `active`) and no longer rendered leaves, said as `{thread, gone:
  // true}` in the same event, only while the overview is listed (`overviewListed`: loaded by structure, no thread open; `told.threads`
  // is cleared by every arrival on an overview). A `done` row dropping out of the group's 20 is no departure, and says nothing.
  const gone = [];
  if (isListed && box("project")) {
    const shown = new Set(listed.map((row) => row.thread));
    for (const [id, said] of told.threads) {
      if (shown.has(id)) continue;
      told.threads.delete(id);
      if (ACTIVE_SECTIONS.has(JSON.parse(said).section)) gone.push({ thread: id, gone: true });
    }
  }
  if (threads.length || gone.length || (whole && isListed)) {
    emit({ type: "threads", threads: [...threads, ...gone], listed: whole && isListed });
    if (!listed.length && gone.length) told.emptied = true;
  }

  // A project frame reports its project side, a thread frame its thread side; neither the other.
  for (const side of FRAME ? [THREAD_FRAME ? "thread" : "project"] : ["project", "thread"]) {
    const seen = told.rows[side];
    const whole = full || told.owed[side];  // a page mounts its transcript late: the first rows replace what Fjord held, whenever they come
    const now = rowsNow(side === "thread");
    // Since a move, a side whose rows were another project's (or couldn't be told) at one flush and are its own at a later one shows
    // the new place (`moveShown`).
    if (moving && lastFlush.at > moving.at) {
      if (now === null) moving.stale[side] = lastFlush.at;
      else if (moving.stale[side] !== null && lastFlush.at > moving.stale[side]) moving.shown[side] = true;
      // The target's `/timeline` fetch ended after the move, and this flush, after it, touched the project side's sizer: its rows rendered.
      if (side === "project" && moving.project && !moving.shown.project) {
        const sizer = sizerOf(false);
        const fetched = timelines.some((t) => t.project === moving.project && t.end > moving.at && lastFlush.at > t.end);
        const touched = lastFlush.nodes.some((node) => node === sizer || sizer?.contains(node)) || lastFlush.added.some((node) => node === sizer || node.contains(sizer));
        if (sizer && fetched && touched) moving.shown.project = true;
      }
    }
    // Still the last project's rows: wait for this one's. A thread's pane mounting (`halfMounted`) only hides which rows are whose for a
    // flush or two: the side's settling stays, and a new sizer starts it again anyway.
    if (now === null) { if (!halfMounted()) told.quiet[side] = told.settle[side] = null; continue; }
    // A keyless row (routerd drops it) is sent only in a whole read: in a diff it would differ from the map on every flush.
    const rows = now.filter((row) => whole || (row.key && seen.get(row.key) !== rowSignature(row)));
    // `turning` (`turningNow`) reads the map as `rowsNow` did, before this read's rows are marked told: it skips exactly the rows left out.
    const turning = turningNow(side === "thread");
    for (const row of rows) if (row.key) seen.set(row.key, rowSignature(row));
    const composer = box(side);
    // Once, a side with its composer and no rows says it is empty, so an empty project can still be sent to: only once its transcript
    // has mounted, its rows were fetched, and it stayed empty since (`settledEmpty`), since before that no rows is the page still loading.
    const sizer = sizerOf(side === "thread");
    const empty = settledEmpty(side, now, composer ? sizer : null, whole);
    // A whole read says whether it is the place's render done (`settledRows`; an empty one is sent only once settled).
    const settled = now.length ? settledRows(side, sizer, now, whole) : empty;
    // A project whose list is empty when its page is visited: once the project side settled this visit (its `/timeline` fetch since the
    // arrival, then a flush or the grace: `settledRows`, `settledEmpty`), the empty list is sent once, so threads that finished while
    // the tab was elsewhere don't stay running on the Board. Never before this visit's data arrived: `settled` needs it.
    if (side === "project" && settled && composer && !listed.length && !told.emptied && threadParam() === null) { told.emptied = true; emit({ type: "threads", threads: [] }); }
    // While the whole read is owed, it is sent again only when its rows, its settling or its turning changed (or on a full scan), not on
    // every flush: routerd learns nothing from the same read twice. It waits for the settled one, sent whatever its rows; a settled read
    // of only pending rows stays owed, and is not sent again until it changes.
    // A thread frame's thread side also says its dock (`dockState`) with each rows event.
    const dock = THREAD_FRAME && side === "thread" ? dockState() : null;
    const unsettledKey = whole ? JSON.stringify([settled, turning, rows.map(rowSignature), dock]) : null;
    const same = !full && unsettledKey !== null && unsettledKey === told.unsettled[side];
    // `turning` (`turningNow`) goes with every rows event, whole or delta, and whenever it changed since last told: alone, as a delta
    // with no rows. A delta without it would leave routerd reading the delta's rows, where an older row settling says nothing.
    if (!same && (rows.length || (whole && empty && (full || !told.empty[side])))) {
      emit({ type: "rows", side, rows, full: whole, ...(whole ? { settled } : {}), turning, ...(dock ?? {}) });
      told.turning[side] = turning;
      if (dock) told.dock = JSON.stringify(dock);
      told.unsettled[side] = unsettledKey;
      told.empty[side] = !rows.length;
      // The whole read is owed until it held a row routerd keeps (a server key, not pending): pending and keyless rows are dropped
      // there, so a read of only those replaced the place's rows with none, and the next one must be whole again. It is owed too until
      // it was settled: routerd waits for a settled one before baselining a send to a chat it stores no rows of. Any whole read sets it,
      // either way: one that isn't settled (a snapshot, or a forced scan, on a place that had settled) makes routerd wait again for a
      // settled one, which the next scan (a flush, or the grace's wake) then sends.
      if (whole) told.owed[side] = !(settled && rows.some((row) => row.key && !row.pending));
    } else if (whole && !empty) {
      // A whole read that said nothing because the side hadn't settled (a full scan, say, after routerd's copy was reset): a later settled
      // scan says it is empty again. One that said nothing because the empty read was already sent leaves the mark, or each flush would.
      told.empty[side] = false;
    }
    // Alone, only once the side's whole read isn't owed (the whole read says it), never the first `false` (nothing was turning), and on the
    // thread side only with a thread open (`box`).
    if (told.turning[side] !== turning && !told.owed[side] && (turning || told.turning[side] !== null) && (side === "project" || composer)) {
      emit({ type: "rows", side, rows: [], full: false, turning, ...(dock ?? {}) }); told.turning[side] = turning;
      if (dock) told.dock = JSON.stringify(dock);
    }
    // A thread frame's dock changing (a running tool's stop, an approval slot filling) is said alone too, with the turning.
    if (dock && told.dock !== JSON.stringify(dock) && !told.owed[side]) {
      emit({ type: "rows", side, rows: [], full: false, turning, ...dock }); told.dock = JSON.stringify(dock);
    }

    if (!composer || FRAME) continue;  // frames say no composer: they never type  // a thread side has one only with two composers mounted (`box`)
    if (moving?.composers.includes(composer)) {
      if (!moveShown(moving, side)) continue;  // the old view's, still up after an open's move
      moving.composers = moving.composers.filter((node) => node !== composer);  // kept by the page for the new place
    }
    const button = sendFor(composer);
    const state = { type: "composer", side, draft: composer.textContent, disabled: button ? !!button.disabled : null };
    const key = JSON.stringify(state);
    if (full || key !== told.composer[side]) { told.composer[side] = key; emit(state); }
  }
  if (FRAME) watchPlace();  // a frame keeps its place after every look (1.4)
}

const snapshot = () => scan(true);

// A thread view's dock, by structure (router-watch-and-briefs.md 1.8, 3.7): `stop`, the thread composer dock's (the second
// `rail-composer-dock`) `[data-testid=code-prompt-stop]` (measured: shown while a tool runs, and it can linger after a `needs`, so it only
// ever withholds a finish); `approval`, the text of the approval slots (`data-approval-cluster-host`, `data-approval-dock`) when any holds
// an element or text, else null, passed on as data (Fjord clicks nothing in a prompt).
function dockState() {
  const docks = all("rail-composer-dock");
  const dock = docks.length >= 2 ? docks.at(-1) : threadScope();
  const scope = threadScope() ?? document;
  const slots = [...scope.querySelectorAll("[data-approval-cluster-host], [data-approval-dock]")].filter((slot) => slot.children.length || squash(slot.textContent));
  return { stop: !!dock?.querySelector('[data-testid="code-prompt-stop"]'), approval: slots.length ? squash(slots.map((slot) => slot.textContent).join(" ")) : null };
}

// Commands wait here as steps. A step returns nothing while it waits, or { ok, error } when it is over. Every flush of
// the observer runs the waiting steps again, so a command waits for the page and never for a timer. A step's `ended` (optional) hears
// it leave: "done", "cancelled" or "superseded".
const waiting = new Map();
let lastFlush = { at: 0, nodes: [], added: [] };  // the observer's last flush: when, and the nodes it changed. A step that waits for "a render after" compares its fields (at, nodes, added)
// An open's move (`openStep`'s `go`): when, the project and thread it went to (null for the bounce), the composers and each side's sizer mounted
// then, and the open that owns it (`by`). The page swaps views a render after the address changes, so until a composer leaves the
// document or its side shows the new place (`moveShown`), it is the old view's: no open counts it as its place's, and `scan` says no
// composer event from it (its draft isn't the new place's). It lasts no longer than its open: the open's end drops it, and a newer open
// that supersedes it takes it over (it may show the place already, the move still under way).
let moving = null;

// Whether a side shows the place a move went to, by structure, though its composer may be the one mounted at the move: across projects
// the page mounts a new one (measured), but thread switches and the bounce's return weren't measured. After a flush since the move: the
// side's transcript container (`transcript-sizer`) is another than the one mounted then; or, on the thread side, a row of the target
// thread's opening message (its `data-entry-key` is the thread's id) is in the thread's part of the page; or, on the project side, a
// `/timeline` fetch of the target ended after the move and a flush after it touched the side's sizer (`scan`); or the side's rows were
// another project's at a flush since the move and its own at a later one (`scan`).
function moveShown(move, side) {
  if (lastFlush.at <= move.at) return false;
  const sizer = sizerOf(side === "thread");
  if (sizer && sizer !== move.sizers[side]) return true;
  if (side === "thread" && move.thread) {
    const scope = threadScope();
    if (scope && all("transcript-row", scope).some((row) => row.querySelector(`[data-entry-key="${CSS.escape(move.thread)}"]`))) return true;
  }
  return move.shown[side];
}
const RENDER_GRACE = 1000;  // ms after an answer ended that its render is taken as done, though no flush touched it (nothing to show changes no DOM): a
// repository search's list, an empty side's sizer (`settledEmpty`), and a thread side's rows (`settledRows`)
// `refused`: the page doesn't offer what was asked (nothing was committed), as opposed to a step that broke.
// The latest `done`s, kept: the native port can drop (Chrome closing the host) while this script lives on, and a `done` sent into a
// dropped port is lost. Every snapshot says them again with what still waits, so routerd learns what the page did.
// A setting's step adds what its open read (`before`), and `already` (it was so: nothing done) or `saved` (the save's HTTP status).
const recent = [];
function done(id, { ok, error, refused, committed, ...more }) {
  const event = { type: "done", id, ok, error: error ?? null, ...(refused ? { refused: true } : {}), ...(committed ? { committed: true } : {}), ...more };
  recent.push(event);
  if (recent.length > 20) recent.shift();
  emit(event);
}

// The place is open: say everything on screen, so what was missed (a renumbered or queued row) can still be proved. Only when nothing
// was moved: opening pushes the history state, and the new place says what it shows by itself.
function shown(moved) {
  if (!moved) snapshot();
  return { ok: true };
}

// Opens the place the way the page's own links do: its address goes on the history and the page's router shows it. No
// document load, so the "open Claude" handoff of a freshly loaded project link never runs, and a thread hidden under
// "show more" or resolved opens as well as a listed one (129 ms across projects, measured). A project that doesn't exist
// shows no composer, so the deadline covers it.
// `fresh` (routerd, for a project the tab shows that never settled since it arrived): if the tab already shows the place at the step's
// first run and no `/timeline` fetch of its chat ended since the arrival (`told.arrived`; an address no scan has seen is scanned first),
// the page is made to fetch it: the step goes to BOUNCE, waits until the project's view is gone, and comes back to the target, a new arrival whose open fetches the chat's rows as
// any does. For a project open (no thread) the place is shown whenever its project is, a thread open beside it or not: the project side
// is what settles, and a thread's open or close is no arrival (`scan`). BOUNCE is the page that starts a new task (`/code`, "Créer" in
// the sidebar), never the projects page: that one's scan says `projects` `complete` once its own list shows, and a list still rendering
// would prune the Board. Left means: the address is BOUNCE, a flush came after the move, and every transcript container (`transcript-sizer`)
// the project showed is out of the document (by structure; the new page may mount a composer of its own). With such a fetch (its
// settling is under way) or the tab elsewhere (the move is itself an arrival) it opens as usual.
const BROWSE = "/code/projects/browse", BOUNCE = "/code";
function openStep(command) {
  const path = command.project ? `/code/project/${command.project}` : BROWSE;  // no project: the projects page
  const target = path + (command.thread ? `?thread=${encodeURIComponent(command.thread)}` : "");
  let moved = false, first = true, away = null;  // away: while bouncing, when it left and the project's sizers then
  let left = null;  // the latest move (`moving`)
  const go = (to, project) => {
    left = moving = { at: performance.now(), project, thread: project ? command.thread ?? null : null, composers: composers(), notes: standIns(), sizers: { project: sizerOf(false), thread: sizerOf(true) },
      stale: { project: null, thread: null }, shown: { project: false, thread: false }, by: step };
    oldView = [...all("transcript-sizer"), ...composers()];
    history.pushState(history.state, "", to + (tagged ? TAG : ""));
    dispatchEvent(new PopStateEvent("popstate", { state: history.state }));
  };
  const step = () => {
    const here = location.pathname === path && (!command.thread || threadParam() === command.thread);  // a project open: any thread beside it
    if (first) {
      first = false;
      if (moving) moving.by = step;  // a move still under way, of the open this one superseded: it is this one's now
      // The arrival is the scan's to note (`told.arrived`): an address changed since the last scan (no flush yet) is scanned first, so a
      // fetch of this visit counts and the tab isn't bounced for want of a scan.
      if (told.path !== location.pathname) scan(false);
      const fetched = told.path === location.pathname && timelines.some((t) => t.project === command.project && t.end >= told.arrived);
      if (command.fresh && command.project && here && (!fetched || command.fresh === "force")) {  // "force": a dev check of the bounce
        moved = true;
        away = { at: performance.now(), sizers: all("transcript-sizer") };
        go(BOUNCE, null);
        return;
      }
    }
    if (away) {
      // The project's view is still up: the address hasn't changed, no update came after the move, or one of its sizers is still mounted.
      if (location.pathname !== BOUNCE || lastFlush.at <= away.at || away.sizers.some((node) => node.isConnected)) return;
      away = null;
      go(target, command.project);
      return;
    }
    if (!here) {
      if (moved) return;
      moved = true;
      go(target, command.project);
      return;
    }
    // A project open is ready once the project's own composer shows, a thread open beside it or not (`box`); a thread open once its
    // thread's does. After a move, only one that a flush since mounted, or the one kept from before once its side shows the new place
    // (`moveShown`), not the old view's still up (as the bounce does for sizers): the address changes at once, the view a render later.
    // The move in progress (`moving`) counts too: a superseded open's, which this one may find already at its place.
    const crumb = all("overview-thread-crumb-back")[0];
    const after = (move, node, side) => !move || (lastFlush.at > move.at && (![...move.composers, ...(move.notes ?? [])].includes(node) || moveShown(move, side)));
    const arrived = (node, side) => !!node && after(left, node, side) && after(moving, node, side);
    // The projects page: a flush since the move, the old view gone (`oldView`), and its own list (or, with no project, its new project
    // button), never the sidebar's links alone, which the last view still shows.
    const ready = !command.project ? (!left || lastFlush.at > left.at) && (ownList() || !!newProjectButton())
      : command.thread ? composers().length >= 2 && crumb && arrived(box("thread"), "thread") : arrived(box("project"), "project");
    if (ready) return shown(moved);
    // The place shows a note where its composer would be (`standIn`), arrived as a composer would: nothing can be sent there.
    const side = command.thread ? "thread" : "project", note = command.project ? standIn(side) : null;
    if (arrived(note, side)) return noComposer(note);
  };
  // Its move lasts no longer than it: over or cut off, the move is dropped; superseded, the newer open takes it over (above). A dropped
  // move is scanned again once (a microtask: after the step's `done`): a composer event `scan` held back for it is sent now, not at
  // the next flush, which may be long in coming.
  // The old view's record goes with any end but `superseded` (the newer open keeps it), though the move went before (`scan` drops it
  // once its composers are out of the document, the sizers maybe still up).
  step.ended = (why) => {
    if (why === "superseded") return;
    oldView = [];
    if (moving?.by !== step) return;
    moving = null;
    queueMicrotask(() => { if (!stopped && alive()) { scan(false); settle(); } });
  };
  return step;
}

// Send is a state machine run on each flush of the observer; the page drives it, nothing here waits on a timer.
//   a. the draft holds other words: clear it and wait
//   b. the draft is empty and Send is enabled: the page is settling, wait (a click now does nothing)
//   c. the draft is empty and Send is disabled or missing (a turn runs, and typing brings Send back): type, once
//   d. the words are in the draft and Send is enabled: click, once
// A click that didn't take is retried by routerd with another send, which replaces this one; a retry is never made here.
// The last click on each side: its place, its intent (routerd's id for the message), its words (loose) and when. A retry routerd sent
// before this click's `done` reached it (its deadline crossed the click) isn't click-only, and would type the words again into the draft
// the click emptied. Another intent's same words are no retry: routerd sends them only once it has proved the first (or given up).
const lastClick = { project: null, thread: null };
const ATTEMPT = 20000;  // ms: one attempt's deadline, routerd's do.TIMEOUT (20 s): a send after it is a retry of an attempt that gave up
// ms: routerd's TAKE_WAIT (2 s), the time a click has for the page to take the words (empty the draft) before routerd clicks again. A
// crossed retry that finds the words still in the draft that soon after the click isn't clicked: the page may be taking them yet.
const TAKE_WAIT = 2000;
// A project side's place is its project (a thread may show beside it); a thread side's is its thread.
const sidePlace = (side) => location.pathname + (side === "thread" ? "?" + (threadParam() ?? "") : "");
function sendStep(command) {
  let typed = false, woke = false;
  return () => {
    // The place it was sent for, if it says (another run may have moved the tab): never type into another place's composer.
    // A project send needs only its project: the page reopens the thread last shown there, and the project's composer is still the first.
    const elsewhere = location.pathname !== `/code/project/${command.project}` || (command.side === "thread" && threadParam() !== command.thread);
    if (command.project && elsewhere) {
      return { ok: false, error: "not on that place" };
    }
    const composer = box(command.side);
    if (!composer) {  // a reload is under way; the deadline covers a composer that never comes
      const note = standIn(command.side);  // a note in its place (an archived project): none will come
      return note && !(moving?.notes?.includes(note) && !moveShown(moving, command.side)) ? noComposer(note) : undefined;
    }
    if (moving?.composers.includes(composer) && !moveShown(moving, command.side)) return;  // the old view's, still up after an open's move
    const draft = loose(composer.textContent), words = loose(command.text);
    const button = sendFor(composer);
    // Typing goes where focus is: a modal over the page (a tool's settings dialog, say) could keep it and take the words into its own
    // fields (the goal, the instructions). Nothing is cleared or typed unless focus is in the composer. routerd waits for its tools
    // before sending; this is the second guard, and retryable. (An open role="dialog" is no sign: the page's "settings saved" toasts are role=dialog and pile up open in a hidden tab, which runs no animation frames.)
    // The settings dialog is checked first and focus is taken only when none is open, so the guard doesn't pull focus from an open menu.
    const modal = () => { if (settingsDialog()) return true; composer.focus(); return !composer.contains(document.activeElement); };
    // A retry after a click the page may yet take: it only clicks words already there; typing them again could send them twice.
    // A send that finds the draft empty right after this side clicked the same intent's words in the same place counts as such a retry:
    // its `done` follows the click's on the same port, so routerd has heard the click first and takes the empty draft as the page taking them.
    const click = lastClick[command.side];
    const since = click && click.place === sidePlace(command.side) && command.intent != null && click.intent === command.intent && click.words === words ? performance.now() - click.at : Infinity;
    const crossed = !draft && !typed && since < ATTEMPT;
    if ((command.click_only || crossed) && draft !== words) return { ok: false, error: "the words aren't in the draft" };
    if (typed && draft !== words) return { ok: false, error: "the draft differs from the words" };
    if (draft && draft !== words) {
      if (modal()) return { ok: false, error: "a dialog is open" };
      document.execCommand("selectAll");
      document.execCommand("delete");
      return;
    }
    if (!draft) {
      if (button && !button.disabled) return;  // empty and enabled: the page is finishing the last send
      if (modal()) return { ok: false, error: "a dialog is open" };
      if (!document.execCommand("insertText", false, command.text)) return { ok: false, error: "the page refused the words" };
      typed = true;
      return;
    }
    if (!button || button.disabled) return;
    // The same intent's words were clicked here less than TAKE_WAIT ago and are still in the draft: the page may be taking them, and a
    // second click could send them twice. It waits: the flush that empties the draft fails it as above (`crossed`), or the wait ends and
    // it clicks, a real retry of a click the page ignored.
    if (since < TAKE_WAIT) {
      if (!woke) { woke = true; wakeAfter(Math.max(0, TAKE_WAIT - since) + 50); }
      return;
    }
    button.click();
    lastClick[command.side] = { place: sidePlace(command.side), intent: command.intent, words, at: performance.now() };
    return { ok: true };
  };
}

// ---- The Router's tools: create a project, and read or change a project's settings.
// Each command is a sequence: every `yield` waits for the next flush of the observer, never for a timer. `state.lack` names what the
// sequence waits for, so a cancel (routerd's deadline) can say what was missing. Elements are found by test id and structure only; a
// repository or a folder is matched by its text because that text is data (`owner/name`, a path), not the page's language.
const outsidePage = '[data-testid="sidebar"], [data-testid="transcript-row"], [role="dialog"]';
// A closed dialog, menu or popup keeps `data-closed` until its closing animation ends, which a hidden tab never runs: only open ones count.
const OPEN = ":not([data-closed])";
const settingsDialog = () => [...document.querySelectorAll(`[role="dialog"]${OPEN}`)].find((node) => node.querySelector('[data-testid="settings-top-row"]')) ?? null;
// The page's own requests for a project's settings, as resource timing reports them (observed, never made). Opening the settings
// dialog fetches them (`…/config`: instructions, repositories, folders) once, about 0.2 s after it shows, but that open keeps showing
// the page's older copy; the next open shows the fetched ones (measured). The goal is not in them: the dialog shows the goal as the tab
// last knew it, even after the page fetched the project again (measured), so a goal read is only the tab's copy.
// The same requests carry the server's answer to a change: instructions and repositories save to `…/config` and folders to `…/remote-control-preapproval` as they are made,
// the goal saves to the project's record when the dialog closes (measured), and each request's status says whether the server took it.
// An entry is reported only once its response ended, so a request listed here has its answer; one still under way isn't listed.
const requests = [];  // the latest requests for a project's record, settings or folders: { project, kind, start, end, status }
const searches = [];  // the latest repository searches, answered: { start, end, q }; their results are what the list shows next
// The latest fetches of a project chat's own rows (`/v1/code/channels/<chan>/timeline?limit=200`, one per visit,
// starting ~0.11 s and ending ~0.33 s after the arrival, measured): { project, end }.
// A project side, empty or with rows, is settled only once one of these ended since the arrival on the page (`settledEmpty`, `settledRows`).
// The page's resource timing buffer holds 250 entries by default and stops filling once full; `buffered` then lacks the newer ones, but
// the observer is still given every entry as it comes. A script injected into a long-lived tab can so miss the fetch of the chat it
// shows: that side never settles until the page fetches it again, which routerd's `fresh` open forces (`openStep`). The buffer's size is
// the page's to set (its own world), so it is left alone.
// At start (`told.arrived` is 0) the buffer can hold a fetch from each earlier visit to the shown project, and one from an earlier visit
// lacks the rows added while away. Each visit fetches once, so the buffer's latest `/timeline` fetch, of any chat, is this visit's when it
// is the shown project's; it alone of the buffered ones counts, and none does when the buffer may be full (this visit's can be missing):
// that side waits for a fetch to come, and routerd's `fresh` open (whose first run reads `timelines` the same way) makes one.
const timelineOf = (name) => new URL(name, location.origin).pathname.match(/^\/v1\/code\/channels\/(chan_[^/]+)\/timeline$/)?.[1] ?? null;
const START = performance.now();
const startTimeline = (() => {
  const entries = performance.getEntriesByType("resource");
  if (entries.length >= 250) return null;
  const latest = entries.filter((entry) => timelineOf(entry.name)).reduce((a, b) => (!a || b.responseEnd >= a.responseEnd ? b : a), null);
  return latest && timelineOf(latest.name) === shownProject() ? latest.responseEnd : null;
})();
const timelines = [];
const resources = new PerformanceObserver((list) => {
  if (!alive()) { try { stop(); } catch {} return; }
  let shownChat = false;
  for (const entry of list.getEntries()) {
    const url = new URL(entry.name, location.origin);
    if (/\/code\/repos\/search$/.test(url.pathname)) {
      searches.push({ start: entry.startTime, end: entry.responseEnd, q: url.searchParams.get("q") });
      if (searches.length > 20) searches.shift();
    }
    const chat = timelineOf(entry.name);
    if (chat && (entry.responseEnd > START || entry.responseEnd === startTimeline)) {
      timelines.push({ project: chat, end: entry.responseEnd });
      if (timelines.length > 20) timelines.shift();
      shownChat ||= chat === shownProject();
    }
    // The project's record (the goal), its settings (instructions, repositories), and its pre-approved folders save each to their own.
    const [, project, sub] = url.pathname.match(/^\/v1\/code\/channels\/(chan_[^/]+)(\/config|\/remote-control-preapproval)?$/) ?? [];
    if (!project) continue;
    requests.push({ project, kind: sub === "/config" ? "config" : sub ? "folders" : "record", start: entry.startTime, end: entry.responseEnd, status: entry.responseStatus });
    if (requests.length > 50) requests.shift();
  }
  // The shown chat's rows came: its sides are scanned now, and each rule that waits arms its own wake (`settledRows`: SETTLE_GRACE for
  // rows; `settledEmpty`: RENDER_GRACE for an empty side), as its render may change no DOM (an empty chat, a re-open with nothing new).
  if (shownChat) scan(false);
  settle();  // the observer's callback isn't a page change: the waiting read is run from here
});
// `buffered`: a script injected into a tab already showing a chat sees the fetch of its rows too. Older entries can't answer a step: each
// step takes only a request that started or ended after its own mark.
resources.observe({ type: "resource", buffered: true });

// The server's answer to the change just made: the first request for that part of the project to start after it. Resource timing
// gives no method, but measured, nothing else asks for it in between: an accepted goal save is followed by the page's refetch of the
// record, a refused one (a 400) by nothing, and the dialog's own fetch of the settings has ended before (openQuiet). Refused, the step
// fails with nothing committed; taken, the change is committed (what the dialog shows after is only the page's own copy).
// Returns the answer's status. `none` says what no request at all means, when it is cut off.
// A pick (a folder or a repository) that the server won't take presses its option and then makes no save request at all, which looks
// like a save still under way. A request is listed only once it has ended and saves answer well under a second, so the save is awaited
// only SAVE_WAIT from the press (a few ticks of a hidden tab's timers); then the step is done with `committed` and `unsaved`, at once,
// rather than at routerd's cut-off, and the fresh read that follows says whether it took.
const SAVE_WAIT = 4000, GAVE_UP = Object.freeze({});
// Marks the press of an option: a save may be under way from `at` (taken just before the press: the page can start its save inside the
// press's own handlers), and the wait for it is timed from then. The timer only wakes the step.
function markPressed(state, at = performance.now()) {
  state.committed = true;
  state.pressedAt = at;
  wakeAfter(SAVE_WAIT + 50);
}
// Presses an option and marks it: a pick's save is the first request that starts at or after `state.pressedAt`.
function pressMarked(state, option) {
  const at = performance.now();
  press(option);
  markPressed(state, at);
  return true;
}
function* saved(state, project, kind, since, what, none = `no answer from the server to the ${what}`) {
  const answer = yield* wait(state, none, () => requests.find((r) => r.project === project && r.kind === kind && r.start >= since)
    ?? (state.pressedAt !== undefined && performance.now() - state.pressedAt >= SAVE_WAIT ? GAVE_UP : null));
  if (answer === GAVE_UP) throw Object.assign(new Error(none), { unsaved: true });
  if (!answer.status) {  // the request got no HTTP answer: it may yet have saved, so it counts as done
    state.committed = true;
    throw new Error(`no answer from the server to the ${what} (network)`);
  }
  if (answer.status >= 400) {
    state.committed = false;  // refused: nothing changed
    throw new Error(`the server refused the ${what} (HTTP ${answer.status})`);
  }
  state.committed = true;
  return answer.status;
}

// A fetch of the project's settings that ended after `since` (when the dialog showed): one that started after it, or one still under way
// then, which an open joins rather than fetching again. One that ended before the dialog mounted can't be the one it joined.
const fetchedSince = (project, since) => requests.some((r) => r.project === project && r.kind === "config" && r.end >= since);

const optionText = (node) => squash(node.textContent.replace(/[\ue000-\uf8ff]/g, ""));  // a chosen option carries a check glyph
const optionsNow = () => [...document.querySelectorAll('[role="option"]')].filter((node) => !node.closest('[data-testid="sidebar"], [data-closed]'));
const refusal = (message) => Object.assign(new Error(message), { refused: true });

function sequence(body) {
  return (command) => {
    // `committed`: its one change was made, so an error after it isn't "nothing done". `before`: what a setting held, once read.
    const state = { lack: null, refused: false, committed: false, before: undefined };
    const it = body(command, state);
    const read = () => (state.before === undefined ? {} : { before: state.before });
    const step = () => {
      try { const next = it.next(); return next.done ? { ...next.value, ...read() } : undefined; } catch (error) { return { ok: false, error: error.message, refused: !!error.refused, committed: state.committed, ...(error.unsaved ? { unsaved: true } : {}), ...read() }; }
    };
    step.why = () => ({ error: state.lack ?? "the step didn't finish", refused: state.refused && !state.committed, committed: state.committed, ...read() });
    return step;
  };
}

function* wait(state, lack, find) {
  for (;;) {
    const found = find();
    if (found) return found;
    state.lack = typeof lack === "function" ? lack() : lack;  // a function says what is there at the moment it is cut off
    yield;
  }
}

// The project's settings, the way a person opens them: the header's second menu button, then its menu's one menu item.
// The dialog, opened, and its own settings fetch ended: a change made after that has the first request that follows for its answer.
function* openQuiet(state, project) {
  const left = settingsDialog();  // left open by a step that broke: only a fresh open fetches, and a change needs that fetch behind it
  if (left) yield* close(state, left);
  const dialog = yield* openSettings(state, project);
  const shown = opened(state);
  // This open's own fetch, or the one it joined: it ended after the dialog showed (one that ended before it mounted isn't it), so a
  // request that starts after the change is its answer.
  yield* wait(state, "the settings never came back from the server", () => fetchedSince(project, shown));
  return dialog;
}

// The settings as the server has them, for a step that reads what it changes: the first open fetches them but keeps showing what it
// opened with, so it is closed once that fetch ended and opened again (openQuiet), which shows them (measured). `fresh` false opens once:
// the goal is only the tab's copy, however many times the dialog opens.
function* openFresh(state, project, fresh) {
  if (fresh) {
    const left = settingsDialog();
    if (left) yield* close(state, left);
    yield* openSettings(state, project);
    const shown = opened(state);
    yield* wait(state, "the settings never came back from the server", () => fetchedSince(project, shown));  // this open's own fetch
    yield* close(state, settingsDialog());
  }
  return yield* openQuiet(state, project);
}

// A setting that is already so is left: an unchanged field saves nothing, and an option already chosen is never pressed.
function* already(state, dialog) {
  return { ...(yield* close(state, dialog)), already: true };
}

// `state.opening`: when its menu item was pressed, which mounts the dialog in that same turn. The dialog joins a settings fetch still
// under way then, so a fetch that ends after it is the one the dialog shows; openSettings itself returns a page update or more later.
// Every caller closes a dialog left open first, so openSettings always presses the item: no time here is a bug.
function opened(state) {
  if (state.opening === undefined) throw new Error("the settings dialog opened without its menu item being pressed");
  return state.opening;
}

// The menu is the one its button names (`namedBy`) while the button says it is expanded, as `menuNow` takes it: a hidden tab keeps an
// earlier menu open in the page, so an open one-item menu found elsewhere may be stale, and is never pressed. A hidden tab can shut the
// menu again at once: the button is clicked again while it isn't expanded, a few times at most.
function* openSettings(state, project) {
  let clicks = 0, item = false;
  state.opening = undefined;
  for (;;) {
    if (location.pathname !== `/code/project/${project}`) throw new Error("not on that project");
    const dialog = settingsDialog();
    if (dialog) return dialog;
    const trigger = [...document.querySelectorAll('button[aria-haspopup="menu"]')].filter((node) => !node.closest(outsidePage))[1];
    const expanded = trigger?.getAttribute("aria-expanded") === "true";
    const open = expanded ? namedBy(trigger) : null;
    if (open?.querySelectorAll('[role="menuitem"]').length !== 1) {
      state.lack = "no settings menu";
      if (trigger && !expanded && !item && clicks < 3) { clicks++; trigger.click(); }
    } else {
      state.lack = "no settings menu item";
      if (!item) { item = true; state.opening = performance.now(); open.querySelector('[role="menuitem"]').click(); }
    }
    yield;
  }
}

// A section is the dialog's nav button at that position; the shown one has aria-current="page".
function* section(state, dialog, index) {
  let clicked = false;
  for (;;) {
    const button = (settingsDialog() ?? dialog).querySelectorAll("nav button")[index];
    if (button?.getAttribute("aria-current") === "page") return;
    state.lack = `no settings section ${index}`;
    if (button && !clicked) { clicked = true; button.click(); }
    yield;
  }
}

// Closes the dialog by the first button of its top row outside the nav (else Escape), and waits until it is gone so the next command finds none.
function* close(state, dialog) {
  let closing = false;
  for (;;) {
    if (!settingsDialog()) return { ok: true };
    state.lack = "the settings dialog stayed open";
    if (!closing) {
      closing = true;
      const button = [...((settingsDialog() ?? dialog).querySelector('[data-testid="settings-top-row"]')?.querySelectorAll("button") ?? [])].find((node) => !node.closest("nav"));
      if (button) button.click();
      else (document.activeElement ?? document.body).dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    }
    yield;
  }
}

// A section's field is its one labelled textarea: the goal in General, the instructions in Memory (whose message box has no label).
// Which section shows is checked before, by the nav's aria-current.
function fieldOf(dialog) {
  const boxes = [...dialog.querySelectorAll("textarea[aria-labelledby]")].filter((node) => !node.closest("[data-closed]") && node.checkVisibility());
  return boxes.length === 1 ? boxes[0] : null;
}

// What the dialog's text boxes are, for an error that says why no field was found.
const boxesSeen = (dialog) => [...dialog.querySelectorAll("textarea")].map((node) =>
  `${node.hasAttribute("aria-labelledby") ? "labelled" : "plain"}${node.checkVisibility() ? "" : " hidden"}${node.closest("[data-closed]") ? " closed" : ""}${node.closest("[data-ending-style]") ? " ending" : ""}${node.closest("[data-starting-style]") ? " starting" : ""}`).join(", ");

// Replaces what a field holds the way typing does and checks it before leaving the field: the page saves on blur, with no Save button.
// Given its step's `state`, the field counts as committed from just before the words go in: an error after that may leave them saved.
// A text box holds its line breaks as `\n` (`value` normalises `\r\n`), so the words are compared the same way (`sameText`).
const sameText = (value, text) => value === text.replace(/\r\n?/g, "\n");
function write(field, text, state = null) {
  field.focus();
  document.execCommand("selectAll");
  if (state) state.committed = true;
  const taken = text ? document.execCommand("insertText", false, text) : document.execCommand("delete");
  if (!taken) throw new Error("the page refused the words");
  if (!sameText(field.value, text)) throw new Error("the field differs from the words");
  field.blur();
}

// The one option whose text is exactly the data asked for. Several are refused at once. None waits, since a list can still be loading;
// if it never comes, the cancel says what was offered. `listed`: whether the list is open, so that having none of the asked one is the page's answer.
// A popup list's options, from the list its button names (`aria-controls`). A hidden tab keeps closed lists in the page, and a list
// that just opened can sit inside one still marked closed (measured): only the button says which list is this one.
function optionsOf(button) {
  const list = namedBy(button);
  return list ? [...list.querySelectorAll('[role="option"]')] : optionsNow();
}

// The element a button names (`aria-controls`), while open: the page reuses ids (a reopened list or menu gets the same one) and a hidden
// tab keeps closed ones in the page, so the newest one not marked closed (`getElementById` gives the first, which can be a stale closed
// one). None while only closed ones carry the id: a closed list's options or menu's items are never what to press, so the caller waits
// for a flush (`menuNow`) or falls back (`optionsNow`).
function namedBy(button) {
  const id = button?.getAttribute("aria-controls"), candidates = id ? [...document.querySelectorAll(`[id="${CSS.escape(id)}"]`)] : [];
  return candidates.filter((node) => !node.hasAttribute("data-closed")).pop() ?? null;
}

function* choose(state, wanted, what, listed, options) {
  for (;;) {
    const shown = options(), exact = shown.filter((node) => optionText(node) === wanted);
    if (exact.length > 1) throw refusal(`${exact.length} ${what} options match ${wanted}`);
    if (exact.length) { state.refused = false; return exact[0]; }  // an earlier turn's "none of it yet" is no refusal once it shows
    const names = shown.map(optionText);
    if (names.length || !state.offered) state.offered = names;  // what the list last showed, kept if it closes before the cut-off
    const seen = state.offered;
    state.lack = `no ${what} option ${wanted}${seen.length ? `; offered: ${seen.slice(0, 8).join(", ")}${seen.length > 8 ? ` (+${seen.length - 8})` : ""}` : ""}`;
    state.refused = listed(shown);
    // A list that has given its answer and holds no match is refused at once rather than at routerd's deadline.
    if (state.refused === "final") throw refusal(state.lack);
    yield;
  }
}

// How the page's list takes a choice, measured in a hidden tab: a press (pointer down, up, click) on an option that is not highlighted
// is ignored, and Enter on a highlighted one too; arrow keys to highlight it, then the press, choose it. An option already chosen is
// never pressed: that unchooses it.
function* pick(state, find, options) {
  let moves = 0, lit;  // lit: the highlighted option after the last arrow press
  for (;;) {
    const option = yield* find();  // found again on each turn until it is pressed: a list that re-renders replaces its nodes
    if (option.getAttribute("aria-selected") === "true") return "already";  // chosen before we pressed: never pressed
    // A list with a search box takes them in its box; one without takes them itself (in a hidden tab the focus may not move to it).
    const search = option.closest('[role="dialog"]')?.querySelector('input[role="combobox"]');
    const keys = search ?? option.closest('[role="listbox"]') ?? option.parentElement;
    const now = options().find((node) => node.hasAttribute("data-highlighted")) ?? null;
    if (option.hasAttribute("data-highlighted")) {
      pressMarked(state, option);  // a save may be under way from here: the short wait for it, then a read decides
      return;  // not found again: the list may close or re-render without it, and `saved()` and the proving read decide
    }
    if (moves === 0 || now !== lit) {  // one arrow per change of highlight: a flush for anything else isn't one
      if (moves++ > options().length) throw new Error(`the keyboard never reached ${squash(option.textContent)}`);
      lit = now;
      keys.focus();
      keys.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", code: "ArrowDown", bubbles: true, cancelable: true }));
      state.lack = "the option never highlighted";
    }
    yield;
  }
}

// Opens a list from its combobox button with the keyboard and finds the option whose text is `wanted`, in this
// turn. Returns false when it was chosen already (never pressed), "move" when open and not chosen yet (`reach` highlights and presses it), "closed" or "unlit" when the list didn't open or
// the keyboard didn't reach the option (tried again: the options found then can be a closed list's), else the options it saw (none matched).
function chooseAtOnce(button, wanted) {
  const key = (node, name) => node.dispatchEvent(new KeyboardEvent("keydown", { key: name, code: name, bubbles: true, cancelable: true }));
  button.focus();
  key(button, "ArrowDown");
  if (button.getAttribute("aria-expanded") !== "true") return "closed";
  const options = optionsOf(button), exact = options.filter((node) => optionText(node) === wanted);
  let option = exact[0];
  if (exact.length > 1) throw refusal(`${exact.length} folder options match ${wanted}`);
  if (!option) return options.map(optionText);
  if (option.getAttribute("aria-selected") === "true") return false;
  return "move";  // never pressed here: a press made as the list opens is ignored (`reach` waits)
}

const press = (option) => {
  const at = { bubbles: true, cancelable: true, pointerType: "mouse", button: 0 };
  option.dispatchEvent(new PointerEvent("pointerdown", { ...at, buttons: 1 }));
  option.dispatchEvent(new MouseEvent("mousedown", { ...at, buttons: 1 }));
  option.dispatchEvent(new PointerEvent("pointerup", at));
  option.dispatchEvent(new MouseEvent("mouseup", at));
  option.dispatchEvent(new MouseEvent("click", { ...at, detail: 1 }));
  return true;
};

// The folder list takes a choice (measured in a hidden tab) as follows. ArrowDown on the button opens it with the first option
// highlighted; further arrows don't move the highlight reliably, but hovering an option (pointer and mouse over, enter and move
// dispatched on it) does. A press made within milliseconds of the list opening is ignored (the popup closes and nothing is chosen); one
// made PRESS_AFTER_OPEN after it opened chooses the option. The page lets presses through once a short timer of its own has run (likely
// ~400 ms): a hidden tab runs that timer at the next one-second slot, so up to ~1.4 s after the list opened, and a press before it is
// dropped with nothing to show for it (measured: 700 ms took ~40% of the time hidden, 1500 took 8 of 8). So `reach` hovers the wanted
// option until it is highlighted, waits until the list has been open that long, and presses it; the first option too, though ArrowDown
// already highlighted it. The wait is for no page change, so routerd wakes the step (`wakeAfter`: the tab's own timers can be throttled
// far longer). Each render can replace the nodes: the option is found again each time.
const PRESS_AFTER_OPEN = 1500;  // visible tab: 300 ms is ignored, 500 takes; hidden: see above
const hover = (node) => {
  const at = { bubbles: true, cancelable: true, pointerType: "mouse" };
  for (const type of ["pointerover", "pointerenter", "pointermove"]) node.dispatchEvent(new PointerEvent(type, at));
  for (const type of ["mouseover", "mouseenter", "mousemove"]) node.dispatchEvent(new MouseEvent(type, at));
};
function* reach(state, button, wanted) {
  const opened = performance.now();  // reached in the turn that opened the list
  let hovers = 0, woken = false;
  for (;;) {
    const options = optionsOf(button), option = options.find((node) => optionText(node) === wanted);
    if (button.getAttribute("aria-expanded") !== "true" || !option) return "closed";
    if (option.hasAttribute("data-highlighted")) {
      if (performance.now() - opened >= PRESS_AFTER_OPEN) return pressMarked(state, option);  // a save may be under way from here
      if (!woken) { woken = true; wakeAfter(Math.max(0, PRESS_AFTER_OPEN - (performance.now() - opened)) + 50); }
      state.lack = "the folder list is open but the option isn't pressable yet";
    } else {
      if (hovers++ > options.length) return "unlit";
      hover(option);
      state.lack = `the hover never highlighted ${wanted}`;
    }
    yield;
  }
}

const foldersBox = (dialog) => all("project-preapproved-folders", dialog)[0];
const searchBox = () => [...document.querySelectorAll('input[role="combobox"], [role="combobox"] input')].find((node) => !node.closest("[data-closed]")) ?? null;

// A folder's row names it in the element whose title is its full path; the row can also carry a note beside it (measured: a folder a
// terminal's Remote Control serves says it is approved for Remote Control only), which is no part of the path.
function rowPath(row) {
  const copy = (row.querySelector('[title^="/"]') ?? row).cloneNode(true);
  copy.querySelectorAll('button, .sr-only, [aria-hidden="true"], [data-testid="project-preapproved-folder-default"]').forEach((node) => node.remove());
  return squash(copy.textContent);
}

// Repositories are told by their shape, owner/name, in the Environment section outside the folders box and any list: that shape is data.
// A repository's row is the deepest element whose text holds exactly one such token, so a row whose text is split across child spans or
// has a suffix (` · main`) still reads as it, and a count like 3/10 (no letters) is no token.
const REPO = /(?<![\w./-])(?=[\w.-]*[A-Za-z])[\w.-]+\/(?=[\w.-]*[A-Za-z])[\w.-]+(?![\w./-])/g;
const repoTokens = (node) => squash(node.textContent).match(REPO) ?? [];
function reposOf(dialog) {
  const found = new Set();
  for (const node of dialog.querySelectorAll("*")) {
    if (node.closest('[data-testid="project-preapproved-folders"], [role="option"], [role="listbox"], nav, textarea, input')) continue;
    const tokens = repoTokens(node);
    if (tokens.length === 1 && ![...node.children].some((child) => repoTokens(child).length)) found.add(tokens[0]);
  }
  return [...found];
}

const setField = sequence(function* (command, state) {
  const goal = command.field === "goal";
  const dialog = yield* openFresh(state, command.project, !goal);
  yield* section(state, dialog, goal ? 0 : 1);
  const field = yield* wait(state, () => `no ${command.field} field (text boxes: ${boxesSeen(dialog)})`, () => fieldOf(dialog));
  state.before = field.value;
  if (sameText(field.value, command.text)) return yield* already(state, dialog);
  const since = performance.now();
  // Written, the change saves by the time the dialog closes (a hidden tab saves only then; a shown one already as the field is left),
  // even when it's a later step that closes it: from the words going in (`write`) it counts as done, and only the server's answer can undo that.
  write(field, command.text, state);
  const done = yield* close(state, dialog);
  return { ...done, saved: yield* saved(state, command.project, goal ? "record" : "config", since, goal ? "goal" : "instructions") };
});

const addRepo = sequence(function* (command, state) {
  const dialog = yield* openFresh(state, command.project, true);
  yield* section(state, dialog, 2);
  yield* wait(state, "no folders box", () => foldersBox(dialog));  // the section's content has rendered
  state.before = reposOf(dialog);
  if (state.before.includes(command.repo)) return yield* already(state, dialog);
  // The repositories' add button: never the folder list's combobox (a popup button too), nor any button in the folders box.
  const add = yield* wait(state, "no repository add button", () => [...dialog.querySelectorAll('button[aria-haspopup="dialog"]:not([role="combobox"])')].find((node) => !foldersBox(dialog)?.contains(node)));
  add.click();
  const input = yield* wait(state, "no repository search", searchBox);
  input.focus();
  document.execCommand("selectAll");
  const typed = performance.now();  // the search for these words starts after this: one from the popup's opening or an earlier add started before
  if (!document.execCommand("insertText", false, command.repo) || input.value !== command.repo) throw new Error("the page refused the words");
  yield;  // the list filters on the next render: an option clicked before it is one the page throws away
  const list = () => optionsOf(add);
  // The list is open, so no option is its answer; once the search for the typed words has answered, that answer is final when a flush
  // of the observer after its response ended touched the popup (the render of its results; an unrelated mutation in between is no
  // render), or RENDER_GRACE after it ended (a render with no match can change no DOM, so no flush would come). The resource observer's
  // callback runs the step when the answer is reported, a flush runs it again, and one timer armed when the answer is first seen runs it
  // at the end of the grace.
  // The popup its button names, as `optionsOf` finds its list (`namedBy`).
  const popup = () => namedBy(add) || searchBox()?.closest('[role="dialog"]') || null;
  let armed = null;
  const listed = () => {
    const answer = searches.find((s) => s.start >= typed && (s.q === null || s.q === command.repo));
    if (!answer) return !!searchBox();
    if (armed !== answer) { armed = answer; wakeAfter(RENDER_GRACE); }
    const now = performance.now(), box = popup();
    const rendered = lastFlush.at >= answer.end && !!box && (lastFlush.nodes.some((n) => n === box || box.contains(n)) || lastFlush.added.some((a) => a === box || a.contains(box)));
    return rendered || now - answer.end >= RENDER_GRACE ? "final" : !!searchBox();
  };
  if ((yield* pick(state, () => choose(state, command.repo, "repo", listed, list), list)) === "already") return yield* already(state, dialog);
  // The save's window opens at the press (`markPressed`), not before it: a settings request in between (a late fetch) isn't its answer.
  const status = yield* saved(state, command.project, "config", state.pressedAt, "repository", "the page saved nothing after the repository was chosen");
  return { ...(yield* close(state, dialog)), saved: status };
});

// A press the page doesn't take saves nothing: that is said as it is, not as a missing answer.
const NOTHING_SAVED = "the page saved nothing after the folder was chosen";
const preapproveFolder = sequence(function* (command, state) {
  const dialog = yield* openFresh(state, command.project, true);
  yield* section(state, dialog, 2);
  const box = yield* wait(state, "no folders box", () => foldersBox(dialog));
  state.before = all("project-preapproved-folder-row", box).map(rowPath);
  if (state.before.includes(command.path)) return yield* already(state, dialog);
  const add = yield* wait(state, "no folder add button", () => box.querySelector("button[aria-haspopup]"));
  // The list shuts when a click opens it and stays open when the keyboard does (measured), so it is opened from the keyboard and chosen
  // from in the same turn, and moved through only on the page's own updates (`reach`), which presses once the list has been open long enough.
  for (let tries = 1; ; tries++) {
    let offered = chooseAtOnce(add, command.path);
    if (offered === "move") offered = yield* reach(state, add, command.path);
    if (offered === false) return yield* already(state, dialog);  // the list marks it chosen (never pressed): routerd judges it against `before`
    if (offered === true) break;  // pressed and marked (`reach`): the short wait for its save, then a read decides
    // Its options may render a beat after it opens: tried again on the next updates; an open list with none matching is the answer.
    const retry = typeof offered === "string" ? { closed: "the folder list never opened", unlit: `the hover never highlighted ${command.path}` }[offered] : null;
    if (retry && tries >= 3) throw new Error(retry);
    if (!retry && (offered.length || tries >= 3)) throw refusal(`no folder option ${command.path}; offered: ${offered.join(", ") || "none"}`);
    state.lack = retry ?? "the folder list never opened";
    yield;
  }
  // The save's window opens at the press (`markPressed`), not when the list was first opened: the tries can take seconds.
  const status = yield* saved(state, command.project, "folders", state.pressedAt, "folder", NOTHING_SAVED);
  return { ...(yield* close(state, dialog)), saved: status };
});

// Dev only (the Router never removes a folder): removes a pre-approved folder from its row's options menu. The row's menu button and the
// menu's items are found by structure, since their words are localized: the button is the row's popup button, the item the menu's
// destructive one, else its last. The folders endpoint answers the removal as it does a grant (measured: its save follows the confirming
// press by ~10 ms); with no request there, the step reports `unsaved`, like a pick that saved nothing.
const DESTRUCTIVE = '[data-variant="destructive"], [data-destructive], [data-testid*="remove" i], [data-testid*="delete" i], [class*="destructive"], [class*="danger"]';
const removeFolder = sequence(function* (command, state) {
  const dialog = yield* openFresh(state, command.project, true);
  yield* section(state, dialog, 2);
  const box = yield* wait(state, "no folders box", () => foldersBox(dialog));
  const rows = all("project-preapproved-folder-row", box);
  state.before = rows.map(rowPath);
  const row = rows.find((node) => rowPath(node) === command.path);
  if (!row) throw refusal(`no folder ${command.path}; has: ${state.before.join(", ") || "none"}`);
  const trigger = yield* wait(state, "no options button on the folder's row", () => row.querySelector("button[aria-haspopup]"));
  let clicks = 0;  // a hidden tab can shut a menu again at once: the button is clicked again while no item shows, a few times at most
  // While its button says it is expanded, the open menu the button names (`namedBy`), if it has items; none until it names one (the wait
  // runs again on the next flush). Never just the last open menu: a hidden tab keeps an earlier menu open in the page, so it can be stale (measured).
  const menuNow = () => {
    const open = trigger.getAttribute("aria-expanded") === "true" ? namedBy(trigger) : null;
    return open?.querySelector('[role="menuitem"]') ? open : null;
  };
  const itemOf = (menu) => {
    const items = [...menu.querySelectorAll('[role="menuitem"]')];
    return items.length > 1 ? (items.find((node) => node.matches(DESTRUCTIVE) || node.querySelector(DESTRUCTIVE)) ?? items.at(-1)) : items[0];
  };
  const menu = yield* wait(state, "the folder's options menu never opened", () => {
    const shown = menuNow();
    if (!shown && trigger.getAttribute("aria-expanded") !== "true" && clicks < 3) { clicks++; trigger.click(); }
    return shown;
  });
  let item = itemOf(menu);
  // As in the folder list: an item is pressed only once hovered and PRESS_AFTER_OPEN after its menu opened, or the page ignores it. A
  // render can replace the item's node: it is found again each turn from the live menu (as `reach` does), and a menu that closed meanwhile
  // fails at once rather than at the deadline.
  const opened = performance.now();
  wakeAfter(PRESS_AFTER_OPEN + 50);
  yield* wait(state, "the menu item never took the hover", () => {
    const live = menuNow();
    // No live menu, or an item it no longer holds (gone, or in a menu marked closed): nothing was pressed, so nothing is committed.
    if (!live) throw new Error("the folder's options menu closed before its item was pressed");
    item = itemOf(live);
    if (!item?.isConnected || item.closest("[data-closed]")) throw new Error("the folder's options menu closed before its item was pressed");
    hover(item);
    return performance.now() - opened >= PRESS_AFTER_OPEN;
  });
  const since = performance.now();
  // A confirmation is an open dialog of its own with two buttons or more, outside the settings dialog. The page's toasts are dialogs too
  // ("settings saved", in the live region `scan` reads its notices from, and piled up open in a hidden tab): one that came with the
  // removal's save must not be taken for its confirmation and pressed, so nothing in a live region counts. That is by structure; focus
  // isn't required (the confirming button was focused, measured, but a hidden tab may not move focus) nor role=alertdialog (unmeasured).
  const asks = () => [...document.querySelectorAll(`[role="alertdialog"]${OPEN}, [role="dialog"]${OPEN}`)]
    .filter((node) => node !== dialog && !node.contains(dialog) && !dialog.contains(node) && !node.closest("[aria-live]") && node.querySelectorAll("button").length >= 2);
  const before = new Set(asks());
  press(item);
  // The page mostly asks before it stops using the folder: a new confirmation with two buttons, the confirming one focused and last
  // (measured). Some folders are removed at the menu's press with no confirmation (measured on one a terminal's Remote Control serves):
  // whichever comes first, the save's answer or the confirmation, is the next step. A hidden tab keeps earlier confirmations in the
  // page, closed or not, so only one that wasn't there before the press counts.
  markPressed(state);
  const none = "neither a save nor a confirmation followed the removal";
  const next = yield* wait(state, none, () =>
    requests.find((r) => r.project === command.project && r.kind === "folders" && r.start >= since) ?? asks().find((node) => !before.has(node))
      ?? (performance.now() - state.pressedAt >= SAVE_WAIT ? GAVE_UP : null));
  if (next === GAVE_UP) throw Object.assign(new Error(none), { unsaved: true });  // committed: the item was pressed
  if (next instanceof Element) {
    const buttons = [...next.querySelectorAll("button")], confirm = buttons.find((node) => node === document.activeElement) ?? buttons.at(-1);
    const shown = performance.now();
    wakeAfter(PRESS_AFTER_OPEN + 50);
    yield* wait(state, "the confirmation never became pressable", () => performance.now() - shown >= PRESS_AFTER_OPEN);
    press(confirm);
    markPressed(state);
  }
  const status = yield* saved(state, command.project, "folders", since, "folder removal", "the page saved nothing after the removal was chosen");
  return { ...(yield* close(state, dialog)), removed: true, saved: status };
});

// Reads the three sections, then closes the dialog.
const readSettings = sequence(function* (command, state) {
  // A fresh open (see openFresh): the page shows a change it saved before the server answers, even one the server refused (measured). The
  // read also waits for its second open's own fetch, as the steps that change settings do.
  const dialog = yield* openFresh(state, command.project, true);
  yield* section(state, dialog, 0);
  const goal = (yield* wait(state, () => `no goal field (text boxes: ${boxesSeen(dialog)})`, () => fieldOf(dialog))).value;
  yield* section(state, dialog, 1);
  const instructions = (yield* wait(state, () => `no instructions field (text boxes: ${boxesSeen(dialog)})`, () => fieldOf(dialog))).value;
  yield* section(state, dialog, 2);
  const box = yield* wait(state, "no folders box", () => foldersBox(dialog));
  const folders = all("project-preapproved-folder-row", box).map(rowPath), repos = reposOf(dialog);
  // Also in the read's `done` (with the address it was read at), which `recent` replays: an event sent while muted is lost.
  const settings = { type: "settings", project: command.project, goal, instructions, repos, folders, offered_folders: null };
  emit(settings);
  const read = { ...settings, path: location.pathname, thread: threadParam() };
  return { ...(yield* close(state, dialog)), settings: read };
});

// The Projects page's New project button: in the row of the page's heading, the one button that opens no popup and isn't marked
// icon-only (`data-cds-icon-only`: the others are the search and sort icons), by attributes, never its words. Measured; an exact count
// is asked of it.
const newProjectButton = () => {
  if (!oldViewGone()) return null;  // the old view's, still up after a move
  let row = document.querySelector("h1");
  while (row && row.querySelectorAll("button").length < 2) row = row.parentElement;
  const found = row ? [...row.querySelectorAll('button:not([aria-haspopup]):not([data-cds-icon-only])')].filter((node) => !node.closest(outsidePage)) : [];
  return found.length === 1 ? found[0] : null;
};

// The dialog's first text input is the name, its textarea the goal; its last button creates, once it is enabled. One click, then done:
// the proof is a later `projects` event listing the new project.
const NAME_INPUT = 'input:not([type]), input[type="text"]';  // the name field has no type attribute (measured)
const createProject = sequence(function* (command, state) {
  if (location.pathname !== "/code/projects/browse") throw new Error("not on the projects page");
  (yield* wait(state, "no new project button", newProjectButton)).click();
  const dialog = yield* wait(state, "no new project dialog", () => [...document.querySelectorAll(`[role="dialog"]${OPEN}`)].find((node) => node.querySelector(NAME_INPUT)));
  write(dialog.querySelector(NAME_INPUT), command.name);
  if (command.goal) write(yield* wait(state, "no goal field", () => dialog.querySelector("textarea")), command.goal);
  const create = yield* wait(state, "the create button stayed disabled", () => { const last = [...dialog.querySelectorAll("button")].pop(); return last && !last.disabled ? last : null; });
  create.click();
  return { ok: true };
});

// Dev only, on the owner's word: the project shown unarchived. Its note (`standIn`) holds one button, pressed once, and the step ends
// when its composer has replaced the note. Run it after an open of the project; the note is found by structure, never by its words.
const unarchive = sequence(function* (_command, state) {
  const note = yield* wait(state, "no archived note on this project", () => standIn("project"));
  const button = yield* wait(state, "no button in the note", () => note.querySelector("button"));
  button.click();
  state.committed = true;
  yield* wait(state, "the composer never replaced the note", () => !note.isConnected && box("project"));
  return { ok: true };
});

// ---- The top frame's frames (router-watch-and-briefs.md 1.1, 1.3). `frames {want: [{project, thread}], base}` is the engine's whole
// wanted set each time: the top frame diffs it against its own <iframe> nodes (removes what isn't wanted, adds what is missing) and says
// what it shows, `frames {have: [{name, project, thread, src}]}`, after each change and with every snapshot. Nodes go on
// `document.documentElement`, outside the page's React root, off screen at 1200×900 (measured: same renderer, same liveness). Their name is
// the frame's identity, `fjord:<project>:<thread|->`. `reload {frame}` sets a node's `src` again (a load). The top frame never decides a
// frame is blank or stale: it can't see a frame's port or a failed document; the worker and the engine do.
const frameName = (f) => `fjord:${f.project}:${f.thread ?? "-"}`;
const frameSrc = (f) => `${location.origin}/code/project/${f.project}${f.thread ? `?thread=${encodeURIComponent(f.thread)}` : ""}`;
const frameNodes = () => [...document.documentElement.children].filter((node) => node.tagName === "IFRAME" && parseName(node.name));
const FRAME_STYLE = "position:fixed;left:-12000px;top:0;width:1200px;height:900px;border:0;pointer-events:none;";
function framesHave() {
  emit({ type: "frames", have: frameNodes().map((node) => ({ name: node.name, ...parseName(node.name), src: node.getAttribute("data-fjord-src") })) });
}
function applyFrames(want) {
  const wanted = new Map((Array.isArray(want) ? want : []).filter((f) => typeof f?.project === "string").map((f) => [frameName(f), f]));
  for (const node of frameNodes()) if (!wanted.has(node.name)) node.remove();
  const have = new Set(frameNodes().map((node) => node.name));
  for (const [name, f] of wanted) {
    if (have.has(name)) continue;
    const node = document.createElement("iframe");
    node.name = name;
    node.setAttribute("aria-hidden", "true");
    node.setAttribute("tabindex", "-1");
    node.setAttribute("style", FRAME_STYLE);
    node.setAttribute("data-fjord-src", frameSrc(f));
    node.src = frameSrc(f);
    document.documentElement.appendChild(node);
  }
  framesHave();
}
function reloadFrame(frame) {
  const node = frame && frameNodes().find((other) => other.name === frameName(frame));
  if (node) node.src = node.getAttribute("data-fjord-src");
}

// ---- A frame's place (1.4). A project frame stays on its overview: whenever it is elsewhere (it lands on `?thread=`, the thread last
// shown for that project in this browser, at each load and 1.5 to 2.2 s after) it moves itself the way the page's links do
// (`history.pushState` to `/code/project/<id>`, then `popstate`; measured to take and to hold). Once the page shows its project side and the
// overview container (`[data-home-section]`, or `threads-empty-explainer` for a project with no thread) is still missing MOVE_GRACE after the move, it clicks `overview-thread-crumb-back` by test id,
// once; still none MOVE_GRACE later, or a move that keeps being undone (MOVES_MAX), and it reports `frame_stuck`, once per document: the
// engine reloads it (`reload`) or marks it stale. A thread frame never moves: one off its thread for MOVE_GRACE reports `frame_stuck` too.
const MOVE_GRACE = 1500, MOVES_MAX = 6;
const place = { phase: null, at: 0, moves: 0, stuck: false, off: null };
const onOverview = () => !!document.querySelector("[data-home-section]") || noThreads();
function moveToOverview() {
  place.phase = "moved"; place.at = performance.now(); place.moves++;
  history.pushState(history.state, "", `/code/project/${NAME.project}`);
  dispatchEvent(new PopStateEvent("popstate", { state: history.state }));
  wakeAfter(MOVE_GRACE + 50);
}
function stuck() {
  if (place.stuck) return;
  place.stuck = true; place.phase = "stuck";
  // `shown`: what the frame showed when it gave up, for diagnosis only (the engine reads none of it).
  const ids = [...new Set([...document.querySelectorAll("[data-testid]")].map((node) => node.getAttribute("data-testid")))].filter((id) => !id.startsWith("sidebar"));
  const shown = { path: location.pathname + location.search, moves: place.moves, sections: [...document.querySelectorAll("[data-home-section]")].map((node) => node.getAttribute("data-home-section")),
    ids: ids.slice(0, 40) };
  emit({ type: "frame_stuck", shown });
}
function watchPlace() {
  if (!FRAME || place.stuck) return;
  const now = performance.now();
  if (THREAD_FRAME) {
    if (shownProject() === NAME.project && threadParam() === NAME.thread) { place.off = null; return; }
    if (place.off === null) { place.off = now; wakeAfter(MOVE_GRACE + 50); return; }
    if (now - place.off >= MOVE_GRACE) stuck();
    return;
  }
  const right = shownProject() === NAME.project && threadParam() === null;
  if (right && onOverview()) { place.phase = null; return; }
  if (!right) {
    if (place.phase === "moved" && now - place.at < MOVE_GRACE) return;  // the move is under way
    if (place.moves >= MOVES_MAX) return stuck();
    return moveToOverview();
  }
  if (!box("project")) return;  // the page is still coming up: the engine's deadline covers a frame that never does
  if (place.phase === null) { place.phase = "moved"; place.at = now; wakeAfter(MOVE_GRACE + 50); return; }
  if (now - place.at < MOVE_GRACE) return;
  if (place.phase === "moved") {
    const crumb = all("overview-thread-crumb-back")[0];
    if (!crumb) return stuck();
    crumb.click();
    place.phase = "crumbed"; place.at = now;
    wakeAfter(MOVE_GRACE + 50);
    return;
  }
  stuck();
}
// ---- Answering a card by click (router-watch-and-briefs.md 3.5), in a thread frame only. `answer {id, project, thread, card, option}`:
// once this frame's thread side has sent a settled whole read (`told.owed.thread` false), the row whose `data-entry-key` is `card` must
// hold `[data-testid=decision-card]` with no `data-state` (pending); then the `option`th (1-based) `ul[role=list] button` of that card is
// clicked, by structure, once: no composer, no move. Guards: a card with a `data-state` ends `refused` ("already answered"), a row or card
// that isn't there ends `refused` ("card gone"), an option past the last ends `refused`; a button `aria-busy`, `aria-disabled` or
// `disabled` (the page is taking an answer, measured 0.2 to 0.8 s after a click) is never clicked: the step waits until the card shows
// answered, then ends `refused` ("already answered"). The `done` says `clicked: true`; the proof is the card's `answered` in this
// frame's rows, then the thread's row going `running`.
function answerStep(command) {
  const step = () => {
    if (!THREAD_FRAME || NAME.project !== command.project || NAME.thread !== command.thread) return { ok: false, refused: true, error: "not this thread's frame" };
    if (shownProject() !== NAME.project || threadParam() !== NAME.thread || told.owed.thread) return;  // its settled read hasn't come
    const row = (chatRows(true) ?? []).find((node) => [...node.querySelectorAll("[data-entry-key]")].some((key) => key.getAttribute("data-entry-key") === command.card));
    const card = row?.querySelector('[data-testid="decision-card"]');
    if (!card) return { ok: false, refused: true, error: "card gone" };
    if (card.hasAttribute("data-state")) return { ok: false, refused: true, error: "already answered" };
    const buttons = [...card.querySelectorAll('ul[role="list"] button')];
    if (buttons.some((b) => b.getAttribute("aria-busy") === "true" || b.getAttribute("aria-disabled") === "true" || b.disabled)) return;
    const button = Number.isInteger(command.option) ? buttons[command.option - 1] : null;
    if (!button) return { ok: false, refused: true, error: "no such option" };
    button.click();
    return { ok: true, clicked: true };
  };
  step.why = () => ({ error: told.owed.thread ? "the thread's read never settled" : "the card never took the answer" });
  return step;
}

// A frame runs only its watching steps; the top frame everything else.
const FRAME_STEPS = new Set(["answer"]);
const steps = { answer: answerStep, open: openStep, send: sendStep, create_project: createProject, set_field: setField, add_repo: addRepo, preapprove_folder: preapproveFolder, remove_folder: removeFolder, read_settings: readSettings, unarchive };

// Stops this instance for good: no observer, no waiting step, no port. A step woken by a timer afterwards finds nothing to run.
function stop() {
  stopped = true;
  try { chrome.runtime.onMessage.removeListener(hello); } catch { /* the runtime is gone with a reloaded extension */ }
  observer.disconnect();
  resources.disconnect();
  waiting.clear();
  port?.disconnect();
}

// A step's delayed wake-up. A hidden tab's timers are throttled (measured: a wake-up late by 15-20 s after the tab was hidden for
// minutes), a message over the port is not: routerd is asked to send `wake` after `ms`, and the timer stays as the fallback.
// A `wake_me` can go unsaid or be lost: asked while muted (or while connect() muted a lost port), or sent while the worker has no host
// (its `toHost` drops it, the port not muted). So every due time is kept (`owedWakes`) until it passes, and each snapshot (the worker
// sends one when the host links again) asks again for each one still to come (routerd keeps a set of wakes: the latest alone would lose
// the earlier ones; one asked twice only wakes twice, and a wake is idempotent).
const owedWakes = new Set();
function wakeAfter(ms) {
  setTimeout(woken, ms);
  emit({ type: "wake_me", after: ms });
  owedWakes.add(performance.now() + ms);
}
const pruneWakes = (at) => { for (const due of owedWakes) if (due <= at) owedWakes.delete(due); };

// A wake-up runs what a flush does: the scan (a side waiting out `settledEmpty`'s grace) and the waiting steps. Both are idempotent.
function woken() {
  if (!alive()) { try { stop(); } catch {} return; }
  pruneWakes(performance.now());  // the due times passed: this wake (or an earlier one) covers them
  settleWakes.project = settleWakes.thread = 0;  // this wake's scan asks again for any side still owed
  scan(false);
  settle();
}

function settle() {
  if (!alive()) { try { stop(); } catch {} return; }
  for (const [id, step] of waiting) {
    // A step that throws is over, with the error: the other steps still run.
    let result;
    try { result = step(); } catch (error) { result = { ok: false, error: String(error?.message ?? error) }; }
    if (!result) continue;
    waiting.delete(id);
    step.ended?.("done");
    done(id, result);
  }
}

function onMessage(message) {
  if (message.kind === "stop") return stop();
  if (message.kind === "wake") return woken();  // routerd's timer for a `wake_me`: runs the scan and the waiting steps, has no id and sends no `done`
  if (message.kind === "tagged") { if (!FRAME) { tagged = globalThis.__fjordTagged = true; keepTag(); } return; }  // kept for a script injected after a stop
  // The engine's frame set and a frame's reload, for the top frame only: no id, no `done`; what it shows is said as `frames {have}`.
  if (message.kind === "frames") return void (!FRAME && applyFrames(message.want));
  if (message.kind === "reload") return void (!FRAME && reloadFrame(message.frame));
  if (message.kind === "snapshot") {
    muted = false;
    emit({ type: "commands", waiting: [...waiting.keys()], done: [...recent], instance: INSTANCE });
    if (!FRAME) framesHave();  // what the top frame shows, with every snapshot: the engine diffs its wanted set against it
    // A wake asked since the last link may have gone unsaid or been lost: a `wake_me` for each distinct due time still to come asks again
    // for all of them, the sides' settle wakes too (they are owed wakes like any other: `settleWakes` stays, so the snapshot's scan doesn't
    // add a second one for a side), and a step that asked once (`woke`/`woken`/`armed`) doesn't ask again. They stay kept until they pass:
    // a host lost again before then is asked again at the next snapshot. One already due is covered by the `settle()` below.
    const at = performance.now();
    pruneWakes(at);
    const afters = new Set([...owedWakes].map((due) => Math.ceil(due - at)));
    for (const after of [...afters].sort((a, b) => a - b)) emit({ type: "wake_me", after });
    snapshot();
    // The worker sends one after adopting the page: a wake due meanwhile may have been lost (a restarted worker, a host that linked
    // before the page did), so the waiting steps run now too.
    return settle();
  }
  if (message.kind === "cancel") {
    const step = waiting.get(message.target);
    waiting.delete(message.target);
    step?.ended?.("cancelled");
    // A step that names what it waits for says so when it is cut off by its deadline: a missing element is an error, never a guess.
    if (step?.why) done(message.target, { ok: false, ...step.why() });
    return;
  }
  const make = steps[message.kind];
  if (!make) return done(message.id, { ok: false, error: "unknown command" });
  if (FRAME !== FRAME_STEPS.has(message.kind)) return done(message.id, { ok: false, refused: true, error: FRAME ? "a watching frame only reports" : "only a frame runs that" });
  // A newer command of the same kind on the same side replaces the one still waiting. A replaced tool step says what it got to, as a
  // cut-off one does (`committed`, `before`, `refused`), so routerd can judge what it may have left done.
  for (const [id, step] of waiting) {
    if (step.command.kind === message.kind && step.command.side === message.side) { waiting.delete(id); step.ended?.("superseded"); done(id, { ok: false, ...(step.why ? step.why() : {}), error: "superseded" }); }
  }
  const step = make(message);
  step.command = message;
  waiting.set(message.id, step);
  settle();
}

// The observer's callback is itself the microtask that coalesces a burst of mutations into one pass.
const observer = new MutationObserver((records) => { if (!alive()) { try { stop(); } catch {} return; } lastFlush = { at: performance.now(), nodes: records.map((r) => r.target), added: records.flatMap((r) => [...r.addedNodes]) }; scan(false); settle(); });
observer.observe(document.body, {
  childList: true,
  subtree: true,
  characterData: true,
  attributes: true,
  attributeFilter: ["disabled", "data-index", "data-entry-key", "data-perf-row-streaming", "data-perf-row", "data-home-card", "data-home-section", "data-home-title", "data-home-status-line", "data-home-status-mark", "aria-current", "aria-expanded", "aria-selected", "data-highlighted", "data-closed",
    // a card answered or busy, the coordinator card's glyph, the overview's list loaded: each changes what a scan or a step reads
    "data-state", "aria-busy", "aria-disabled", "data-glyph", "data-home-state"],
});
// A script with no port (its connect failed, or its reconnect did) connects again rather than say it is alive with nothing to adopt.
// The worker asking is a reason to connect now, whatever the backoff says (`connectAfter`): it is the one that wants a page.
// A frame never answers it: the alive check is the top frame's (the worker asks frameId 0 anyway).
const hello = (message, _sender, reply) => { if (message.kind === "hello" && !FRAME) { if (!port) connectAfter = 0; reply({ ok: !stopped && !!(port ?? connect()) }); } };
chrome.runtime.onMessage.addListener(hello);

connect();
// The scan at start only notes what the page shows (`told`, the arrival): it sends nothing (connect() muted the port), so the snapshot that follows the worker's
// adoption speaks first, `commands` before any whole read.
// A notice up at start is said by that snapshot's scan too: a muted scan doesn't note the notices it couldn't say (`told.notice`).
scan(true);
})();
