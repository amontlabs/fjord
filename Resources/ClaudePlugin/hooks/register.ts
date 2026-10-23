import type { EngineInterface, Register } from 'claude-code'

// Fjord's Router relays what the person writes to this session. The message arrives on the peer channel,
// signed by the Fjord app with a key only it holds (a file of Fjord's own, readable by the person
// alone, never in this folder: Claude Code copies an installed plugin's folder into its cache). A valid one, addressed
// to this session, fresh and never seen before, is taken off the peer channel and submitted as the person's own words.
// Anything else passes on untouched, as the peer message it is.
//
// The wire format: a header line, then the body's UTF-8 bytes in base64 on one line (so the peer channel's escaping and
// any Unicode normalization can't touch them):
//   ⟦fjord v1 <target session id> <nonce> <ms since 1970> <hex HMAC-SHA256>⟧\n<base64 body>
// The MAC covers the UTF-8 bytes of "v1\n<target>\n<nonce>\n<ms>\n" followed by the body's own UTF-8 bytes.
//
// Ways in, one check. The app's own send (`carry-v1` below) hands the message over as a peer message, to `session.receive`
// in a running session and as the first prompt of a sleeping one. The inbox is the direct way, with no model in between:
// Fjord writes the very same signed text to `<inboxDir>/<session id>/<nonce>.msg` (atomically: a dot-file
// renamed into place), the plugin polls that folder every half second, runs the same check, and answers with
// `<nonce>.ack` beside it ("ok", or "refused: why"). Fjord reads the ack and deletes both files; the plugin
// has no way to delete, and needs none. Presence files list `capabilities`, so Fjord knows how a
// session can be reached.
//
// `settings-v1`: a v2 message carries the model and effort the session should use, inside the signed bytes:
//   ⟦fjord v2 <target> <nonce> <ms> <model|-> <effort|-> <hex HMAC-SHA256>⟧\n<base64 body>
// with the MAC over "v2\n<target>\n<nonce>\n<ms>\n<model|->\n<effort|->\n" and the body. A plugin without the capability
// sees an unknown header (unsigned) and ignores it; Fjord only sends v2 to a plugin that advertises `settings-v1`.
// From the inbox (never the peer channel, whose hook the turn waits on), the plugin sets the model, then the effort (a
// model switch resets the effort), with `/model` and `/effort` run for this session only, and only then submits the
// text, so the turn it starts uses them. The ack says what happened: "ok model=opus effort=high", or "model=error:why".
//
// `abort-v1`: Fjord can take back a delivery it made, with a control file in the same inbox, signed the same way:
//   ⟦fjord abort v1 <target> <nonce> <ms> <nonce of the delivery> <hex HMAC-SHA256>⟧
// with the MAC over "abort-v1\n<target>\n<nonce>\n<ms>\n<nonce of the delivery>\n" (no body). Its own nonce is claimed as a
// delivery's is (no replay). This copy remembers each delivery it submitted and the turn it started (the next main turn
// whose text is that delivery's, or holds it with other deliveries), and answers in the ack, "ok " and how:
//   before-start  it never started: not seen yet (it will be refused when it comes), or queued behind a running turn, its
//                 turn then ended the moment it starts (unless Claude Code reads it together with words of the
//                 person's own: those are never stopped)
//   aborted       its turn was running, and is stopped: the tools it is running are answered at once (else an abort
//                 sends a running Bash command to the background, and its end wakes the session to carry on), then
//                 $.turn.abort; a notification from one of its tools after that is dropped, so the session doesn't take
//                 the cancelled request up again. The command's process itself runs to its end: no hook can stop it.
//   together      its turn also holds words of the person's own: it isn't stopped, so neither are they
//   too-late      its turn is over
//   unknown       this copy never saw it, but one did (a reload since): it can't tell
// Nothing an aborted turn already did is undone, and the words stay in the session's history: Claude Code has no way to
// take a submitted prompt back out.
//
// `stop-v1`: Fjord can stop whatever turn the session is running, started by a delivery or not, with a control file in
// the same inbox, signed the same way:
//   ⟦fjord stop v1 <target> <nonce> <ms> <turn id|-> <hex HMAC-SHA256>⟧
// with the MAC over "stop-v1\n<target>\n<nonce>\n<ms>\n<turn id|->\n". Its nonce is claimed as a delivery's is. With a turn
// id, only that turn is stopped (a newer one is left alone): the ack is "ok not-running" when it isn't the running turn.
// With `-`, whatever turn runs. No turn: "ok idle". Otherwise the tools the turn is running are answered at once, then
// $.turn.abort, and a notice "Stopped from Fjord" is added to the session: "ok stopped <turn id>". Every main turn is
// covered, not only a delivery's.
//
// `interrupt-v1`: a v3 message is a v2 one with a signed interrupt flag after the effort:
//   ⟦fjord v3 <target> <nonce> <ms> <model|-> <effort|-> <0|1> <hex HMAC-SHA256>⟧\n<base64 body>
// with the MAC over "v3\n<target>\n<nonce>\n<ms>\n<model|->\n<effort|->\n<0|1>\n" and the body.
// `interrupt-turn-v1`: a v4 message adds the turn the interrupt was judged on after the flag:
//   ⟦fjord v4 <target> <nonce> <ms> <model|-> <effort|-> <0|1> <turn id|-> <hex HMAC-SHA256>⟧\n<base64 body>
// with the MAC over "v4\n<target>\n<nonce>\n<ms>\n<model|->\n<effort|->\n<0|1>\n<turn id|->\n" and the body. With a turn id
// the interrupt is refused ("refused: turn changed", nothing submitted, the nonce not claimed) unless that turn is the one
// running, checked before the nonce is claimed (so a retry of an unclaimed message is checked again) and again by the stop. From the inbox, with the flag
// set, the turn under way (if any) is stopped as above, then the settings are applied and the words submitted as the
// person's own, in one step: the ack is "ok interrupted <turn id>" or "ok idle" (then it only submits), followed by what
// the settings did. Plain v1 and v2 messages keep queueing behind a running turn. Over the peer channel (whose hook a turn
// waits on) a v3 message is not taken at all.
//
// An interrupt is refused ("refused: why", nothing submitted) when its words can't be submitted (empty, or a slash command:
// checked before anything is stopped), when the running turn can't be stopped, or when the submit is rejected.
//
// A subagent belongs to the main turn that spawned it, found from the spawn's parent: a background agent of an older turn that
// spawns another during a newer turn keeps it with the older one, so stopping the newer turn leaves it be.
//
// Presence files carry `turn`: `{ id, startedAt }` while a main turn runs, null when idle, rewritten as the turn starts and
// as it completes.
//
// `carry-v1`: every message of the person's goes the same way, whether its session runs or sleeps: Fjord orders the plugin of
// another session the Claude app runs (the carrier) to hand the signed message to the app's own send tool. A carry order is
// a control file in the carrier's inbox, signed the same way:
//   ⟦fjord carry v1 <carrier> <nonce> <ms> <local_ id of the target> <hex HMAC-SHA256>⟧\n<base64 of the signed message>
// with the MAC over "carry-v1\n<carrier>\n<nonce>\n<ms>\n<local_ id>\n" followed by the message's UTF-8 bytes. Its nonce is
// claimed as a delivery's is. The carrier writes `<nonce>.taken` as it starts, then calls
// `$.mcp.call('ccd_session_mgmt', 'send_message', { session_id, message })` (no model turn, nothing in the carrier's
// conversation) and acks with the app's own answer, "ok <what the app said>" or "refused: why". What the app says is only
// what it saw (it reports a running session whose plugin took the message as "not delivered"): the target's ack says it went.
// The message must be a signed message of Fjord's for another session.
//
// The app puts the message in the target in an envelope, `<cross-session-message from="…" name="…">\n<body>\n</cross-session-message>`,
// escaping in the body only a "<" that opens a tag it knows (and "@" across machines): Fjord's signed text, a header line and
// base64, has neither. Two ways in, one check (`accept`):
//   - the target runs: the app hands the envelope to `session.receive` (the body may be followed by a notice that it came from
//     another Claude). A valid message is consumed and its words submitted as the person's own, as an inbox file's are, with
//     its settings applied first; an interrupt never comes this way.
//   - the target sleeps: the app starts it with the envelope as its first prompt, after its own guidance (system-reminders).
//     `prompt.submit` rewrites the prompt to the words alone, the guidance riding as `context`, so Claude reads the words as
//     the person's own and the app shows an ordinary message of theirs. Settings are applied first, bounded.
// Either way the plugin answers in the target's inbox folder, `<nonce>.ack` ("ok", or "refused: why" once the signature held),
// which is how Fjord knows it went. Any other envelope passes on untouched as the peer message it is.
//
// Fjord writes this file; edits are overwritten.

