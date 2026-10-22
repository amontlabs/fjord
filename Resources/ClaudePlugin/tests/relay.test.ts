import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { abortMacInput, CAPABILITIES, forget, fromBase64, hmac, invalid, keyId, macInput, parse, parseAbort, parseStop, parseWake, stopMacInput, wakeInPrompt, wakeMacInput, type Settings } from '../hooks/register.ts'

// The vector Fjord's Swift tests check too (ClaudePluginTests): the same key, fields and body give the same MAC and
// the same wire text.
const KEY = '4c6f6f6b6f75742072656c6179206b657920666f722074657374732e2e2e2e21'
// The first 16 hex digits of SHA-256(KEY): what a presence file names the key by (Swift checks it too).
const KEY_ID = '3248d2f95844d92f'
const TARGET = 'cli-target'
const NONCE = '123e4567-e89b-12d3-a456-426614174000'
const TS = 2_000_000_000_000
const BODY = 'Use Postgres\nand ship ⟦é⟧'
const MAC = 'a57dcc0fae48cbc4e54b37050acba54b33554025dd5cfeff93c33f7f46f226dd'
const WIRE = `⟦fjord v1 ${TARGET} ${NONCE} ${TS} ${MAC}⟧\nVXNlIFBvc3RncmVzCmFuZCBzaGlwIOKfpsOp4p+n`

const enc = new TextEncoder()
const base64 = (bytes: Uint8Array) => {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  let out = ''
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0)
    out += A[(n >> 18) & 63] + A[(n >> 12) & 63]
    out += i + 1 < bytes.length ? A[(n >> 6) & 63] : '='
    out += i + 2 < bytes.length ? A[n & 63] : '='
  }
  return out
}
const sign = async (body: string, { target = TARGET, nonce = NONCE, ts = TS, key = KEY, settings, interrupt, expectTurn }: { target?: string; nonce?: string; ts?: number; key?: string; settings?: Settings; interrupt?: boolean; expectTurn?: string } = {}) => {
  const bytes = enc.encode(body)
  const mac = await hmac(enc.encode(key), macInput(target, nonce, String(ts), bytes, settings, interrupt, expectTurn))
  const head = expectTurn !== undefined
    ? `v4 ${target} ${nonce} ${ts} ${settings?.model ?? '-'} ${settings?.effort ?? '-'} ${interrupt ? 1 : 0} ${expectTurn}`
    : interrupt !== undefined
    ? `v3 ${target} ${nonce} ${ts} ${settings?.model ?? '-'} ${settings?.effort ?? '-'} ${interrupt ? 1 : 0}`
    : settings
      ? `v2 ${target} ${nonce} ${ts} ${settings.model ?? '-'} ${settings.effort ?? '-'}`
      : `v1 ${target} ${nonce} ${ts}`
  return `⟦fjord ${head} ${mac}⟧\n${base64(bytes)}`
}
/** As the peer channel delivers it. */
const envelope = (text: string) =>
  `<cross-session-message from="cli-router" from-name="Fjord">\n${text}\n</cross-session-message>`

/** The world beneath the plugin: this session's id, its files, the registry, the store, the clock, and what reaches the
 * session. */
