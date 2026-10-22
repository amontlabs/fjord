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
// Two ways in, one check. The peer channel (`session.receive`) is the original way and stays as the fallback for a
// Fjord that can't reach this plugin directly. The inbox is the direct way, with no model in between:
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
// `wake-v1`: Fjord starts a sleeping session through its relay (a session of Fjord's own in the Claude app, named by
// `relay` in config.json), the one session the app lets call SendMessage to a session with no process. The relay sends the
// session this text, which the app delivers as the cold-started session's first prompt, inside the app's own envelope:
//   fjord-wake <target cli session id> <nonce> <ms since 1970> <hex HMAC-SHA256>
// with the MAC over "wake-v1\n<target>\n<nonce>\n<ms>\n" (ASCII and hex only, so the envelope's escaping can't change it).
// In the target, `prompt.submit` drops a prompt that holds a valid wake for this session (signature, fresh, nonce never
// seen, claimed as a delivery's is): no turn runs, the process stays up and this plugin shows its presence. Any other
// prompt passes untouched. In the relay, `tool.call` lets SendMessage through only to a `local_` session and only with a
// validly signed, fresh wake as its message, and denies every other SendMessage.
//
// Fjord writes this file; edits are overwritten.

const HEADER = /(?:^|\n)⟦fjord (?:v1 (\S+) (\S+) (\d+)|v2 (\S+) (\S+) (\d+) (\S+) (\S+)|v3 (\S+) (\S+) (\d+) (\S+) (\S+) ([01])|v4 (\S+) (\S+) (\d+) (\S+) (\S+) ([01]) (\S+)) ([0-9a-f]{64})⟧\n/
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/
const CLOSE = '</cross-session-message>'
const WINDOW_MS = 10 * 60 * 1000
const NONCE = 'nonce.'
export const CAPABILITIES = ['inbox-v1', 'settings-v1', 'abort-v1', 'stop-v1', 'interrupt-v1', 'interrupt-turn-v1']
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

const WAKE = /^fjord-wake (\S+) ([0-9a-f-]{8,64}) (\d{1,16}) ([0-9a-f]{64})$/

/** What a wake's MAC covers: its kind, the target (a CLI session id), its nonce and its time, one per line. */
export const wakeMacInput = (target: string, nonce: string, ts: string) => enc.encode(`wake-v1\n${target}\n${nonce}\n${ts}\n`)

/** A wake's fields from its own text; undefined for anything else. */
export const parseWake = (text: string) => {
  const m = WAKE.exec(text.trim())
  return m ? { target: m[1], nonce: m[2], ts: m[3], mac: m[4] } : undefined
}

/** The wake a prompt holds: the body of the app's cross-session envelope (the app's own system-reminder may come before it),
 * which must be a wake and nothing else; undefined for any other prompt. */