const HEADER = /(?:^|\n)⟦fjord (?:v1 (\S+) (\S+) (\d+)|v2 (\S+) (\S+) (\d+) (\S+) (\S+)|v3 (\S+) (\S+) (\d+) (\S+) (\S+) ([01])|v4 (\S+) (\S+) (\d+) (\S+) (\S+) ([01]) (\S+)) ([0-9a-f]{64})⟧\n/
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/
const CLOSE = '</cross-session-message>'
const WINDOW_MS = 10 * 60 * 1000
const NONCE = 'nonce.'
export const CAPABILITIES = ['inbox-v1', 'settings-v1', 'abort-v1', 'stop-v1', 'interrupt-v1', 'interrupt-turn-v1', 'carry-v1']
const POLL_MS = 500
const ACTIVATION = crypto.randomUUID()

const enc = new TextEncoder()
const hex = (bytes: Uint8Array) => [...bytes].map((x) => x.toString(16).padStart(2, '0')).join('')
const join = (...parts: Uint8Array[]) => {
  const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let at = 0
  for (const p of parts) {
    all.set(p, at)
    at += p.length
  }
  return all
}
const sha256 = async (...parts: Uint8Array[]) => new Uint8Array(await crypto.subtle.digest('SHA-256', join(...parts)))

/** HMAC-SHA256 (RFC 2104) on the environment's SHA-256, the one digest it has. */
export const hmac = async (key: Uint8Array, message: Uint8Array) => {
  const block = new Uint8Array(64)
  block.set(key.length > 64 ? await sha256(key) : key)
  const inner = block.map((x) => x ^ 0x36)
  const outer = block.map((x) => x ^ 0x5c)
  return hex(await sha256(outer, await sha256(inner, message)))
}

const ABORT = /^⟦fjord abort v1 (\S+) (\S+) (\d+) (\S+) ([0-9a-f]{64})⟧\n?/

/** What an abort's MAC covers: its kind, the target, its nonce, its time and the delivery it takes back, one per line. */
export const abortMacInput = (target: string, nonce: string, ts: string, cancels: string) =>
  enc.encode(`abort-v1\n${target}\n${nonce}\n${ts}\n${cancels}\n`)

/** An abort's fields; undefined for anything else. */
export const parseAbort = (text: string) => {
  const m = ABORT.exec(text)
  return m ? { target: m[1], nonce: m[2], ts: m[3], cancels: m[4], mac: m[5] } : undefined
}

const CARRY = /^⟦fjord carry v1 (\S+) (\S+) (\d+) (local_[A-Za-z0-9_-]+) ([0-9a-f]{64})⟧\n/

/** What a carry order's MAC covers: its kind, the carrier, its nonce, its time and the app's id of the target, one per line,
 * then the signed message's bytes. */
export const carryMacInput = (carrier: string, nonce: string, ts: string, local: string, message: Uint8Array) =>
  join(enc.encode(`carry-v1\n${carrier}\n${nonce}\n${ts}\n${local}\n`), message)