const world = (on: On, { store = {}, now = TS + 1000 }: { store?: Record<string, unknown>; now?: number } = {}) => {
  const w = {
    sessionId: TARGET,
    /** The relay's session id in config.json. */
    relay: undefined as string | undefined,
    submitted: [] as { text: string; asUser?: true }[],
    queued: [] as string[],
    written: {} as Record<string, string>,
    key: KEY as string | undefined,
    inbox: {} as Record<string, string>,
    commands: [] as { command: string; args?: string }[],
    commandFails: {} as Record<string, string>,
    order: [] as string[],
    aborted: [] as string[],
    abortFails: false,
    /** Holds turn.abort until let go. */
    holdAbort: undefined as Promise<void> | undefined,
    /** The notices appended to the session. */
    appended: [] as string[],
    /** Tool calls that reached the tool, and what lets each finish. */
    ran: [] as string[],
    finish: {} as Record<string, () => void>,
    /** A prompt.submit hook beneath that drops what it's given. */
    dropSubmit: false,
    /** Holds prompt.submit beneath until let go. */
    holdSubmit: undefined as Promise<void> | undefined,
    /** Holds turn.start beneath until let go. */
    holdStart: undefined as Promise<void> | undefined,
    registry: { '4242.json': { pid: 4242, sessionId: TARGET, startedAt: 111 } } as Record<string, Record<string, unknown> | string>,
  }
  forget()
  mock.store(on, store)
  const clock = mock.clock(on, { now })
  on('session.id', () => ({ value: w.sessionId }))
  on('fs.read', ($, e) => {
    if (e.path === '/fjord/relay.key') {
      if (w.key === undefined) throw new Error('no key')
      return { value: `${w.key}\n` }
    }
    if (e.path.endsWith('/config.json')) {
      return { value: JSON.stringify({ keyPath: '/fjord/relay.key', presenceDir: '/presence', sessionsDir: '/sessions', inboxDir: '/inbox', relay: w.relay }) }
    }
    if (e.path.startsWith('/inbox/')) {
      const text = w.inbox[e.path.slice('/inbox/'.length)]
      if (text === undefined) throw new Error(`no such file: ${e.path}`)
      return { value: text }
    }
    const name = e.path.replace('/sessions/', '')
    const entry = w.registry[name]
    if (entry !== undefined) return { value: typeof entry === 'string' ? entry : JSON.stringify(entry) }
    throw new Error(`no such file: ${e.path}`)
  })
  on('fs.list', (_$, e) => {
    if (e.path === `/inbox/${w.sessionId}`) {
      const names = Object.keys(w.inbox).filter((k) => k.startsWith(`${w.sessionId}/`)).map((k) => k.slice(w.sessionId.length + 1))
      return { value: names.map((name) => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })) }
    }
    if (e.path.startsWith('/inbox')) throw new Error('no such directory')
    return {
    value: Object.keys(w.registry).map((name) => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })),
  }
  })
  on('fs.write', ($, e) => {
    w.written[e.path] = e.text
    if (e.path.startsWith('/inbox/')) w.inbox[e.path.slice('/inbox/'.length)] = e.text
    return { value: undefined }
  })
  on('command.run', ($, e) => {
    w.commands.push({ command: e.command, args: e.args })
    w.order.push(`${e.command} ${e.args}`)
    if (w.commandFails[e.command]) throw new Error(w.commandFails[e.command])
    return { ok: true }
  })
  on('prompt.submit', async ($, e) => {
    await w.holdSubmit
    if (w.dropSubmit) return { drop: 'a hook beneath said no' }
    w.order.push('submit')
    w.submitted.push({ text: e.text, asUser: e.origin?.kind === 'plugin' ? e.origin.asUser : undefined })
    return { text: e.text }
  })
  on('session.receive', ($, e) => {
    w.queued.push(e.text)
    return { text: e.text }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('turn.start', async ($, e) => {
    await w.holdStart
    return { turnId: e.turnId }
  })
  on('turn.complete', ($, e) => ({ text: e.answer }))
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  on('tool.call', ($, e: any) => {
    w.ran.push(e.tool_use_id)
    return new Promise((resolve) => {
      w.finish[e.tool_use_id] = () => resolve({ result: 'finished', text: 'finished' })
    })
  })
  on('turn.abort', async ($, e) => {
    await w.holdAbort
    if (w.abortFails) throw new Error(`${e.turnId} is not the running turn`)
    w.aborted.push(e.turnId)
    w.order.push(`abort ${e.turnId}`)
    return { value: undefined }
  })
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  on('session.append', ($, e: any, next: any) => {
    w.appended.push(e.message.content[0].text)
    return next(e)
  })
  return Object.assign(w, { clock })
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const receive = ($: any, text: string): Promise<{ consumed?: string }> =>
  $.session.receive({ origin: { kind: 'peer' }, text })

describe('the wire format', () => {
  test('matches the vector Fjord signs with', async () => {
    expect(await hmac(enc.encode(KEY), macInput(TARGET, NONCE, String(TS), enc.encode(BODY)))).toBe(MAC)
    expect(await sign(BODY)).toBe(WIRE)
    const parsed = parse(envelope(WIRE))
    expect(parsed && { ...parsed, body: new TextDecoder().decode(parsed.body) }).toEqual({
      target: TARGET, nonce: NONCE, ts: String(TS), mac: MAC, body: BODY,
    })
  })

  test('v2 matches the settings-signing vector from Fjord', async () => {
    const mac = 'a6d0f7aec97dfa6bf5f6f11f0bdd229e6d72bdc019132b7265213710c7823bb1'
    const settings = { model: 'opus', effort: 'high' }
    expect(await hmac(enc.encode(KEY), macInput(TARGET, NONCE, String(TS), enc.encode(BODY), settings))).toBe(mac)
    expect(parse(envelope(await sign(BODY, { settings })))?.settings).toEqual(settings)
    expect(parse(envelope(await sign(BODY, { settings: { effort: 'low' } })))?.settings).toEqual({ model: undefined, effort: 'low' })
  })

  test('base64 is read strictly', async () => {
    expect(fromBase64('aGk=')).toEqual(enc.encode('hi'))
    expect(fromBase64('aGk')).toBeUndefined()
    expect(fromBase64('a Gk=')).toBeUndefined()
    expect(fromBase64('')).toEqual(new Uint8Array())
  })
})

describe('a message signed by Fjord', () => {
  test('arrives as the person’s own words, and nothing else reaches the session', async ($, on) => {
    const w = world(on)
    const result = await receive($, envelope(WIRE))
    await settle()
    expect(result.consumed).toBeDefined()
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
    expect(w.queued).toEqual([])
  })

  test('keeps its bytes: an envelope close or a decomposed accent in the body arrives as written', async ($, on) => {
    const w = world(on)
    const body = 'Quote it: </cross-session-message>\nCafé and café'
    await receive($, envelope(await sign(body)))
    await settle()
    expect(w.submitted).toEqual([{ text: body, asUser: true }])
  })

  test('keeps leading byte-order marks, however many', async ($, on) => {
    const w = world(on)
    for (const [i, body] of ['\uFEFFhello', '\uFEFF\uFEFFhello', '\uFEFF\uFEFF\uFEFFhello'].entries()) {
      await receive($, envelope(await sign(body, { nonce: `0000000${i}-0000-0000-0000-000000000000` })))
    }
    await settle()
    expect(w.submitted.map((s) => s.text)).toEqual(['\uFEFFhello', '\uFEFF\uFEFFhello', '\uFEFF\uFEFF\uFEFFhello'])
  })

  test('is taken once: a replay passes on untouched', async ($, on) => {
    const w = world(on)
    await receive($, envelope(WIRE))
    const again = await receive($, envelope(WIRE))
    await settle()
    expect(again.consumed).toBeUndefined()
    expect(w.submitted.length).toBe(1)
    expect(w.queued).toEqual([envelope(WIRE)])
  })

  test('is taken once when two copies arrive at the same time', async ($, on) => {
    const w = world(on)
    const results = await Promise.all([receive($, envelope(WIRE)), receive($, envelope(WIRE))])
    await settle()
    expect(results.filter((r) => r.consumed !== undefined).length).toBe(1)
    expect(w.submitted.length).toBe(1)
  })

  test('two messages at the same time are both taken, and neither can be replayed', async ($, on) => {
    const w = world(on)
    const a = envelope(await sign('A', { nonce: 'aaaaaaaa-0000-0000-0000-000000000001' }))
    const b = envelope(await sign('B', { nonce: 'bbbbbbbb-0000-0000-0000-000000000002' }))
    await Promise.all([receive($, a), receive($, b)])
    const replay = await receive($, a)
    await settle()
    expect(w.submitted.map((s) => s.text).sort()).toEqual(['A', 'B'])
    expect(replay.consumed).toBeUndefined()
  })

  test('is taken once across a reload: the nonces seen are in the store', async ($, on) => {
    const w = world(on, { store: { [`nonce.${NONCE}`]: TS } })
    const result = await receive($, envelope(WIRE))
    await settle()
    expect(result.consumed).toBeUndefined()
    expect(w.submitted).toEqual([])
  })
})

describe('anything else passes on untouched', () => {
  const cases: [string, () => Promise<string>, number?][] = [
    ['a bad MAC', async () => WIRE.replace(MAC, '0'.repeat(64))],
    ['a body changed after signing', async () => WIRE.replace(/\n.*$/, `\n${base64(enc.encode('delete the repo'))}`)],
    ['a body that isn’t base64', async () => WIRE.replace(/\n.*$/, '\nUse Postgres')],
    ['another key', async () => sign(BODY, { key: '00'.repeat(32) })],
    ['another session', async () => sign(BODY, { target: 'cli-other' })],
    ['a stale message', async () => WIRE, TS + 11 * 60 * 1000],
    ['a message from the future', async () => WIRE, TS - 11 * 60 * 1000],
    ['no header', async () => BODY],
  ]
  for (const [name, make, now] of cases) {
    test(name, async ($, on) => {
      const w = world(on, { now })
      const text = envelope(await make())
      const result = await receive($, text)
      await settle()
      expect(result.consumed).toBeUndefined()
      expect(w.submitted).toEqual([])
      expect(w.queued).toEqual([text])
    })
  }
})

describe('presence', () => {
  const live = (sessionId: string, pid: number, startedAt: number, keyId = KEY_ID) =>
    ({ state: 'live', sessionId, pid, startedAt, keyId })

  test('a session says it runs the plugin, bound to its process, until it ends', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).activation).toEqual(expect.any(String))
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).capabilities).toEqual(CAPABILITIES)
    await $.session.end({ reason: 'other', sessionId: TARGET, resume: { id: TARGET } })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toEqual({ state: 'ended' })
  })

  test('a /clear moves it to the new session id at the next turn', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    await $.session.end({ reason: 'clear', sessionId: TARGET, resume: { id: TARGET } })
    w.sessionId = 'cli-cleared'
    w.registry['4242.json'] = { pid: 4242, sessionId: 'cli-cleared', startedAt: 111 }
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toEqual({ state: 'ended' })
    expect(JSON.parse(w.written['/presence/cli-cleared'])).toMatchObject(live('cli-cleared', 4242, 111))
  })

  test('nothing is said until the registry lists the process', async ($, on) => {
    const w = world(on)
    w.registry = {}
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(w.written).toEqual({})
    w.registry['4242.json'] = { pid: 4242, sessionId: TARGET, startedAt: 111 }
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
  })

  test('a new key (the Router switched off and on) is said again, in the same process and session', async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
    // Off: the key and the presence files are gone; nothing is said.
    w.key = undefined
    w.written = {}
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(w.written).toEqual({})
    // On again, with a new key: said again under it.
    w.key = '11'.repeat(32)
    await $.turn.start({ text: 'hi', turnId: 't2' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111, await keyId('11'.repeat(32))))
  })

  test('the presence is a lease, renewed at every tick and turn without reading the registry again', async ($, on) => {
    const w = world(on, { now: TS })
    const clock = w.clock
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).renewedAt).toBe(TS)
    w.registry = {}
    await clock.advance(10_000)
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject({ ...live(TARGET, 4242, 111), renewedAt: TS + 10_000 })
    await $.turn.start({ text: 'hi', turnId: 't1' })
    expect(JSON.parse(w.written[`/presence/${TARGET}`]).renewedAt).toBe(TS + 10_000)
  })

  test('a corrupt registry file is skipped, not the whole registry', async ($, on) => {
    const w = world(on)
    w.registry = { '1.json': '{ not json', '4242.json': { pid: 4242, sessionId: TARGET, startedAt: 111 } }
    await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    expect(JSON.parse(w.written[`/presence/${TARGET}`])).toMatchObject(live(TARGET, 4242, 111))
  })
})