export const wakeInPrompt = (text: string) => {
  const m = /<cross-session-message\b[^>]*>\n?([^<]*?)\n?<\/cross-session-message>/.exec(text)
  return m ? parseWake(m[1]) : undefined
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

/** The signed message in a delivery: its header's fields and the body's bytes (the peer envelope's close left out). */
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
  let rest = text.slice(m.index + header.length)
  const close = rest.indexOf(CLOSE)
  if (close >= 0) rest = rest.slice(0, close)
  const body = fromBase64(rest.trim())
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
type Config = { keyPath?: string; presenceDir?: string; sessionsDir?: string; inboxDir?: string; relay?: string }

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

/** Whether a wake is signed by Fjord's key and fresh (nothing is claimed). */
async function wakeSigned($: EngineInterface, wake: NonNullable<ReturnType<typeof parseWake>>) {
  const { keyPath } = await config($)
  if (!keyPath) return false
  const key = (await $.fs.read(keyPath)).trim()
  if (!key) return false
  const expected = await hmac(enc.encode(key), wakeMacInput(wake.target, wake.nonce, wake.ts))
  return same(expected, wake.mac) && Math.abs((await $.clock.now()) - Number(wake.ts)) < WINDOW_MS
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
  deliveries = Promise.resolve()
  titled = false
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

/** Checks a signed text the way both ways in must, and submits it as the person's own words. `unsigned` means it isn't
 * Fjord's at all (the peer channel then passes it on); anything else is a refusal with its reason. */
export async function accept(
  $: EngineInterface,
  text: string,
  apply = false,
): Promise<{ ok: true; applied?: string; interrupted?: string } | { ok: false; reason: string }> {
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
  if (!(Math.abs(now - ts) < WINDOW_MS)) return { ok: false, reason: 'stale' }
  // An interrupt acts from the inbox only: never from inside a hook a turn waits on.
  if (signed.interrupt && !apply) return { ok: false, reason: 'an interrupt is taken from the inbox only' }
  const bad = signed.settings && invalid(signed.settings)
  if (bad) return { ok: false, reason: bad }
  // A leading byte-order mark is part of what was written: the decoder drops one, so exactly one is put back.
  let decoded: string
  try {
    decoded = new TextDecoder('utf-8', { fatal: true }).decode(signed.body)
  } catch {
    return { ok: false, reason: 'not UTF-8' }
  }
  const bom = signed.body[0] === 0xef && signed.body[1] === 0xbb && signed.body[2] === 0xbf
  const body = bom ? `\uFEFF${decoded}` : decoded
  // An interrupt's words are checked before anything is stopped: a turn is never aborted for text that can't be submitted.
  const unfit = apply && signed.interrupt ? unsubmittable(body) : undefined
  if (unfit) return { ok: false, reason: `not submitted: ${unfit}` }
  // An interrupt judged on a turn (v4) acts on that turn only: when another runs, or none, nothing is submitted and the nonce
  // stays unclaimed, so a retry of the same message is refused the same way while that holds. A retry of one that was claimed
  // already (delivered, its ack lost) is told so first: `turn changed` would read as never delivered.
  const expectTurn = apply && signed.interrupt && signed.expectTurn !== undefined && signed.expectTurn !== '-' ? signed.expectTurn : undefined
  if (expectTurn !== undefined && (await claimed($, signed.nonce))) return { ok: false, reason: 'already delivered' }
  if (expectTurn !== undefined && running !== expectTurn) return { ok: false, reason: 'turn changed' }
  if (!(await claim($, signed.nonce, ts, now))) return { ok: false, reason: 'already delivered' }
  // An interrupt stops the turn under way first (the person's words then start the next one at once). When the stop fails
  // and the turn still runs, the words would only queue behind it: refused, not delivered.
  let interrupted = apply && signed.interrupt ? await stopRunning($, now, expectTurn, 'Interrupted from Fjord') : undefined
  if (interrupted === 'not-running' && expectTurn !== undefined) return { ok: false, reason: 'turn changed' }
  if (interrupted === 'not-running') {
    if (running !== undefined) return { ok: false, reason: 'the running turn could not be stopped' }
    interrupted = 'idle'
  }
  // The settings first, so the turn the text starts uses them: the model, then the effort (a model resets it). Each can fail
  // on its own; the person's words go either way. Only from the inbox (`apply`): never from inside a hook a turn waits on.
  const applied: string[] = []
  if (apply && signed.settings) {
    for (const [command, args] of [['model', signed.settings.model], ['effort', signed.settings.effort]] as const) {
      if (args === undefined) continue
      try {
        await $.command.run({ command, args })
        applied.push(`${command}=${args}`)
      } catch (error) {
        const why = String((error as { message?: unknown })?.message ?? error).replace(/\s+/g, '_').slice(0, 80)
        applied.push(`${command}=error:${why}`)
      }
    }
  }
  remember(signed.nonce, body, now)
  const sending = submit($, signed.nonce, body)
  if (apply && signed.interrupt) {
    const why = await sending
    if (why !== undefined) return { ok: false, reason: `not submitted: ${why.replace(/\s+/g, ' ').slice(0, 80)}` }
  } else void sending
  return { ok: true, ...(applied.length ? { applied: applied.join(' ') } : {}), ...(interrupted ? { interrupted } : {}) }
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
    const { inboxDir } = await config($)
    if (!inboxDir) return
    const dir = `${inboxDir}/${await $.session.id()}`
    const names = new Set((await $.fs.list(dir)).map((entry) => entry.name))
    for (const name of [...names].sort()) {
      if (!name.endsWith('.msg') || names.has(`${name.slice(0, -4)}.ack`)) continue
      const text = await $.fs.read(`${dir}/${name}`).catch(() => undefined)
      if (text === undefined) continue
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
        try {
          const outcome = await accept($, text, true).catch((error) => ({ ok: false as const, reason: String(error?.message ?? error) }))
          await $.fs.write(`${dir}/${name.slice(0, -4)}.ack`, outcome.ok ? `ok${acked(outcome)}\n` : `refused: ${outcome.reason}\n`)
        } catch {
          // The ack couldn't be written: the next look takes the message again (its nonce is claimed, so it is refused as a replay).
        } finally {
          inFlight.delete(name)
        }
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

/** Whether this process has named the relay session already (its title can't be read, so it is set once per process). */
let titled = false

/** In Fjord's relay session, renames it "Fjord", so the sessions it wakes show "From Fjord". Fjord names the relay in the
 * config when it finds the session (after this starts, perhaps), so it is tried again until it is named; a rename that fails
 * is left alone (a wake works under any title). */
async function title($: EngineInterface) {
  if (titled) return
  const relay = await config($).then((c) => c.relay, () => undefined)
  if (!relay || relay !== (await $.session.id().catch(() => undefined))) return
  titled = true
  await $.command.run({ command: 'rename', args: 'Fjord' }).catch(() => undefined)
}

export const register: Register = (on) => {
  on('session.receive', async ($, e, next) => {
    const outcome = await accept($, e.text)
    if (!outcome.ok) return next(e)
    return { consumed: 'relayed by Fjord as the person’s own message' }
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    await mark($).catch(() => undefined)
    // The registry may not list the process yet, and a /clear changes the session's id: looked at again now and then.
    $.clock.every(10_000, () => {
      void mark($).catch(() => undefined)
      void title($)
    })
    void title($)
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
  // In Fjord's relay session, SendMessage carries a wake and nothing else, to a session of the app.
  on('tool.call', { tool: 'SendMessage' }, async ($, e, next) => {
    const relay = await config($).then((c) => c.relay, () => undefined)
    if (!relay || relay !== (await $.session.id())) return next(e)
    const call = e as { to?: unknown; message?: unknown }
    const wake = typeof call.message === 'string' ? parseWake(call.message) : undefined
    const to = typeof call.to === 'string' ? call.to : ''
    const fit = !!wake && wake.target !== relay && /^local_[A-Za-z0-9_-]+$/.test(to) && (await wakeSigned($, wake!).catch(() => false))
    return fit ? next(e) : { deny: 'Fjord’s relay only sends the signed wake it is given, to the session it names.' }
  })
  // A wake for this session, the first prompt of a session the app started for Fjord, is dropped: no turn runs.
  // A notification only of tasks of a turn taken back is dropped; one that tells of others too goes as it is.
  on('prompt.submit', async ($, e, next) => {
    const wake = wakeInPrompt(e.text)
    if (wake && wake.target === (await $.session.id()) && (await wakeSigned($, wake))) {
      if (await claim($, wake.nonce, Number(wake.ts), await $.clock.now())) {
        return { drop: 'Fjord woke this session: nothing to answer.' }
      }
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