/** A carry order's fields and the signed message it carries; undefined for anything else. */
export const parseCarry = (text: string) => {
  const m = CARRY.exec(text)
  if (!m) return undefined
  const bytes = fromBase64(text.slice(m[0].length).trim())
  if (!bytes) return undefined
  let message: string
  try {
    message = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch {
    return undefined
  }
  return { carrier: m[1], nonce: m[2], ts: m[3], local: m[4], mac: m[5], bytes, message }
}

const OPEN = /<cross-session-message\b[^>]*>\n?/

/** What a delivery of the app's holds: the body of its cross-session envelope, exactly (the one newline after the opening tag
 * and the one before the close are the envelope's, nothing else is taken off), what the app said before it (its guidance, a
 * leading system-reminder) and after it (the notice that it came from another Claude). A text with no complete envelope is
 * all body. */
export const unwrap = (text: string) => {
  const open = OPEN.exec(text)
  const end = open ? text.indexOf(CLOSE, open.index + open[0].length) : -1
  if (!open || end < 0) return { wrapped: false, before: '', body: text, after: '' }
  let body = text.slice(open.index + open[0].length, end)
  if (body.endsWith('\n')) body = body.slice(0, -1)
  return { wrapped: true, before: text.slice(0, open.index).trim(), body, after: text.slice(end + CLOSE.length).trim() }
}

const STOP = /^⟦fjord stop v1 (\S+) (\S+) (\d+) (\S+) ([0-9a-f]{64})⟧\n?/

/** What a stop's MAC covers: its kind, the target, its nonce, its time and the turn it stops (`-`: whichever runs). */
export const stopMacInput = (target: string, nonce: string, ts: string, turn: string) =>
  enc.encode(`stop-v1\n${target}\n${nonce}\n${ts}\n${turn}\n`)

/** A stop's fields; undefined for anything else. */
export const parseStop = (text: string) => {
  const m = STOP.exec(text)
  return m ? { target: m[1], nonce: m[2], ts: m[3], turn: m[4], mac: m[5] } : undefined
}

/** The model and effort a v2 message asks for; `-` on the wire is none. */
export type Settings = { model?: string; effort?: string }

/** What the MAC covers: the version, the target, the nonce and the time, one per line (v2: also the model and the effort),
 * then the body's bytes. */
export const macInput = (target: string, nonce: string, ts: string, body: Uint8Array, settings?: Settings, interrupt?: boolean, expectTurn?: string) =>
  join(
    enc.encode(
      expectTurn !== undefined
        ? `v4\n${target}\n${nonce}\n${ts}\n${settings?.model ?? '-'}\n${settings?.effort ?? '-'}\n${interrupt ? 1 : 0}\n${expectTurn}\n`
        : interrupt !== undefined
        ? `v3\n${target}\n${nonce}\n${ts}\n${settings?.model ?? '-'}\n${settings?.effort ?? '-'}\n${interrupt ? 1 : 0}\n`
        : settings
          ? `v2\n${target}\n${nonce}\n${ts}\n${settings.model ?? '-'}\n${settings.effort ?? '-'}\n`
          : `v1\n${target}\n${nonce}\n${ts}\n`,
    ),
    body,
  )

const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max']
/** A model `/model` takes: an alias (with the 1M-context suffix), or a full id. */
const MODEL = /^(?:(?:opus|sonnet|haiku|fable)|claude-[a-z0-9][a-z0-9.-]*)(?:\[1m\])?$/
/** Why a settings request can't be applied (undefined: fine). */
export const invalid = (s: Settings) =>
  s.model !== undefined && !MODEL.test(s.model) ? `invalid model ${JSON.stringify(s.model.slice(0, 40))}`
    : s.effort !== undefined && !EFFORTS.includes(s.effort) ? `invalid effort ${JSON.stringify(s.effort.slice(0, 40))}`
      : undefined

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

/** Standard base64 (padded) to bytes; undefined for anything else. */
export const fromBase64 = (text: string) => {
  if (!BASE64.test(text) || text.length % 4 !== 0) return undefined
  const clean = text.replace(/=+$/, '')
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4))
  let bits = 0
  let value = 0
  let at = 0
  for (const c of clean) {
    value = (value << 6) | ALPHABET.indexOf(c)
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out[at++] = (value >> bits) & 0xff
    }
  }
  return out
}

/** The signed message in a text (an inbox file, or an envelope's body from `unwrap`): its header's fields and the body's bytes. */
export const parse = (text: string) => {
  const m = HEADER.exec(text)
  if (!m) return undefined
  const header = m[0]
  const v2 = m[4] !== undefined
  const v3 = m[9] !== undefined
  const v4 = m[15] !== undefined
  const [target, nonce, ts] = v4 ? [m[15], m[16], m[17]] : v3 ? [m[9], m[10], m[11]] : v2 ? [m[4], m[5], m[6]] : [m[1], m[2], m[3]]
  const mac = m[22]
  const [model, effort] = v4 ? [m[18], m[19]] : v3 ? [m[12], m[13]] : [m[7], m[8]]
  const settings: Settings | undefined =
    v2 || v3 || v4 ? { model: model === '-' ? undefined : model, effort: effort === '-' ? undefined : effort } : undefined
  const interrupt = v4 ? m[20] === '1' : v3 ? m[14] === '1' : undefined
  // v4: the turn the interrupt was judged on (`-`: none named), covered by the MAC.
  const expectTurn = v4 ? m[21] : undefined
  const body = fromBase64(text.slice(m.index + header.length).trim())
  if (!body) return undefined
  return { target, nonce, ts, mac, body, settings, interrupt, expectTurn }
}