describe('key ids', () => {
  test('are the first 16 hex digits of the key’s SHA-256', async () => {
    expect(await keyId(KEY)).toBe(KEY_ID)
  })
})

describe('the inbox', () => {
  // The plugin looks every half second, off the clock: the first look starts the session, then the clock moves on.
  const started = new WeakSet<object>()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const look = async ($: any, w: ReturnType<typeof world>) => {
    if (!started.has(w)) {
      started.add(w)
      await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    }
    await w.clock.advance(500)
  }
  const ack = (name: string) => `/inbox/${TARGET}/${name}.ack`

  test('a signed file is submitted as the person’s own words and acked', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await settle()
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
    expect(w.written[ack(NONCE)]).toBe('ok\n')
  })

  test('is taken once: an acked file is not looked at again, a re-written one is a replay', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await look($, w)
    delete w.inbox[`${TARGET}/${NONCE}.ack`]
    await look($, w)
    await settle()
    expect(w.submitted.length).toBe(1)
    expect(w.written[ack(NONCE)]).toBe('refused: already delivered\n')
  })

  test('a file taken over the peer channel first is refused as a replay', async ($, on) => {
    const w = world(on)
    await receive($, envelope(WIRE))
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await settle()
    expect(w.submitted.length).toBe(1)
    expect(w.written[ack(NONCE)]).toBe('refused: already delivered\n')
  })

  const refused: [string, () => Promise<string>, string, number?][] = [
    ['a bad MAC', async () => WIRE.replace(MAC, '0'.repeat(64)), 'bad signature'],
    ['another key', async () => sign(BODY, { key: '00'.repeat(32) }), 'bad signature'],
    ['another session', async () => sign(BODY, { target: 'cli-other' }), 'addressed to another session'],
    ['a stale message', async () => WIRE, 'stale', TS + 11 * 60 * 1000],
    ['no header', async () => BODY, 'unsigned'],
  ]
  for (const [name, make, reason, now] of refused) {
    test(`refuses ${name}`, async ($, on) => {
      const w = world(on, { now })
      w.inbox[`${TARGET}/${NONCE}.msg`] = await make()
      await look($, w)
      await settle()
      expect(w.submitted).toEqual([])
      expect(w.written[ack(NONCE)]).toBe(`refused: ${reason}\n`)
    })
  }

  test('looks only at its own session’s folder and at .msg files', async ($, on) => {
    const w = world(on)
    w.inbox[`cli-other/${NONCE}.msg`] = WIRE
    w.inbox[`${TARGET}/.${NONCE}.tmp`] = WIRE
    await look($, w)
    await settle()
    expect(w.submitted).toEqual([])
    expect(Object.keys(w.written).filter((k) => k.startsWith('/inbox/'))).toEqual([])
  })

  test('a session with no folder is quiet', async ($, on) => {
    const w = world(on)
    w.sessionId = 'cli-none'
    await look($, w)
    expect(w.submitted).toEqual([])
  })

  test('presence names the capability', () => {
    expect(CAPABILITIES).toEqual(['inbox-v1', 'settings-v1', 'abort-v1', 'stop-v1', 'interrupt-v1', 'interrupt-turn-v1'])
  })

  const SETTINGS_NONCE = '223e4567-e89b-12d3-a456-426614174000'
  const put = async (w: ReturnType<typeof world>, settings: Settings, nonce = SETTINGS_NONCE) => {
    w.inbox[`${TARGET}/${nonce}.msg`] = await sign(BODY, { nonce, settings })
  }

  test('v2 signs the settings: the model, then the effort, are set before the text is submitted', async ($, on) => {
    const w = world(on)
    await put(w, { model: 'opus', effort: 'high' })
    await look($, w)
    await settle()
    expect(w.order).toEqual(['model opus', 'effort high', 'submit'])
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
    expect(w.written[ack(SETTINGS_NONCE)]).toBe('ok model=opus effort=high\n')
  })

  test('only what was asked for is set', async ($, on) => {
    const w = world(on)
    await put(w, { effort: 'low' })
    await look($, w)
    await settle()
    expect(w.order).toEqual(['effort low', 'submit'])
    expect(w.written[ack(SETTINGS_NONCE)]).toBe('ok effort=low\n')
  })

  test('a command that fails is told in the ack, the other still runs, and the words still go', async ($, on) => {
    const w = world(on)
    w.commandFails.model = 'unknown model'
    await put(w, { model: 'opus', effort: 'max' })
    await look($, w)
    await settle()
    expect(w.order).toEqual(['model opus', 'effort max', 'submit'])
    expect(w.written[ack(SETTINGS_NONCE)]).toMatch(/^ok model=error:\S+ effort=max\n$/)
  })

  test('a full model id is accepted', async ($, on) => {
    const w = world(on)
    await put(w, { model: 'claude-opus-4-5', effort: 'xhigh' })
    await look($, w)
    await settle()
    expect(w.written[ack(SETTINGS_NONCE)]).toBe('ok model=claude-opus-4-5 effort=xhigh\n')
  })

  for (const settings of [{ model: 'gpt-5' }, { model: 'opus;rm' }, { effort: 'extreme' }, { model: 'opus', effort: '--x' }]) {
    test(`refuses ${JSON.stringify(settings)} and sends nothing`, async ($, on) => {
      const w = world(on)
      await put(w, settings)
      await look($, w)
      await settle()
      expect(w.commands).toEqual([])
      expect(w.submitted).toEqual([])
      expect(w.written[ack(SETTINGS_NONCE)]).toMatch(/^refused: invalid (model|effort)/)
    })
  }

  test('settings can’t be forged: changing them after signing is a bad signature', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${SETTINGS_NONCE}.msg`] = (await sign(BODY, { nonce: SETTINGS_NONCE, settings: { model: 'haiku' } })).replace(' haiku ', ' opus ')
    await look($, w)
    await settle()
    expect(w.commands).toEqual([])
    expect(w.written[ack(SETTINGS_NONCE)]).toBe('refused: bad signature\n')
  })

  test('a v1 message sets nothing', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await settle()
    expect(w.commands).toEqual([])
    expect(w.written[ack(NONCE)]).toBe('ok\n')
  })

  test('over the peer channel the settings are not applied (that hook is waited on), the words still arrive', async ($, on) => {
    const w = world(on)
    const result = await receive($, envelope(await sign(BODY, { settings: { model: 'opus' } })))
    await settle()
    expect(result.consumed).toBeDefined()
    expect(w.commands).toEqual([])
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
  })

  test('the allowlists', () => {
    expect(invalid({ model: 'sonnet[1m]', effort: 'medium' })).toBeUndefined()
    expect(invalid({ model: 'Opus' })).toBeDefined()
    expect(invalid({ effort: 'ultra' })).toBeDefined()
  })

  test('a v2 header is unknown to a v1-only reader: the old pattern finds nothing', async () => {
    expect(/⟦fjord v1 (\S+) (\S+) (\d+) ([0-9a-f]{64})⟧/.test(await sign(BODY, { settings: { model: 'opus' } }))).toBe(false)
  })
})

describe('taking a delivery back', () => {
  const ABORT_NONCE = '323e4567-e89b-12d3-a456-426614174000'
  // The vector Fjord's Swift tests sign the same abort with (RouterCancelTests.theAbortIsSignedAsThePluginChecksIt).
  const ABORT_MAC = '0dbaf1b1ec9728c6d3c3e507515ae0c1ba74dccda5c17011ccfb04a3f688a66a'
  const signAbort = async (cancels = NONCE, { target = TARGET, nonce = ABORT_NONCE, ts = TS, key = KEY } = {}) =>
    `⟦fjord abort v1 ${target} ${nonce} ${ts} ${cancels} ${await hmac(enc.encode(key), abortMacInput(target, nonce, String(ts), cancels))}⟧\n`
  const started = new WeakSet<object>()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const look = async ($: any, w: ReturnType<typeof world>) => {
    if (!started.has(w)) {
      started.add(w)
      await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    }
    await w.clock.advance(500)
    await settle()
  }
  const ack = (name: string) => `/inbox/${TARGET}/${name}.ack`
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const deliver = async ($: any, w: ReturnType<typeof world>) => {
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const abort = async ($: any, w: ReturnType<typeof world>, text?: string) => {
    w.inbox[`${TARGET}/${ABORT_NONCE}.msg`] = text ?? (await signAbort())
    await look($, w)
    return w.written[ack(ABORT_NONCE)]
  }
  const complete = { durationMs: 1, isAborted: false, reason: 'answer' as const, answer: 'done' }

  test('the wire format matches the vector Fjord signs with', async () => {
    const text = await signAbort()
    expect(text).toBe(`⟦fjord abort v1 ${TARGET} ${ABORT_NONCE} ${TS} ${NONCE} ${ABORT_MAC}⟧\n`)
    expect(parseAbort(text)).toEqual({ target: TARGET, nonce: ABORT_NONCE, ts: String(TS), cancels: NONCE, mac: ABORT_MAC })
    // Not a delivery: nothing would be submitted from it, whatever reads it.
    expect(parse(text)).toBeUndefined()
  })

  test('a running turn the delivery started is aborted', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: BODY, turnId: 't1' })
    expect(await abort($, w)).toBe('ok aborted\n')
    expect(w.aborted).toEqual(['t1'])
  })

  test('a delivery queued behind a running turn ends the moment its turn starts', async ($, on) => {
    const w = world(on)
    await $.turn.start({ text: 'what you typed before', turnId: 't0' })
    await deliver($, w)
    expect(await abort($, w)).toBe('ok before-start\n')
    expect(w.aborted).toEqual([])
    await $.turn.complete({ ...complete, turnId: 't0' })
    await $.turn.start({ text: BODY, turnId: 't1' })
    await settle()
    expect(w.aborted).toEqual(['t1'])
  })

  test('read together with words of the person’s own, its turn is not stopped: neither are they', async ($, on) => {
    const w = world(on)
    await $.turn.start({ text: 'first', turnId: 't0' })
    await deliver($, w)
    expect(await abort($, w)).toBe('ok before-start\n')
    await $.turn.complete({ ...complete, turnId: 't0' })
    await $.turn.start({ text: `something typed\n\n${BODY}`, turnId: 't1' })
    await settle()
    expect(w.aborted).toEqual([])
  })

  test('running together with words of the person’s own, a cancel says so and stops nothing', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: `something typed\n\n${BODY}`, turnId: 't1' })
    expect(await abort($, w)).toBe('ok together\n')
    expect(w.aborted).toEqual([])
  })

  test('two deliveries read together are one turn, taken back with either', async ($, on) => {
    const w = world(on)
    const second = 'And then update the changelog for it'
    const NONCE2 = '523e4567-e89b-12d3-a456-426614174000'
    await deliver($, w)
    w.inbox[`${TARGET}/${NONCE2}.msg`] = await sign(second, { nonce: NONCE2 })
    await look($, w)
    await $.turn.start({ text: `${BODY}\n\n${second}`, turnId: 't1' })
    expect(await abort($, w)).toBe('ok aborted\n')
    expect(w.aborted).toEqual(['t1'])
  })

  test('a short delivery is only its turn when it is the whole turn', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${NONCE}.msg`] = await sign('yes')
    await look($, w)
    // The person's later "yes, run the tests again" is not it.
    await $.turn.start({ text: 'yes, run the tests again', turnId: 't1' })
    expect(await abort($, w)).toBe('ok before-start\n')
    await $.turn.complete({ ...complete, turnId: 't1' })
    expect(w.aborted).toEqual([])
  })

  test('a delivery is forgotten past the window: a later turn of the person’s with its words is never aborted', async ($, on) => {
    const w = world(on)
    await $.turn.start({ text: 'first', turnId: 't0' })
    await deliver($, w)
    expect(await abort($, w)).toBe('ok before-start\n')
    await $.turn.complete({ ...complete, turnId: 't0' })
    await w.clock.advance(11 * 60 * 1000)
    await $.turn.start({ text: BODY, turnId: 't1' })
    await settle()
    expect(w.aborted).toEqual([])
  })

  test('a delivery a hook dropped started nothing, and is forgotten', async ($, on) => {
    const w = world(on)
    w.dropSubmit = true
    await deliver($, w)
    await settle()
    // The person then types the same words: theirs, not Fjord's.
    await $.turn.start({ text: BODY, turnId: 't1' })
    expect(await abort($, w)).toBe('ok unknown\n')
    expect(w.aborted).toEqual([])
  })

  test('cancelled while its turn is starting, it ends as it starts', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    let go = () => {}
    w.holdStart = new Promise((resolve) => {
      go = resolve
    })
    const starting = $.turn.start({ text: BODY, turnId: 't1' })
    await settle()
    w.abortFails = true
    expect(await abort($, w)).toBe('ok before-start\n')
    w.abortFails = false
    go()
    await starting
    expect(w.aborted).toEqual(['t1'])
  })

  test('a turn that is over is too late, and nothing is aborted', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: BODY, turnId: 't1' })
    await $.turn.complete({ ...complete, turnId: 't1' })
    expect(await abort($, w)).toBe('ok too-late\n')
    expect(w.aborted).toEqual([])
  })

  test('another turn starting is not mistaken for it, nor is a subagent ending', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: 'something else entirely', turnId: 't1' })
    await $.turn.complete({ ...complete, turnId: 't1', agentId: 'a1' })
    // Still waiting for its own turn: taken back before it starts.
    expect(await abort($, w)).toBe('ok before-start\n')
  })

  test('a delivery not seen yet is refused when it comes', async ($, on) => {
    const w = world(on)
    expect(await abort($, w)).toBe('ok before-start\n')
    await deliver($, w)
    expect(w.submitted).toEqual([])
    expect(w.written[ack(NONCE)]).toBe('refused: already delivered\n')
  })

  test('one an earlier copy submitted (a reload since) can’t be told', async ($, on) => {
    const w = world(on, { store: { [`nonce.${NONCE}`]: TS } })
    expect(await abort($, w)).toBe('ok unknown\n')
  })

  test('a turn that won’t abort is too late', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: BODY, turnId: 't1' })
    w.abortFails = true
    expect(await abort($, w)).toBe('ok too-late\n')
  })

  test('an abort is taken once', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: BODY, turnId: 't1' })
    await abort($, w)
    delete w.inbox[`${TARGET}/${ABORT_NONCE}.ack`]
    expect(await abort($, w)).toBe('refused: already delivered\n')
    expect(w.aborted).toEqual(['t1'])
  })

  const refused: [string, () => Promise<string>, string, number?][] = [
    ['a bad MAC', async () => (await signAbort()).replace(/[0-9a-f]{64}⟧/, `${'0'.repeat(64)}⟧`), 'bad signature'],
    ['another key', async () => signAbort(NONCE, { key: '00'.repeat(32) }), 'bad signature'],
    ['another delivery named after signing', async () => (await signAbort()).replace(` ${NONCE} `, ' 00000000-0000-0000-0000-000000000000 '), 'bad signature'],
    ['another session', async () => signAbort(NONCE, { target: 'cli-other' }), 'addressed to another session'],
    ['a stale abort', async () => signAbort(), 'stale', TS + 11 * 60 * 1000],
  ]
  for (const [name, make, reason, now] of refused) {
    test(`refuses ${name}`, async ($, on) => {
      const w = world(on, { now })
      if (now === undefined) {
        await deliver($, w)
        await $.turn.start({ text: BODY, turnId: 't1' })
      }
      expect(await abort($, w, await make())).toBe(`refused: ${reason}\n`)
      expect(w.aborted).toEqual([])
    })
  }

  test('over the peer channel an abort is nothing: it passes on as the peer message it is', async ($, on) => {
    const w = world(on)
    await deliver($, w)
    await $.turn.start({ text: BODY, turnId: 't1' })
    const text = envelope(await signAbort())
    const result = await receive($, text)
    expect(result.consumed).toBeUndefined()
    expect(w.aborted).toEqual([])
  })

  test('a delivery over the peer channel can be taken back too', async ($, on) => {
    const w = world(on)
    await receive($, envelope(WIRE))
    await $.turn.start({ text: BODY, turnId: 't1' })
    expect(await abort($, w)).toBe('ok aborted\n')
  })
})

describe('taking back a turn that runs tools', () => {
  const ABORT_NONCE = '423e4567-e89b-12d3-a456-426614174000'
  const started = new WeakSet<object>()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const look = async ($: any, w: ReturnType<typeof world>) => {
    if (!started.has(w)) {
      started.add(w)
      await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    }
    await w.clock.advance(500)
    await settle()
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const running = async ($: any, w: ReturnType<typeof world>, text = BODY) => {
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await $.turn.start({ text, turnId: 't1' })
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const abort = async ($: any, w: ReturnType<typeof world>) => {
    const mac = await hmac(enc.encode(KEY), abortMacInput(TARGET, ABORT_NONCE, String(TS), NONCE))
    w.inbox[`${TARGET}/${ABORT_NONCE}.msg`] = `⟦fjord abort v1 ${TARGET} ${ABORT_NONCE} ${TS} ${NONCE} ${mac}⟧\n`
    await look($, w)
    return w.written[`/inbox/${TARGET}/${ABORT_NONCE}.ack`]
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const call = ($: any, id: string): Promise<any> => $.tool.call({ tool: 'Bash', command: 'sleep 90', tool_use_id: id })
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const notify = ($: any, text: string): Promise<any> => $.prompt.submit({ text, origin: { kind: 'task-notification' } })

  test('a tool it is running is cut short before the turn is aborted', async ($, on) => {
    const w = world(on)
    await running($, w)
    const pending = call($, 'toolu_1')
    await settle()
    expect(w.ran).toEqual(['toolu_1'])
    expect(await abort($, w)).toBe('ok aborted\n')
    expect(await pending).toEqual({ deny: 'Stopped: the person stopped this from Fjord.' })
    expect(w.aborted).toEqual(['t1'])
  })

  test('a notification from one of its tools afterwards is dropped; others pass', async ($, on) => {
    const w = world(on)
    await running($, w)
    void call($, 'toolu_1')
    await settle()
    await abort($, w)
    const dropped = await notify($, '<task-notification><tool-use-id>toolu_1</tool-use-id><status>completed</status></task-notification>')
    expect(dropped.drop).toBeDefined()
    const other = await notify($, '<task-notification><tool-use-id>toolu_9</tool-use-id></task-notification>')
    expect(other.drop).toBeUndefined()
  })

  test('an abort that fails cuts nothing, and mutes nothing', async ($, on) => {
    const w = world(on)
    await running($, w)
    const pending = call($, 'toolu_1')
    await settle()
    w.abortFails = true
    expect(await abort($, w)).toBe('ok too-late\n')
    w.finish.toolu_1()
    expect((await pending).result).toBe('finished')
    expect((await notify($, '<task-notification><tool-use-id>toolu_1</tool-use-id></task-notification>')).drop).toBeUndefined()
  })

  test('a background agent of an earlier turn is left be; one this turn spawned is cut with it', async ($, on) => {
    const w = world(on)
    on('agent.spawn', () => ({ model: 'haiku', agentId: 'a-new' }))
    await running($, w)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await ($ as any).agent.spawn({ prompt: 'look around' })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const old = ($ as any).tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'toolu_old', agentId: 'a-old' })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const mine = ($ as any).tool.call({ tool: 'Bash', command: 'make', tool_use_id: 'toolu_mine', agentId: 'a-new' })
    await settle()
    expect(await abort($, w)).toBe('ok aborted\n')
    expect((await mine).deny).toBeDefined()
    w.finish.toolu_old()
    expect((await old).result).toBe('finished')
  })

  test('a notification of several tasks is dropped only when all are the cancelled turn’s', async ($, on) => {
    const w = world(on)
    await running($, w)
    void call($, 'toolu_1')
    await settle()
    await abort($, w)
    const both = '<task-notification><tool-use-id>toolu_1</tool-use-id></task-notification>\n<task-notification><tool-use-id>toolu_9</tool-use-id></task-notification>'
    expect((await notify($, both)).drop).toBeUndefined()
  })

  test('a tool that finishes is answered as it finished', async ($, on) => {
    const w = world(on)
    await running($, w)
    const pending = call($, 'toolu_1')
    await settle()
    w.finish.toolu_1()
    expect((await pending).result).toBe('finished')
  })

  test('the tools of a turn no delivery started pass straight through, and a cancel leaves them be', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await $.turn.start({ text: 'what you typed yourself', turnId: 't0' })
    const pending = call($, 'toolu_1')
    await settle()
    expect(await abort($, w)).toBe('ok before-start\n')
    w.finish.toolu_1()
    expect((await pending).result).toBe('finished')
    expect(w.aborted).toEqual([])
  })
})