/** Compares two MACs in time that doesn't depend on where they differ. */
const same = (a: string, b: string) => {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

/** One nonce check-and-claim at a time in this copy of the plugin: two deliveries of the same message can't both pass. */
let claims: Promise<unknown> = Promise.resolve()
const exclusive = <T>(work: () => Promise<T>): Promise<T> => {
  const run = claims.then(work, work)
  claims = run.catch(() => undefined)
  return run
}

/** Where Fjord keeps the key and the presence files, and Claude Code its registry of processes, as absolute paths (a
 * hooks module can't read the environment). */
type Config = { keyPath?: string; presenceDir?: string; sessionsDir?: string; inboxDir?: string }

async function config($: EngineInterface) {
  return JSON.parse(await $.fs.read(`${$.plugin.root}/config.json`)) as Config
}

/** Which key a presence file was written under: the first 16 hex digits of the key's SHA-256, never the key. */
export const keyId = async (key: string) => hex(await sha256(enc.encode(key))).slice(0, 16)

/** The session this copy last said it runs in, under which key, where it said so, and the process it found for it. */
let marked: { sessionId: string; presenceDir: string; keyId: string; pid: number; startedAt: number } | undefined

/** Says which session this plugin runs in, bound to its process (Claude Code's registry entry for the session: its pid
 * and start time) and to the key Fjord holds now, so Fjord can tell a live session from one that crashed, was resumed
 * without the plugin, or unloaded it while the Router was off. It is a lease: renewed at every turn and every 10 s
 * (`renewedAt`), so a plugin disabled and reloaded away, which says nothing as it goes, stops counting within 30 s.
 * The registry is read again when the session id changes (a /clear starts a new one with no session.start) or the key
 * does (the Router was switched off and on: its old presence files are gone). */
async function mark($: EngineInterface) {
  const { presenceDir, sessionsDir, keyPath } = await config($)
  if (!presenceDir || !sessionsDir || !keyPath) return
  const key = (await $.fs.read(keyPath).catch(() => '')).trim()
  if (!key) {
    // The Router is off: nothing to say until there's a key again.
    marked = undefined
    return
  }
  const id = await keyId(key)
  const sessionId = await $.session.id()
  let own: { pid: number; startedAt: number } | undefined =
    marked?.sessionId === sessionId && marked.keyId === id ? { pid: marked.pid, startedAt: marked.startedAt } : undefined
  if (!own) for (const entry of await $.fs.list(sessionsDir)) {
    if (!entry.name.endsWith('.json')) continue
    let found: { sessionId?: unknown; pid?: unknown; startedAt?: unknown }
    try {
      found = JSON.parse(await $.fs.read(`${sessionsDir}/${entry.name}`))
    } catch {
      continue
    }
    if (found?.sessionId === sessionId && typeof found.pid === 'number') {
      const startedAt = typeof found.startedAt === 'number' ? found.startedAt : 0
      if (!own || startedAt > own.startedAt) own = { pid: found.pid, startedAt }
    }
  }
  if (!own) return
  if (marked && marked.sessionId !== sessionId) {
    await $.fs.write(`${marked.presenceDir}/${marked.sessionId}`, `${JSON.stringify({ state: 'ended' })}\n`)
  }
  const renewedAt = await $.clock.now()
  const turn = running === undefined ? null : { id: running, startedAt: runningSince }
  const presence = { state: 'live', sessionId, pid: own.pid, startedAt: own.startedAt, keyId: id, renewedAt, activation: ACTIVATION, capabilities: CAPABILITIES, turn }
  await $.fs.write(`${presenceDir}/${sessionId}`, `${JSON.stringify(presence)}\n`)
  marked = { sessionId, presenceDir, keyId: id, pid: own.pid, startedAt: own.startedAt }
}

async function unmark($: EngineInterface) {
  if (!marked) return
  await $.fs.write(`${marked.presenceDir}/${marked.sessionId}`, `${JSON.stringify({ state: 'ended' })}\n`)
  marked = undefined
}

/** Claims a nonce: false when it was claimed before. Each nonce is a key of its own in the store (it outlives reloads and
 * restarts), kept while its message's time is inside the window: past it the message is refused as stale anyway. */
const claim = ($: EngineInterface, nonce: string, ts: number, now: number) =>
  exclusive(async () => {
    if ((await $.store.get(NONCE + nonce)) !== undefined) return false
    await $.store.set(NONCE + nonce, ts)
    for (const name of await $.store.keys()) {
      if (!name.startsWith(NONCE)) continue
      const at = Number(await $.store.get(name))
      if (!(Math.abs(now - at) < WINDOW_MS)) await $.store.delete(name)
    }
    return true
  })

/** Whether a nonce was claimed already (nothing is claimed). */
const claimed = ($: EngineInterface, nonce: string) => exclusive(async () => (await $.store.get(NONCE + nonce)) !== undefined)

/** A delivery this copy submitted, by its nonce: its words and when, the turn it started once one did (and whether that
 * turn holds words of the person's own too, or is still starting), and whether that turn is over or was taken back before
 * it began. Kept for the window an abort is taken in, the latest few at most. */
type Sent = { body: string; at: number; turnId?: string; mixed?: boolean; starting?: boolean; ended?: boolean; cancelled?: boolean }
const sent = new Map<string, Sent>()
const SENT_KEPT = 50
/** A body this long is told apart inside a turn that holds other words too; a shorter one only as the whole turn. */
const DISTINCT = 24
/** The main loop's turn under way, by `turn.start` and `turn.complete`, and when it began (ms since 1970). */
let running: string | undefined
let runningSince = 0
/** In a main turn: the tool calls under way, each with what cuts it short, the ids of every call made, and
 * the subagents it spawned. */
type Calls = { cuts: Set<() => void>; ids: Set<string>; agents: Set<string> }
const calls = new Map<string, Calls>()
/** The main turn that owns each subagent (by the agent's id): a spawn from the main loop belongs to the turn running, one
 * from a subagent to that subagent's owner, so an older turn's background agent spawning during a newer turn stays the older
 * turn's. The latest few only. */
const owners = new Map<string, string>()
const OWNERS_KEPT = 500
/** The tool calls of turns taken back, with when: a notification naming only them (a background command ending) is
 * dropped. Kept an hour. */
const quiet = new Map<string, number>()
const QUIET_MS = 60 * 60 * 1000

/** Forgets every delivery and turn (tests: each starts a fresh copy's memory). */
export const forget = () => {
  sent.clear()
  calls.clear()
  owners.clear()
  quiet.clear()
  running = undefined
  runningSince = 0
  inFlight.clear()
  later.length = 0
  deliveries = Promise.resolve()
}

/** Stops what a turn's tools are doing, and keeps their notifications out from now on. `record` is the turn's record taken
 * before an abort was awaited: the turn may have completed (and dropped its record) meanwhile, and its tools are still cut. */
const silence = (turnId: string, now: number, record = calls.get(turnId)) => {
  if (!record) return
  for (const cut of record.cuts) cut()
  for (const id of record.ids) quiet.set(id, now)
  if (calls.get(turnId) === record) calls.delete(turnId)
}

/** Forgets deliveries past the window (an abort of one is refused as stale anyway) and notifications kept long enough. */
const prune = (now: number) => {
  for (const [nonce, s] of sent) if (!(Math.abs(now - s.at) < WINDOW_MS)) sent.delete(nonce)
  for (const [id, at] of quiet) if (!(Math.abs(now - at) < QUIET_MS)) quiet.delete(id)
}

const remember = (nonce: string, body: string, now: number) => {
  prune(now)
  sent.set(nonce, { body, at: now })
  while (sent.size > SENT_KEPT) sent.delete(sent.keys().next().value as string)
}

/** Submits a delivery's words; one a hook drops, or that fails, started nothing and is forgotten (else a later turn of the
 * person's own could be taken for its turn). */
const submit = ($: EngineInterface, nonce: string, body: string): Promise<string | undefined> => {
  const forgotten = () => {
    if (sent.get(nonce)?.turnId === undefined) sent.delete(nonce)
  }
  return $.prompt.submit({ text: body, asUser: true }).then(
    (r) => {
      if (r && 'drop' in r && r.drop !== undefined) {
        forgotten()
        return String(r.drop)
      }
      return undefined
    },
    (error) => {
      forgotten()
      return String((error as { message?: unknown })?.message ?? error)
    },
  )
}

/** Whether `$.prompt.submit` takes this text: not empty, not a slash command (those are rejected). Undefined: fine. */
const unsubmittable = (body: string) => {
  const text = body.trim()
  return text === '' ? 'nothing to send' : text.startsWith('/') ? 'a slash command can’t be sent as a message' : undefined
}

/** The deliveries a main turn starts with: each one waiting whose words are the turn's text, or, when Claude Code read
 * queued prompts together, whose (distinctive) words it holds. `mixed`: the turn holds words of no delivery too (the
 * person's own). */
const startedBy = (text: string, now: number) => {
  prune(now)
  const said = text.trim()
  const mine: Sent[] = []
  let rest = said
  for (const s of sent.values()) {
    if (s.turnId !== undefined) continue
    const body = s.body.trim()
    if (!body) continue
    if (said === body) return { mine: [s], mixed: false }
    if (body.length >= DISTINCT && rest.includes(body)) {
      mine.push(s)
      rest = rest.replace(body, '')
    }
  }
  return { mine, mixed: rest.trim() !== '' }
}

/** Takes back the delivery `nonce`, as far as can still be: the ack's word for how. */
export async function cancel($: EngineInterface, nonce: string, ts: number, now: number) {
  prune(now)
  const s = sent.get(nonce)
  if (!s) {
    // Never submitted here: claimed now, it is refused when it comes; claimed already, an earlier copy took it.
    return (await claim($, nonce, ts, now)) ? 'before-start' : 'unknown'
  }
  if (s.ended) return 'too-late'
  if (s.mixed) return 'together'
  // Not started, or starting (its turn.start hasn't finished): ended as turn.start finishes.
  if (s.turnId === undefined || s.starting) {
    s.cancelled = true
    return 'before-start'
  }
  if (running !== s.turnId) return 'too-late'
  const record = calls.get(s.turnId)
  try {
    await $.turn.abort({ turnId: s.turnId })
  } catch {
    return 'too-late'
  }
  // Only once the abort is taken: the tools it was running, and what they would say afterwards.
  silence(s.turnId, now, record)
  for (const other of sent.values()) if (other.turnId === s.turnId) other.ended = true
  return 'aborted'
}

/** Stops the main turn under way, whoever started it: its tools are answered at once and silenced, then the turn is aborted
 * and a notice left in the session. `turnId` given: only that turn (`not-running` when another runs, or none). */
export async function stopRunning($: EngineInterface, now: number, turnId?: string, notice = 'Stopped from Fjord') {
  if (turnId !== undefined && running !== turnId) return 'not-running'
  const id = running
  if (id === undefined) return 'idle'
  // Kept alive across the abort: the turn may complete while it is awaited, and its tools are still to be cut.
  const record = calls.get(id)
  try {
    await $.turn.abort({ turnId: id })
  } catch {
    return 'not-running'
  }
  silence(id, now, record)
  for (const other of sent.values()) if (other.turnId === id) other.ended = true
  await $.session.append({ message: { type: 'system', content: [{ type: 'text', text: notice }] } }).catch(() => undefined)
  return `stopped ${id}`
}

/** Checks a control message the way a delivery is checked (its signature, its session, its time, its nonce never seen) and
 * acts on it, an abort of a delivery or a stop of the running turn: the ack's text. */
export async function control($: EngineInterface, text: string) {
  const abort = parseAbort(text)
  const stop = abort ? undefined : parseStop(text)
  const signed = abort ?? stop
  if (!signed) return 'refused: unsigned'
  const { keyPath } = await config($)
  if (!keyPath) return 'refused: no key configured'
  const key = (await $.fs.read(keyPath)).trim()
  const expected = await hmac(
    enc.encode(key),
    abort ? abortMacInput(abort.target, abort.nonce, abort.ts, abort.cancels) : stopMacInput(stop!.target, stop!.nonce, stop!.ts, stop!.turn),
  )
  const now = await $.clock.now()
  const ts = Number(signed.ts)
  if (!same(expected, signed.mac)) return 'refused: bad signature'
  if (signed.target !== (await $.session.id())) return 'refused: addressed to another session'
  if (!(Math.abs(now - ts) < WINDOW_MS)) return 'refused: stale'
  if (!(await claim($, signed.nonce, ts, now))) return 'refused: already delivered'
  if (abort) return `ok ${await cancel($, abort.cancels, ts, now)}`
  return `ok ${await stopRunning($, now, stop!.turn === '-' ? undefined : stop!.turn)}`
}

/** A signed message that passed every check, its nonce claimed: what is left is to act on it. */
type Vetted = {
  nonce: string
  body: string
  now: number
  settings?: Settings
  interrupt: boolean
  expectTurn?: string
}
type Refusal = { ok: false; reason: string; nonce?: string; signed?: boolean }

/** Checks a signed text the way every way in must (its signature, its session, its time, its words, its nonce never seen) and
 * claims its nonce. `apply`: it comes from the inbox, where an interrupt may act. `signed` on a refusal: the signature held and
 * the message is this session's (so the refusal may be answered in the inbox folder, not by anyone else's forgery). */
async function vet($: EngineInterface, text: string, apply: boolean): Promise<({ ok: true } & Vetted) | Refusal> {
  const signed = parse(text)
  if (!signed) return { ok: false, reason: 'unsigned' }
  const { keyPath } = await config($)
  if (!keyPath) return { ok: false, reason: 'no key configured' }
  const key = (await $.fs.read(keyPath)).trim()
  const expected = await hmac(enc.encode(key), macInput(signed.target, signed.nonce, signed.ts, signed.body, signed.settings, signed.interrupt, signed.expectTurn))
  const now = await $.clock.now()
  const ts = Number(signed.ts)
  if (!same(expected, signed.mac)) return { ok: false, reason: 'bad signature' }
  if (signed.target !== (await $.session.id())) return { ok: false, reason: 'addressed to another session' }
  const refuse = (reason: string): Refusal => ({ ok: false, reason, nonce: signed.nonce, signed: true })
  if (!(Math.abs(now - ts) < WINDOW_MS)) return refuse('stale')
  // An interrupt acts from the inbox only: never from inside a hook a turn waits on.
  if (signed.interrupt && !apply) return { ok: false, reason: 'an interrupt is taken from the inbox only', nonce: signed.nonce }
  const bad = signed.settings && invalid(signed.settings)
  if (bad) return refuse(bad)
  // A leading byte-order mark is part of what was written: the decoder drops one, so exactly one is put back.
  let decoded: string
  try {
    decoded = new TextDecoder('utf-8', { fatal: true }).decode(signed.body)
  } catch {
    return refuse('not UTF-8')
  }
  const bom = signed.body[0] === 0xef && signed.body[1] === 0xbb && signed.body[2] === 0xbf
  const body = bom ? `\uFEFF${decoded}` : decoded
  // An interrupt's words are checked before anything is stopped: a turn is never aborted for text that can't be submitted.
  const unfit = apply && signed.interrupt ? unsubmittable(body) : undefined
  if (unfit) return refuse(`not submitted: ${unfit}`)
  // An interrupt judged on a turn (v4) acts on that turn only: when another runs, or none, nothing is submitted and the nonce
  // stays unclaimed, so a retry of the same message is refused the same way while that holds. A retry of one that was claimed
  // already (delivered, its ack lost) is told so first: `turn changed` would read as never delivered.
  const expectTurn = apply && signed.interrupt && signed.expectTurn !== undefined && signed.expectTurn !== '-' ? signed.expectTurn : undefined
  if (expectTurn !== undefined && (await claimed($, signed.nonce))) return { ok: false, reason: 'already delivered', nonce: signed.nonce }
  if (expectTurn !== undefined && running !== expectTurn) return refuse('turn changed')
  if (!(await claim($, signed.nonce, ts, now))) return { ok: false, reason: 'already delivered', nonce: signed.nonce }
  return { ok: true, nonce: signed.nonce, body, now, settings: signed.settings, interrupt: signed.interrupt === true, expectTurn }
}

/** Sets the model, then the effort (a model resets it), for this session only, and says what each did. Each can fail on its
 * own; the person's words go either way. */
async function applySettings($: EngineInterface, settings: Settings | undefined) {
  const applied: string[] = []
  if (!settings) return applied
  for (const [command, args] of [['model', settings.model], ['effort', settings.effort]] as const) {
    if (args === undefined) continue
    try {
      await $.command.run({ command, args })
      applied.push(`${command}=${args}`)
    } catch (error) {
      const why = String((error as { message?: unknown })?.message ?? error).replace(/\s+/g, '_').slice(0, 80)
      applied.push(`${command}=error:${why}`)
    }
  }
  return applied
}

/** `entered`: settles, undefined, once the engine took the words in; else why it did not (a hook dropped them, or the submit failed).
 * An interrupt's already has (it is awaited). The ack waits on it, never on the call that started it. */
type Accepted = { ok: true; applied?: string; interrupted?: string; entered: Promise<string | undefined> }

/** Acts on a vetted message: an interrupt stops the turn under way first (the person's words then start the next one at
 * once), then the settings, so the turn the text starts uses them, then the words are submitted as the person's own. From the
 * inbox (`apply`) the settings and the interrupt act; the answer waits for the submit of an interrupt. */
async function perform($: EngineInterface, v: Vetted, apply: boolean): Promise<Accepted | { ok: false; reason: string }> {
  // When the stop fails and the turn still runs, the words would only queue behind it: refused, not delivered.
  let interrupted = apply && v.interrupt ? await stopRunning($, v.now, v.expectTurn, 'Interrupted from Fjord') : undefined
  if (interrupted === 'not-running' && v.expectTurn !== undefined) return { ok: false, reason: 'turn changed' }
  if (interrupted === 'not-running') {
    if (running !== undefined) return { ok: false, reason: 'the running turn could not be stopped' }
    interrupted = 'idle'
  }
  const applied = apply ? await applySettings($, v.settings) : []
  remember(v.nonce, v.body, v.now)
  const sending = submit($, v.nonce, v.body)
  if (apply && v.interrupt) {
    const why = await sending
    if (why !== undefined) return { ok: false, reason: notSubmitted(why) }
  }
  return { ok: true, entered: sending, ...(applied.length ? { applied: applied.join(' ') } : {}), ...(interrupted ? { interrupted } : {}) }
}

/** The ack's word for words the engine did not take in. */
const notSubmitted = (why: string) => `not submitted: ${why.replace(/\s+/g, ' ').slice(0, 80)}`

/** The ack for a delivery that was acted on: "ok" only once the engine took the words in, else a refusal saying why. */
async function receipt(outcome: Accepted | { ok: false; reason: string }, ok: (o: Accepted) => string) {
  if (!outcome.ok) return `refused: ${outcome.reason}`
  const why = await outcome.entered
  return why === undefined ? ok(outcome) : `refused: ${notSubmitted(why)}`
}

/** Checks a signed text the way both ways in must, and submits it as the person's own words. `unsigned` means it isn't
 * Fjord's at all (the peer channel then passes it on); anything else is a refusal with its reason. */
export async function accept($: EngineInterface, text: string, apply = false): Promise<Accepted | Refusal> {
  const v = await vet($, text, apply)
  return v.ok ? perform($, v, apply) : v
}

/** Where the answer for a message goes in this session's inbox folder (the file a message from the inbox is answered in). */
const ackPath = async ($: EngineInterface, nonce: string) => {
  const { inboxDir } = await config($)
  return inboxDir ? `${inboxDir}/${await $.session.id()}/${nonce}.ack` : undefined
}

/** Answers a message that did not come through the inbox, in the inbox folder: Fjord looks there for it. */
async function answer($: EngineInterface, nonce: string, text: string) {
  const path = await ackPath($, nonce).catch(() => undefined)
  if (path) await $.fs.write(path, `${text}\n`).catch(() => undefined)
}

/** Messages whose words wait for the clock's next look: those with settings to set first. `command.run` is refused inside a
 * hook the turn waits on, so the settings are set (and the words submitted) from the look, apart from every hook. */
const later: { v: Vetted; text: string }[] = []
const hasSettings = (s?: Settings) => s !== undefined && (s.model !== undefined || s.effort !== undefined)

/** Submits what a hook set aside, in order, and answers in the inbox folder. */
function release($: EngineInterface) {
  for (const { v, text } of later.splice(0)) {
    deliveries = deliveries.then(async () => {
      const outcome = await perform($, { ...v, body: text }, true).catch((error) => ({ ok: false as const, reason: String(error?.message ?? error) }))
      // The next one is submitted without waiting for this one's words to be taken in: the answer follows them.
      void receipt(outcome, (o) => `ok${acked(o)}`).then((reply) => answer($, v.nonce, reply))
    })
  }
}

/** What the app hands a running session: Fjord's signed message in its envelope. A valid one is taken off the channel and its
 * words are submitted as the person's own apart from this hook (a turn waits on it), the settings first, from the next look. */
async function received($: EngineInterface, text: string): Promise<boolean> {
  const v = await vet($, unwrap(text).body, false)
  if (!v.ok) {
    if (v.signed && v.nonce) await answer($, v.nonce, `refused: ${v.reason}`)
    return false
  }
  if (hasSettings(v.settings)) {
    later.push({ v, text: v.body })
    return true
  }
  void (async () => {
    const outcome = await perform($, v, false).catch((error) => ({ ok: false as const, reason: String(error?.message ?? error) }))
    await answer($, v.nonce, await receipt(outcome, () => 'ok'))
  })()
  return true
}

/** The first prompt of a session the app started with Fjord's message (its guidance, then the envelope): rewritten to the
 * person's words alone, the guidance as context. Undefined: not Fjord's, or refused: it goes on untouched as the peer
 * message it is. A slash command is dropped (it would run as one). A message with settings can't set them inside this hook:
 * the prompt is dropped (no turn) and its words submitted from the next look, once they are set, with the app's guidance
 * ahead of them in the text (a plugin's submit can't pass context). */
async function started($: EngineInterface, e: { text: string; context?: readonly string[] }) {
  const u = unwrap(e.text)
  if (!u.wrapped || !parse(u.body)) return undefined
  const v = await vet($, u.body, false)
  if (!v.ok) {
    if (v.signed && v.nonce) await answer($, v.nonce, `refused: ${v.reason}`)
    return undefined
  }
  const unfit = unsubmittable(v.body)
  if (unfit) {
    await answer($, v.nonce, `refused: not submitted: ${unfit}`)
    return { drop: `Fjord: ${unfit}` }
  }
  if (hasSettings(v.settings)) {
    later.push({ v, text: u.before ? `${u.before}\n${v.body}` : v.body })
    return { drop: 'Fjord: its model and effort are set first; the message follows' }
  }
  remember(v.nonce, v.body, v.now)
  return { text: v.body, context: u.before ? [u.before, ...(e.context ?? [])] : e.context, nonce: v.nonce }
}

/** What a tool result says, as one short line. */
const said = (result: { content?: readonly { type?: string; text?: string }[] }) =>
  (result.content ?? []).filter((c) => c.type === 'text').map((c) => c.text ?? '').join(' ').replace(/\s+/g, ' ').trim().slice(0, 300)

/** Checks a carry order the way a delivery is checked (its signature, its session, its time, its nonce never seen), then hands
 * the signed message it carries to the app's own send tool, with no model turn: the ack's text. `taken` is told the nonce as
 * the call starts (the app answers only once the message is delivered, which can take a cold start). */
export async function carry($: EngineInterface, text: string, taken: (nonce: string) => Promise<unknown> = async () => {}) {
  const order = parseCarry(text)
  if (!order) return 'refused: unsigned'
  const { keyPath } = await config($)
  if (!keyPath) return 'refused: no key configured'
  const key = (await $.fs.read(keyPath)).trim()
  const expected = await hmac(enc.encode(key), carryMacInput(order.carrier, order.nonce, order.ts, order.local, order.bytes))
  const now = await $.clock.now()
  const ts = Number(order.ts)
  if (!same(expected, order.mac)) return 'refused: bad signature'
  const own = await $.session.id()
  if (order.carrier !== own) return 'refused: addressed to another session'
  if (!(Math.abs(now - ts) < WINDOW_MS)) return 'refused: stale'
  // What is carried is a message of Fjord's, signed for another session: never this one's own.
  const inner = parse(order.message)
  if (!inner) return 'refused: not a signed message'
  if (inner.target === own) return 'refused: a session does not carry to itself'
  if (!(await claim($, order.nonce, ts, now))) return 'refused: already delivered'
  await taken(order.nonce)
  try {
    const result = await $.mcp.call('ccd_session_mgmt', 'send_message', { session_id: order.local, message: order.message })
    return result.isError ? `refused: ${said(result)}` : `ok ${said(result)}`.trimEnd()
  } catch (error) {
    return `refused: ${String((error as { message?: unknown })?.message ?? error).replace(/\s+/g, ' ').slice(0, 300)}`
  }
}

/** When the look in progress began (0: none). A look that hangs is given up on after `POLL_STUCK_MS`, so one stuck call can't
 * silence the inbox for good; two looks at once never happen otherwise (each message gets exactly one ack). */
let pollingSince = 0
const POLL_STUCK_MS = 5000
/** The inbox files being delivered (not yet acked), and the deliveries' order. */
const inFlight = new Set<string>()
let deliveries: Promise<void> = Promise.resolve()

/** What follows "ok" in a delivery's ack: how an interrupt went ("interrupted <turn id>", or "idle" when nothing ran), then what
 * the settings did. */
const acked = (o: { applied?: string; interrupted?: string }) => {
  const how = o.interrupted?.startsWith('stopped ') ? `interrupted ${o.interrupted.slice(8)}` : o.interrupted
  const parts = [how, o.applied].filter((x) => x !== undefined)
  return parts.length ? ` ${parts.join(' ')}` : ''
}

/** One look at this session's inbox: every message without an ack is checked, submitted or refused, and answered. */
export async function poll($: EngineInterface) {
  const began = await $.clock.now()
  if (pollingSince && Math.abs(began - pollingSince) < POLL_STUCK_MS) return
  pollingSince = began
  try {
    release($)
    const { inboxDir } = await config($)
    if (!inboxDir) return
    const dir = `${inboxDir}/${await $.session.id()}`
    const names = new Set((await $.fs.list(dir)).map((entry) => entry.name))
    for (const name of [...names].sort()) {
      if (!name.endsWith('.msg') || names.has(`${name.slice(0, -4)}.ack`)) continue
      const text = await $.fs.read(`${dir}/${name}`).catch(() => undefined)
      if (text === undefined) continue
      if (CARRY.test(text)) {
        // A carry waits for the app to deliver (a cold start takes a while): apart from the look and from the deliveries.
        if (inFlight.has(name)) continue
        inFlight.add(name)
        const base = name.slice(0, -4)
        void (async () => {
          try {
            const reply = await carry($, text, (nonce) => $.fs.write(`${dir}/${nonce}.taken`, 'taken\n')).catch((error) => `refused: ${String(error?.message ?? error)}`)
            await $.fs.write(`${dir}/${base}.ack`, `${reply}\n`)
          } catch {
            // The ack couldn't be written: the next look takes the order again (its nonce is claimed, so it is refused as a replay).
          } finally {
            inFlight.delete(name)
          }
        })()
        continue
      }
      if (parseAbort(text) || parseStop(text)) {
        const reply = await control($, text).catch((error) => `refused: ${String(error?.message ?? error)}`)
        await $.fs.write(`${dir}/${name.slice(0, -4)}.ack`, `${reply}\n`)
        continue
      }
      // A delivery can take long (an interrupt waits for its words to be accepted): it runs apart from the look, one after
      // another so the words keep their order, and its message is skipped by every look until its own ack is written.
      if (inFlight.has(name)) continue
      inFlight.add(name)
      const deliver = async () => {
        let outcome: Accepted | { ok: false; reason: string }
        try {
          outcome = await accept($, text, true).catch((error) => ({ ok: false as const, reason: String(error?.message ?? error) }))
        } catch {
          inFlight.delete(name)
          return
        }
        // The next delivery is submitted without waiting for this one's words to be taken in; the ack follows them.
        void (async () => {
          try {
            await $.fs.write(`${dir}/${name.slice(0, -4)}.ack`, `${await receipt(outcome, (o) => `ok${acked(o)}`)}\n`)
          } catch {
            // The ack couldn't be written: the next look takes the message again (its nonce is claimed, so it is refused as a replay).
          } finally {
            inFlight.delete(name)
          }
        })()
      }
      deliveries = deliveries.then(deliver)
    }
  } catch {
    // No folder yet (nothing was ever sent here), or it can't be read: nothing to do until the next look.
  } finally {
    if (pollingSince === began) pollingSince = 0
  }
}

let timer: { cancel: () => void } | undefined

export const register: Register = (on) => {
  on('session.receive', async ($, e, next) => {
    if (!(await received($, e.text))) return next(e)
    return { consumed: 'relayed by Fjord as the person’s own message' }
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    await mark($).catch(() => undefined)
    // The registry may not list the process yet, and a /clear changes the session's id: looked at again now and then.
    $.clock.every(10_000, () => {
      void mark($).catch(() => undefined)
    })
    timer?.cancel()
    timer = $.clock.every(POLL_MS, () => void poll($))
    return next(e)
  })
  on('turn.start', async ($, e, next) => {
    running = e.turnId
    const now = await $.clock.now()
    runningSince = now
    const { mine, mixed } = startedBy(e.text, now)
    for (const s of mine) Object.assign(s, { turnId: e.turnId, mixed, starting: true })
    calls.set(e.turnId, { cuts: new Set(), ids: new Set(), agents: new Set() })
    try {
      await mark($).catch(() => undefined)
      return await next(e)
    } finally {
      for (const s of mine) s.starting = false
      // Taken back while it waited its turn (or as it started), and wholly Fjord's: it ends as it begins.
      // One that holds words of the person's own isn't stopped.
      if (!mixed && mine.some((s) => s.cancelled)) {
        for (const s of mine) s.ended = true
        await $.turn.abort({ turnId: e.turnId }).catch(() => undefined)
        silence(e.turnId, now)
      }
    }
  })
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      for (const s of sent.values()) if (s.turnId === e.turnId) s.ended = true
      const ended = running === e.turnId
      if (ended) running = undefined
      calls.delete(e.turnId)
      if (ended) await mark($).catch(() => undefined)
    }
    return next(e)
  })
  // The subagents a turn spawns are its own: their tool calls are cut with it.
  // Whose it is goes by its parent: the main loop's spawn belongs to the turn running, a subagent's to that subagent's turn.
  on('agent.spawn', async ($, e, next) => {
    const parent = (e as { parentAgentId?: unknown }).parentAgentId
    const owner = typeof parent === 'string' ? owners.get(parent) : running
    const spawned = await next(e)
    const id = (spawned as { agentId?: unknown })?.agentId
    if (owner !== undefined && typeof id === 'string') {
      owners.set(id, owner)
      while (owners.size > OWNERS_KEPT) owners.delete(owners.keys().next().value as string)
      calls.get(owner)?.agents.add(id)
    }
    return spawned
  }).catch(($, e, next) => next(e))
  // A tool call of a main turn (on the main loop, or in a subagent it spawned) can be cut short by a cancel or a stop:
  // answered before what runs beneath is done. Any other call (a background agent of an earlier turn's) passes straight
  // through.
  on('tool.call', async ($, e, next) => {
    const turn = running === undefined ? undefined : calls.get(running)
    if (!turn || (e.agentId !== undefined && !turn.agents.has(e.agentId))) return next(e)
    if (e.tool_use_id) turn.ids.add(e.tool_use_id)
    let cut = () => {}
    const stopped = new Promise<'cut'>((resolve) => {
      cut = () => resolve('cut')
    })
    turn.cuts.add(cut)
    try {
      const done = await Promise.race([next(e), stopped])
      return done === 'cut' ? { deny: 'Stopped: the person stopped this from Fjord.' } : done
    } finally {
      turn.cuts.delete(cut)
    }
  }).catch(($, e, next) => next(e))
  // The first prompt of a session the app started with Fjord's message: rewritten to the person's words, the app's guidance as
  // context. A notification only of tasks of a turn taken back is dropped; one that tells of others too goes as it is.
  on('prompt.submit', async ($, e, next) => {
    const cold = await started($, e).catch(() => undefined)
    if (cold) {
      if ('drop' in cold) return cold
      // The answer says it went only once the hooks beneath and the engine took the words in: a prompt dropped there, or a
      // failure, is a refusal, and its words are forgotten (else a later turn of the person's own could be taken for it).
      const { nonce } = cold
      let result: Awaited<ReturnType<typeof next>>
      try {
        result = await next({ ...e, text: cold.text, ...(cold.context ? { context: cold.context } : {}) })
      } catch (error) {
        sent.delete(nonce)
        await answer($, nonce, `refused: ${notSubmitted(String((error as { message?: unknown })?.message ?? error))}`)
        throw error
      }
      const dropped = result && typeof result === 'object' && 'drop' in result && (result as { drop?: unknown }).drop !== undefined
      if (dropped) sent.delete(nonce)
      await answer($, nonce, dropped ? `refused: ${notSubmitted(String((result as { drop: unknown }).drop))}` : 'ok')
      return result
    }
    if (e.origin.kind === 'task-notification' && quiet.size) {
      const ids = [...e.text.matchAll(/<tool-use-id>([^<\s]+)<\/tool-use-id>/g)].map((m) => m[1])
      if (ids.length && ids.every((id) => quiet.has(id))) {
        return { drop: 'A task of a message cancelled from Fjord ended: not taken up again.' }
      }
    }
    return next(e)
  })
  on('session.end', async ($, e, next) => {
    await unmark($).catch(() => undefined)
    return next(e)
  })
}