describe('stopping a turn and interrupting it', () => {
  const STOP_NONCE = '423e4567-e89b-12d3-a456-426614174000'
  const INTERRUPT_NONCE = '523e4567-e89b-12d3-a456-426614174000'
  // The vectors Fjord's Swift tests check too (SessionControlTests).
  const STOP_MAC = 'e782a0a0eec1e2c602dfcb2085b8da83d7c47dfc505ce7aa93179f4a00ec831b'
  const STOP_ANY_MAC = 'f8d40719bb6cd8b283e0415d5982f789446c8f35b39ea8a46334c611bc55835e'
  const V3_MAC = '397d706bea305bc49650a5a83e5000bc850c791b9e3e06aa7769a0815afacd4c'
  const V3_SETTINGS_MAC = '61a6003925d90fe9ddb2513a15952a918ae05e2d3b40f05a41aae4e11fa37742'
  const V3_FLAG0_MAC = '0fe96e552c0da9b6bd0bf6c704e0c87a77c6ffcb1e6a9158f562bf7e14242692'

  const signStop = async (turn = 't1', { target = TARGET, nonce = STOP_NONCE, ts = TS, key = KEY } = {}) => {
    const mac = await hmac(enc.encode(key), stopMacInput(target, nonce, String(ts), turn))
    return `⟦fjord stop v1 ${target} ${nonce} ${ts} ${turn} ${mac}⟧\n`
  }
  const started = new WeakSet<object>()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const look = async ($: any, w: ReturnType<typeof world>) => {
    if (!started.has(w)) {
      started.add(w)
      await $.session.start({ cwd: '/code/app', surface: null, isInteractive: false })
    }
    await w.clock.advance(500)
    await settle()
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const put = async ($: any, w: ReturnType<typeof world>, nonce: string, text: string) => {
    w.inbox[`${TARGET}/${nonce}.msg`] = text
    await look($, w)
    return w.written[`/inbox/${TARGET}/${nonce}.ack`]
  }
  const complete = { durationMs: 1, isAborted: false, reason: 'answer' as const, answer: 'done' }
  const presence = (w: ReturnType<typeof world>) => JSON.parse(w.written[`/presence/${TARGET}`])
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const call = ($: any, id: string): Promise<any> => $.tool.call({ tool: 'Bash', command: 'sleep 90', tool_use_id: id })

  test('the wire formats match the vectors Fjord signs with', async () => {
    expect(await hmac(enc.encode(KEY), stopMacInput(TARGET, STOP_NONCE, String(TS), 't1'))).toBe(STOP_MAC)
    expect(await hmac(enc.encode(KEY), stopMacInput(TARGET, STOP_NONCE, String(TS), '-'))).toBe(STOP_ANY_MAC)
    const text = await signStop()
    expect(text).toBe(`⟦fjord stop v1 ${TARGET} ${STOP_NONCE} ${TS} t1 ${STOP_MAC}⟧\n`)
    expect(parseStop(text)).toEqual({ target: TARGET, nonce: STOP_NONCE, ts: String(TS), turn: 't1', mac: STOP_MAC })
    // Not a delivery and not an abort.
    expect(parse(text)).toBeUndefined()
    expect(parseAbort(text)).toBeUndefined()
    expect(await hmac(enc.encode(KEY), macInput(TARGET, NONCE, String(TS), enc.encode(BODY), {}, true))).toBe(V3_MAC)
    const settings = { model: 'opus', effort: 'high' }
    expect(await hmac(enc.encode(KEY), macInput(TARGET, NONCE, String(TS), enc.encode(BODY), settings, true))).toBe(V3_SETTINGS_MAC)
    expect(await hmac(enc.encode(KEY), macInput(TARGET, NONCE, String(TS), enc.encode(BODY), {}, false))).toBe(V3_FLAG0_MAC)
    const parsed = parse(envelope(await sign(BODY, { settings, interrupt: true })))
    expect(parsed && { target: parsed.target, nonce: parsed.nonce, settings: parsed.settings, interrupt: parsed.interrupt, mac: parsed.mac }).toEqual({
      target: TARGET, nonce: NONCE, settings, interrupt: true, mac: V3_SETTINGS_MAC,
    })
    expect(parse(envelope(WIRE))?.interrupt).toBeUndefined()
  })

  test('a stop aborts the turn running, one no delivery started, and its tools are cut first', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'what you typed yourself', turnId: 't1' })
    const pending = call($, 'toolu_1')
    await settle()
    expect(await put($, w, STOP_NONCE, await signStop('t1'))).toBe('ok stopped t1\n')
    expect(w.aborted).toEqual(['t1'])
    expect((await pending).deny).toBeDefined()
    expect(w.appended).toEqual(['Stopped from Fjord'])
    // A notification from one of its tools afterwards is dropped, as for a taken-back delivery.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const dropped = await ($ as any).prompt.submit({ text: '<task-notification><tool-use-id>toolu_1</tool-use-id></task-notification>', origin: { kind: 'task-notification' } })
    expect(dropped.drop).toBeDefined()
  })

  test('a turn that completes while its stop awaits the abort is still cut and muted', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    const pending = call($, 'toolu_1')
    await settle()
    let release = () => {}
    w.holdAbort = new Promise<void>((resolve) => (release = resolve))
    w.inbox[`${TARGET}/${STOP_NONCE}.msg`] = await signStop('t1')
    await look($, w)
    await $.turn.complete({ ...complete, turnId: 't1' })
    release()
    await settle()
    await settle()
    expect(w.written[`/inbox/${TARGET}/${STOP_NONCE}.ack`]).toBe('ok stopped t1\n')
    expect((await pending).deny).toBeDefined()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const dropped = await ($ as any).prompt.submit({ text: '<task-notification><tool-use-id>toolu_1</tool-use-id></task-notification>', origin: { kind: 'task-notification' } })
    expect(dropped.drop).toBeDefined()
  })

  test('an interrupt whose stop fails while the turn still runs is refused and submits nothing', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    w.abortFails = true
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true }))).toBe('refused: the running turn could not be stopped\n')
    await settle()
    expect(w.submitted).toEqual([])
  })

  test('an interrupt whose stop fails because the turn just ended goes through as idle', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    w.abortFails = true
    let release = () => {}
    w.holdAbort = new Promise<void>((resolve) => (release = resolve))
    w.inbox[`${TARGET}/${NONCE}.msg`] = await sign(BODY, { interrupt: true })
    await look($, w)
    await $.turn.complete({ ...complete, turnId: 't1' })
    release()
    await settle()
    await settle()
    expect(w.written[`/inbox/${TARGET}/${NONCE}.ack`]).toBe('ok idle\n')
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
  })

  for (const [name, text] of [['empty', ''], ['whitespace', ' \n\t '], ['a slash command', '/clear']] as const) {
    test(`an interrupt with ${name} text is refused before the turn is aborted`, async ($, on) => {
      const w = world(on)
      await look($, w)
      await $.turn.start({ text: 'typed', turnId: 't1' })
      expect(await put($, w, NONCE, await sign(text, { interrupt: true }))).toMatch(/^refused: not submitted: /)
      await settle()
      expect(w.aborted).toEqual([])
      expect(w.submitted).toEqual([])
      expect(w.appended).toEqual([])
    })
  }

  test('an interrupt whose submit is rejected says so in the ack', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    w.dropSubmit = true
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true }))).toBe('refused: not submitted: a hook beneath said no\n')
  })

  test('an interrupt whose submission takes longer than the stuck limit gets one ack, its own, and a stop meanwhile is handled', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    let release = () => {}
    w.holdSubmit = new Promise<void>((resolve) => (release = resolve))
    w.inbox[`${TARGET}/${NONCE}.msg`] = await sign(BODY, { interrupt: true })
    await look($, w)
    // Well past POLL_STUCK_MS, with the submission still waiting: every look in between passes the message by.
    for (let i = 0; i < 14; i++) await look($, w)
    expect(w.written[`/inbox/${TARGET}/${NONCE}.ack`]).toBeUndefined()
    w.inbox[`${TARGET}/${STOP_NONCE}.msg`] = await signStop('t1')
    await look($, w)
    expect(w.written[`/inbox/${TARGET}/${STOP_NONCE}.ack`]).toMatch(/^ok /)
    const writes: string[] = []
    const base = w.inbox
    w.inbox = new Proxy(base, { set: (t, k, v) => (writes.push(String(k)), Reflect.set(t, k, v)) })
    release()
    await settle()
    await settle()
    expect(w.written[`/inbox/${TARGET}/${NONCE}.ack`]).toBe('ok interrupted t1\n')
    expect(writes.filter((k) => k.endsWith(`${NONCE}.ack`))).toHaveLength(1)
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
  })

  test('a subagent belongs to the turn its parent does: an older agent’s child is not cut with a newer turn', async ($, on) => {
    const w = world(on)
    let next = ''
    on('agent.spawn', () => ({ model: 'haiku', agentId: next }))
    await look($, w)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const spawn = (id: string, parentAgentId?: string) => ((next = id), ($ as any).agent.spawn({ prompt: 'go', parentAgentId }))
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const run = (agentId: string, id: string): Promise<any> => $.tool.call({ tool: 'Bash', command: 'make', tool_use_id: id, agentId })
    await $.turn.start({ text: 'first', turnId: 't0' })
    await spawn('a-old')
    await $.turn.complete({ ...complete, turnId: 't0' })
    await $.turn.start({ text: 'second', turnId: 't1' })
    await spawn('a-old-child', 'a-old')
    await spawn('a-new')
    await spawn('a-new-child', 'a-new')
    const oldChild = run('a-old-child', 'toolu_oc')
    const newChild = run('a-new-child', 'toolu_nc')
    await settle()
    expect(await put($, w, STOP_NONCE, await signStop('t1'))).toBe('ok stopped t1\n')
    expect((await newChild).deny).toBeDefined()
    w.finish.toolu_oc()
    expect((await oldChild).result).toBe('finished')
  })

  test('a stop for a turn that is not the running one leaves the running one be', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'first', turnId: 't0' })
    await $.turn.complete({ ...complete, turnId: 't0' })
    await $.turn.start({ text: 'second', turnId: 't1' })
    expect(await put($, w, STOP_NONCE, await signStop('t0'))).toBe('ok not-running\n')
    expect(w.aborted).toEqual([])
    expect(w.appended).toEqual([])
  })

  test('a stop with no turn named stops whichever runs; with none running it is idle', async ($, on) => {
    const w = world(on)
    await look($, w)
    expect(await put($, w, STOP_NONCE, await signStop('-'))).toBe('ok idle\n')
    await $.turn.start({ text: 'second', turnId: 't1' })
    expect(await put($, w, INTERRUPT_NONCE, await signStop('-', { nonce: INTERRUPT_NONCE }))).toBe('ok stopped t1\n')
    expect(w.aborted).toEqual(['t1'])
  })

  test('a stop for a turn already over, or one that will not abort, is not-running and mutes nothing', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'first', turnId: 't0' })
    await $.turn.complete({ ...complete, turnId: 't0' })
    expect(await put($, w, STOP_NONCE, await signStop('t0'))).toBe('ok not-running\n')
    await $.turn.start({ text: 'second', turnId: 't1' })
    const pending = call($, 'toolu_1')
    await settle()
    w.abortFails = true
    expect(await put($, w, INTERRUPT_NONCE, await signStop('t1', { nonce: INTERRUPT_NONCE }))).toBe('ok not-running\n')
    w.finish.toolu_1()
    expect((await pending).result).toBe('finished')
    expect(w.appended).toEqual([])
  })

  test('a stop of a turn a delivery started also ends the delivery', async ($, on) => {
    const w = world(on)
    w.inbox[`${TARGET}/${NONCE}.msg`] = WIRE
    await look($, w)
    await $.turn.start({ text: BODY, turnId: 't1' })
    expect(await put($, w, STOP_NONCE, await signStop('t1'))).toBe('ok stopped t1\n')
    // Taking the delivery back afterwards finds its turn over.
    const mac = await hmac(enc.encode(KEY), abortMacInput(TARGET, INTERRUPT_NONCE, String(TS), NONCE))
    expect(await put($, w, INTERRUPT_NONCE, `⟦fjord abort v1 ${TARGET} ${INTERRUPT_NONCE} ${TS} ${NONCE} ${mac}⟧\n`)).toBe('ok too-late\n')
  })

  const refused: [string, () => Promise<string>, string, number?][] = [
    ['a bad MAC', async () => (await signStop()).replace(/[0-9a-f]{64}⟧/, `${'0'.repeat(64)}⟧`), 'bad signature'],
    ['another key', async () => signStop('t1', { key: '00'.repeat(32) }), 'bad signature'],
    ['another turn named after signing', async () => (await signStop('t1')).replace(' t1 ', ' t2 '), 'bad signature'],
    ['any turn put in after signing', async () => (await signStop('t1')).replace(' t1 ', ' - '), 'bad signature'],
    ['another session', async () => signStop('t1', { target: 'cli-other' }), 'addressed to another session'],
    ['a stale stop', async () => signStop(), 'stale', TS + 11 * 60 * 1000],
  ]
  for (const [name, make, reason, now] of refused) {
    test(`refuses ${name}`, async ($, on) => {
      const w = world(on, { now })
      await look($, w)
      await $.turn.start({ text: 'typed', turnId: 't1' })
      expect(await put($, w, STOP_NONCE, await make())).toBe(`refused: ${reason}\n`)
      expect(w.aborted).toEqual([])
    })
  }

  test('a stop is taken once: a replay is refused and stops nothing', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'first', turnId: 't1' })
    await put($, w, STOP_NONCE, await signStop('-'))
    await $.turn.start({ text: 'second', turnId: 't2' })
    delete w.inbox[`${TARGET}/${STOP_NONCE}.ack`]
    expect(await put($, w, STOP_NONCE, await signStop('-'))).toBe('refused: already delivered\n')
    expect(w.aborted).toEqual(['t1'])
  })

  test('over the peer channel a stop is nothing: it passes on as the peer message it is', async ($, on) => {
    const w = world(on)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    const result = await receive($, envelope(await signStop()))
    expect(result.consumed).toBeUndefined()
    expect(w.aborted).toEqual([])
  })

  test('an interrupt stops the running turn, then submits the words as the person’s own, in that order', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    const pending = call($, 'toolu_1')
    await settle()
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true }))).toBe('ok interrupted t1\n')
    await settle()
    expect((await pending).deny).toBeDefined()
    expect(w.order).toEqual(['abort t1', 'submit'])
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
    expect(w.appended).toEqual(['Interrupted from Fjord'])
  })

  test('a v4 interrupt names the turn it was judged on: it stops that turn, and is refused (nothing submitted, nonce unclaimed) when another runs or none', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    await settle()
    // The turn changed: A ended, B began.
    await $.turn.complete({ ...complete, turnId: 't1' })
    await $.turn.start({ text: 'typed', turnId: 't2' })
    await settle()
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true, expectTurn: 't1' }))).toBe('refused: turn changed\n')
    expect(w.order).toEqual([])
    expect(w.submitted).toEqual([])
    // Not claimed: the same message is refused again as a retry, and still stopped nothing.
    w.inbox[`${TARGET}/${NONCE}.msg`] = await sign(BODY, { interrupt: true, expectTurn: 't1' })
    delete w.written[`/inbox/${TARGET}/${NONCE}.ack`]
    delete w.inbox[`${TARGET}/${NONCE}.ack`]
    await look($, w)
    await settle()
    expect(w.written[`/inbox/${TARGET}/${NONCE}.ack`]).toBe('refused: turn changed\n')
    expect(w.order).toEqual([])
    // The turn it names runs: stopped and submitted.
    expect(await put($, w, STOP_NONCE, await sign(BODY, { interrupt: true, expectTurn: 't2', nonce: STOP_NONCE }))).toBe('ok interrupted t2\n')
    expect(w.order).toEqual(['abort t2', 'submit'])
  })

  test('a v4 interrupt delivered whose ack was lost is refused as already delivered on a retry once another turn runs, never as turn changed', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    await settle()
    const signed = await sign(BODY, { interrupt: true, expectTurn: 't1' })
    expect(await put($, w, NONCE, signed)).toBe('ok interrupted t1\n')
    await settle()
    // The ack is lost; the words started turn t2.
    delete w.written[`/inbox/${TARGET}/${NONCE}.ack`]
    delete w.inbox[`${TARGET}/${NONCE}.ack`]
    await $.turn.start({ text: BODY, turnId: 't2' })
    await settle()
    w.inbox[`${TARGET}/${NONCE}.msg`] = signed
    await look($, w)
    await settle()
    expect(w.written[`/inbox/${TARGET}/${NONCE}.ack`]).toBe('refused: already delivered\n')
    expect(w.order).toEqual(['abort t1', 'submit'])
  })

  test('a v4 interrupt of an idle session that named a turn is refused; its turn is inside the signature', async ($, on) => {
    const w = world(on)
    await look($, w)
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true, expectTurn: 't1' }))).toBe('refused: turn changed\n')
    await $.turn.start({ text: 'typed', turnId: 't1' })
    await settle()
    const signed = await sign(BODY, { interrupt: true, expectTurn: 't9', nonce: STOP_NONCE })
    expect(await put($, w, STOP_NONCE, signed.replace(' t9 ', ' t1 '))).toBe('refused: bad signature\n')
    expect(w.order).toEqual([])
  })

  test('an interrupt applies its settings after the stop and before the words', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true, settings: { model: 'opus', effort: 'high' } }))).toBe(
      'ok interrupted t1 model=opus effort=high\n',
    )
    await settle()
    expect(w.order).toEqual(['abort t1', 'model opus', 'effort high', 'submit'])
  })

  test('an interrupt of an idle session only submits', async ($, on) => {
    const w = world(on)
    await look($, w)
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true }))).toBe('ok idle\n')
    await settle()
    expect(w.aborted).toEqual([])
    expect(w.submitted).toEqual([{ text: BODY, asUser: true }])
  })

  test('a v3 message without the flag set does not interrupt, and plain v1 and v2 keep queueing', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: false }))).toBe('ok\n')
    expect(await put($, w, STOP_NONCE, await sign('plain', { nonce: STOP_NONCE }))).toBe('ok\n')
    await settle()
    expect(w.aborted).toEqual([])
    expect(w.submitted.map((s) => s.text)).toEqual([BODY, 'plain'])
  })

  test('the interrupt flag is inside the signature: clearing it, or setting it, is refused', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    const flagged = await sign(BODY, { interrupt: true })
    expect(await put($, w, NONCE, flagged.replace(/ 1 ([0-9a-f]{64})⟧/, ' 0 $1⟧'))).toBe('refused: bad signature\n')
    const plain = await sign(BODY, { interrupt: false, nonce: STOP_NONCE })
    expect(await put($, w, STOP_NONCE, plain.replace(/ 0 ([0-9a-f]{64})⟧/, ' 1 $1⟧'))).toBe('refused: bad signature\n')
    // A v2 header cannot be dressed as a v3 one either.
    const v2 = await sign(BODY, { settings: { model: 'opus' }, nonce: INTERRUPT_NONCE })
    expect(await put($, w, INTERRUPT_NONCE, v2.replace('v2 ', 'v3 ').replace(/ opus - /, ' opus - 1 '))).toBe('refused: bad signature\n')
    expect(w.aborted).toEqual([])
    expect(w.submitted).toEqual([])
  })

  test('an interrupt is taken once, and not at all over the peer channel', async ($, on) => {
    const w = world(on)
    await look($, w)
    await $.turn.start({ text: 'typed', turnId: 't1' })
    const result = await receive($, envelope(await sign(BODY, { interrupt: true })))
    expect(result.consumed).toBeUndefined()
    await settle()
    expect(w.aborted).toEqual([])
    expect(w.submitted).toEqual([])
    // The same message from the inbox still works: the peer channel claimed nothing.
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true }))).toBe('ok interrupted t1\n')
    delete w.inbox[`${TARGET}/${NONCE}.ack`]
    expect(await put($, w, NONCE, await sign(BODY, { interrupt: true }))).toBe('refused: already delivered\n')
  })

  test('the presence file says which turn runs, as it starts and as it completes', async ($, on) => {
    const w = world(on)
    await look($, w)
    expect(presence(w).turn).toBeNull()
    expect(presence(w).capabilities).toEqual(expect.arrayContaining(['stop-v1', 'interrupt-v1', 'interrupt-turn-v1']))
    await $.turn.start({ text: 'typed', turnId: 't1' })
    expect(presence(w).turn).toEqual({ id: 't1', startedAt: TS + 1500 })
    // A subagent's turn ending changes nothing; the main turn's does.
    await $.turn.complete({ ...complete, turnId: 'sub', agentId: 'a1' })
    expect(presence(w).turn).toEqual({ id: 't1', startedAt: TS + 1500 })
    await $.turn.complete({ ...complete, turnId: 't1' })
    expect(presence(w).turn).toBeNull()
  })
})

const WAKE_NONCE = '123e4567-e89b-12d3-a456-426614174001'
const wake = async (target = TARGET, nonce = WAKE_NONCE, ts = TS, key = KEY) =>
  `fjord-wake ${target} ${nonce} ${ts} ${await hmac(enc.encode(key), wakeMacInput(target, nonce, String(ts)))}`
/** As the app delivers a cold-started session's first prompt. */
const woken = (body: string) =>
  `<system-reminder>\nThis session runs in the Claude desktop app.\n</system-reminder>\n<cross-session-message from="local_relay" name="Fjord">\n${body}\n</cross-session-message>`

describe('a wake', () => {
  test('is read from its own text and from the app’s envelope, and from nothing else', async () => {
    const text = await wake()
    expect(parseWake(text)).toMatchObject({ target: TARGET, nonce: WAKE_NONCE, ts: String(TS) })
    expect(wakeInPrompt(woken(text))?.target).toBe(TARGET)
    expect(wakeInPrompt(woken(`${text} and more`))).toBeUndefined()
    expect(wakeInPrompt(text)).toBeUndefined()
    expect(parseWake('fjord-wake x y')).toBeUndefined()
  })

  test('matches the vector Fjord signs with', async () => {
    expect(await hmac(enc.encode(KEY), wakeMacInput(TARGET, WAKE_NONCE, String(TS)))).toBe('10e8049ccf2ff75827c09de1d03a454989398c2193577174dd7b1321e87a01b6')
  })

  test('is dropped in its target: no turn, and its nonce is used up', async ($, on) => {
    const w = world(on)
    const text = woken(await wake())
    const first = await ($ as any).prompt.submit({ text, origin: { kind: 'peer' } })
    expect(first.drop).toBeDefined()
    expect(w.submitted).toEqual([])
    // Seen already: it goes on as the peer message it then is.
    await ($ as any).prompt.submit({ text, origin: { kind: 'peer' } })
    expect(w.submitted.length).toBe(1)
  })

  test('is dropped only when it is signed, fresh and for this session', async ($, on) => {
    const w = world(on)
    for (const body of [
      await wake('someone-else'),
      await wake(TARGET, '123e4567-e89b-12d3-a456-426614174002', TS - 11 * 60 * 1000),
      await wake(TARGET, '123e4567-e89b-12d3-a456-426614174003', TS, 'other key'),
    ]) {
      const result = await ($ as any).prompt.submit({ text: woken(body), origin: { kind: 'peer' } })
      expect(result.drop).toBeUndefined()
    }
    expect(w.submitted.length).toBe(3)
  })

  test('does not touch other prompts', async ($, on) => {
    const w = world(on)
    await ($ as any).prompt.submit({ text: 'fix the bug', origin: { kind: 'composer' } })
    await ($ as any).prompt.submit({ text: woken('Please review the PR'), origin: { kind: 'peer' } })
    expect(w.submitted.length).toBe(2)
  })
})

describe('SendMessage in the relay', () => {
  /** The hooks beneath take a few turns of the loop to be reached. */
  const reached = async () => { for (let i = 0; i < 40; i++) await settle() }
  const send = ($: any, to: string, message: string) =>
    $.tool.call({ tool: 'SendMessage', to, message, tool_use_id: `toolu_${Math.random()}` })

  test('goes only with a valid wake, to a session of the app', async ($, on) => {
    const w = world(on)
    w.relay = TARGET
    const good = await wake('cli-other')
    const sent = send($, 'local_abc-123', good)
    await reached()
    expect(Object.keys(w.finish).length).toBe(1)
    Object.values(w.finish)[0]()
    expect((await sent).deny).toBeUndefined()
    expect((await send($, 'local_abc-123', 'hello')).deny).toBeDefined()
    expect((await send($, 'local_abc-123', await wake('cli-other', WAKE_NONCE, TS, 'other key'))).deny).toBeDefined()
    expect((await send($, 'someone', good)).deny).toBeDefined()
    expect((await send($, 'local_abc', await wake(TARGET))).deny).toBeDefined()
  })

  test('is left alone in any other session', async ($, on) => {
    const w = world(on)
    w.relay = 'cli-relay'
    const pending = send($, 'someone', 'hello')
    await reached()
    expect(Object.keys(w.finish).length).toBe(1)
    Object.values(w.finish)[0]()
    expect((await pending).deny).toBeUndefined()
  })
})
