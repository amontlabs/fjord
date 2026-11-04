// POC: drive Claude Code Projects from a native Mac app, through a hidden signed-in web view.
// Build: swiftc -O poc/projects/ProjectsPOC.swift -o .build/projects-poc
// Run:   .build/projects-poc login | whoami | projects | sessions | timeline <chan> | send <chan> <text> [reply-root]
//        .build/projects-poc watch <chan> <seconds>
// The sign-in stays in this app's own web store. No token is read, printed or saved.
import AppKit
import WebKit

let site = URL(string: "https://claude.ai/code")!

/// The same script body runs for every command: `call` does one request with the headers the API requires.
let prelude = """
const orgId = async () => { const r = await fetch('/api/organizations', {credentials: 'include'});
  if (!r.ok) throw new Error('organizations ' + r.status); return (await r.json())[0].uuid };
const call = async (method, path, body) => { const org = await orgId();
  const r = await fetch(path, {method, credentials: 'include', headers: {'anthropic-version': '2023-06-01',
    'anthropic-beta': 'ccr-byoc-2025-07-29', 'anthropic-client-feature': 'ccr', 'x-organization-uuid': org,
    'content-type': 'application/json'}, body: body ? JSON.stringify(body) : undefined});
  const text = await r.text(); let json = null; try { json = JSON.parse(text) } catch {}
  if (!r.ok) return {status: r.status, mitigated: r.headers.get('cf-mitigated'), error: text.slice(0, 300)};
  return json };
"""

func script(_ command: [String]) -> String? {
    func quoted(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
    }
    switch command.first {
    case "whoami":
        return "const r = await fetch('/api/organizations', {credentials: 'include'}); return {status: r.status, mitigated: r.headers.get('cf-mitigated')}"
    case "projects":
        return """
        const j = await call('GET', '/v1/code/channels?scope=all&include_members=false&limit=200');
        return (j.data || [j]).map(c => ({id: c.id, name: c.name, coordinator: c.channel_session_id, lastMessage: c.last_message_at, unread: c.has_unread}))
        """
    case "sessions":
        return """
        const j = await call('GET', '/v1/code/sessions?statuses=active&statuses=paused&limit=50');
        return (j.data || [j]).map(s => ({id: s.id, title: s.title, status: s.status, bucket: s.status_bucket, worker: s.worker_status, connection: s.connection_status, kind: s.environment_kind, unread: s.unread}))
        """
    case "timeline" where command.count >= 2:
        return """
        const j = await call('GET', '/v1/code/channels/' + \(quoted(command[1])) + '/timeline?limit=200');
        return (j.data || [j]).map(m => ({id: m.id, from: m.author_account_id ? 'you' : 'coordinator', notice: !!m.server_notice,
          body: (m.body || '').slice(0, 200), thread: m.thread_status, working: m.thread_any_session_working,
          sessions: (m.bound_sessions || []).map(b => ({id: b.id, title: b.title, bucket: b.status_bucket, device: b.device_state}))}))
        """
    case "ui-read":
        return """
        const ready = async s => { for (let i = 0; i < 80; i++) { const e = document.querySelector(s); if (e) return e; await new Promise(k => setTimeout(k, 250)) } throw new Error('missing ' + s) };
        await ready('[data-testid="code-prompt-input"]');
        for (let i = 0; i < 48 && !document.querySelector('[data-testid="overview-thread-row"]'); i++) await new Promise(k => setTimeout(k, 250));
        return [...document.querySelectorAll('[data-testid="overview-thread-row"]')].map(r => ({thread: r.getAttribute('data-home-card'), text: r.innerText.replace(/\\n+/g, ' | ')}))
        """
    case "ui-chat":
        return """
        const ready = async s => { for (let i = 0; i < 80; i++) { const e = document.querySelector(s); if (e) return e; await new Promise(k => setTimeout(k, 250)) } throw new Error('missing ' + s) };
        const list = await ready('[data-testid="epitaxy-virtual-transcript"]'); await ready('[data-testid="transcript-row"]');
        let box = list; while (box && box.scrollHeight <= box.clientHeight + 4) box = box.parentElement;
        const seen = new Map(); box.scrollTop = 0; await new Promise(k => setTimeout(k, 800));
        for (let i = 0; i < 400; i++) {
          document.querySelectorAll('[data-testid="transcript-row"]').forEach(r => { const t = r.innerText.replace(/\\n+/g, ' ').trim(); if (t) seen.set(t, true) });
          if (box.scrollTop + box.clientHeight >= box.scrollHeight - 4) break;
          box.scrollTop += box.clientHeight * 0.7; await new Promise(k => setTimeout(k, 180))
        }
        return [...seen.keys()]
        """
    case "ui-send" where command.count >= 3:
        let last = command.count > 3
        return """
        const ready = async s => { for (let i = 0; i < 80; i++) { const e = document.querySelector(s); if (e) return e; await new Promise(k => setTimeout(k, 250)) } throw new Error('missing ' + s) };
        await ready('[data-testid="code-prompt-input"]');
        if (\(last)) for (let i = 0; i < 80 && document.querySelectorAll('[data-testid="code-prompt-input"]').length < 2; i++) await new Promise(k => setTimeout(k, 250));
        if (!\(last)) { const back = document.querySelector('[data-testid="overview-thread-crumb-back"]'); if (back) { back.click(); await new Promise(k => setTimeout(k, 800)) } }
        const boxes = [...document.querySelectorAll('[data-testid="code-prompt-input"]')];
        const shape = boxes.map(b => [b.getAttribute('aria-label'), Math.round(b.getBoundingClientRect().x), Math.round(b.getBoundingClientRect().width)]);
        const box = boxes[\(last) ? boxes.length - 1 : 0]; box.focus();
        document.execCommand('selectAll'); document.execCommand('delete');
        await new Promise(k => setTimeout(k, 300));
        const typed = document.execCommand('insertText', false, \(quoted(command[2])));
        await new Promise(k => setTimeout(k, 500));
        const pick = () => { const all = [...document.querySelectorAll('[data-testid="code-prompt-send"]')]; return all[\(last) ? all.length - 1 : 0] };
        const trace = [];
        for (let i = 0; i < 40; i++) {
          const send = pick(); trace.push(send ? [send.disabled, send.getAttribute('aria-label')] : null);
          if (send && !send.disabled) { send.click(); await new Promise(k => setTimeout(k, 1200)); if (!box.textContent.trim()) return {sent: true, tries: i + 1, shape} }
          await new Promise(k => setTimeout(k, 500));
        }
        const send = pick(); const props = send ? Object.keys(send).find(k => k.startsWith('__reactProps')) : null;
        return {sent: false, shape, left: box.textContent.slice(0, 80), visible: document.visibilityState, focused: document.activeElement === box, hasFocus: document.hasFocus(),
          near: (send?.closest('form') || send?.parentElement?.parentElement)?.innerText?.replace(/\\s+/g, ' ').slice(0, 160), banner: document.body.innerText.slice(-200).replace(/\\s+/g, ' ')}
        """
    case "board":
        return """
        const channels = (await call('GET', '/v1/code/channels?scope=all&include_members=false&limit=200')).data || [];
        const sessions = (await call('GET', '/v1/code/sessions?statuses=active&statuses=paused&limit=100')).data || [];
        const projects = [];
        for (const c of channels) {
          const roots = (await call('GET', '/v1/code/channels/' + c.id + '/timeline?limit=200&thread_roots_only=true')).data || [];
          projects.push({id: c.id, name: c.name, coordinator: c.channel_session_id, threads: roots.filter(m => (m.bound_sessions || []).length).map(m => ({root: m.id,
            ask: (m.body || '').slice(0, 160), status: m.thread_status, sessions: m.bound_sessions.map(b => ({id: b.id, title: b.title, bucket: b.status_bucket, device: b.device_state}))}))})
        }
        return {projects, sessions: sessions.map(s => ({id: s.id, title: s.title, bucket: s.status_bucket, worker: s.worker_status, connection: s.connection_status, kind: s.environment_kind, unread: s.unread, updated: s.updated_at}))}
        """
    case "thread" where command.count >= 3:
        return """
        const j = await call('GET', '/v1/code/channels/' + \(quoted(command[1])) + '/threads/' + \(quoted(command[2])));
        return (j.data || [j]).map(m => ({from: m.author_account_id ? 'you' : 'claude', notice: !!m.server_notice, body: (m.body || '').slice(0, 800)}))
        """
    case "markread" where command.count >= 2:
        return """
        const id = \(quoted(command[1]));
        const events = await call('GET', '/v1/code/sessions/' + id + '/events?limit=1&sort_order=desc');
        const last = (events.data || [])[0];
        if (!last) return events;
        return await call('POST', '/v1/code/sessions/' + id + '/mark_read', {event_id: last.uuid || last.id})
        """
    case "send" where command.count >= 3:
        let reply = command.count > 3 ? "reply_to_message_id: \(quoted(command[3]))," : ""
        return """
        return await call('POST', '/v1/code/channels/' + \(quoted(command[1])) + '/messages',
          {body: \(quoted(command[2])), \(reply) client_message_id: crypto.randomUUID(), sender_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone})
        """
    case "watch" where command.count >= 3:
        return """
        const org = await orgId(); const stop = Date.now() + 1000 * Number(\(quoted(command[2])));
        const r = await fetch('/v1/code/channels/' + \(quoted(command[1])) + '/messages/stream?from=tail&caught_up=true', {credentials: 'include',
          headers: {'anthropic-version': '2023-06-01', 'x-organization-uuid': org}});
        const reader = r.body.getReader(), decoder = new TextDecoder(); const events = [];
        while (Date.now() < stop) { const part = await Promise.race([reader.read(), new Promise(k => setTimeout(() => k({timeout: true}), stop - Date.now()))]);
          if (part.timeout || part.done) break; events.push(decoder.decode(part.value).slice(0, 400)) }
        reader.cancel(); return {status: r.status, events}
        """
    default:
        return nil
    }
}

final class Runner: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let command: [String]
    var web: WKWebView!
    var window: NSWindow?
    init(_ command: [String]) { self.command = command }

    func applicationDidFinishLaunching(_ notification: Notification) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 760), configuration: {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .default()
            return c
        }())
        web.navigationDelegate = self
        if command.first == "login" {
            let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Fjord POC: sign in to Claude, then close this window"
            w.contentView = web
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window = w
        }
        var target = site
        if command.first?.hasPrefix("ui-") == true, command.count > 1 {
            let thread = command.first == "ui-send" && command.count > 3 ? "?thread=\(command[3])" : ""
            target = URL(string: "https://claude.ai/code/project/\(command[1])\(thread)")!
        }
        web.load(URLRequest(url: target))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { command.first == "login" }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard command.first != "login", let body = script(command) else {
            if command.first != "login" { print("unknown command"); exit(2) }
            return
        }
        Task { @MainActor in
            do {
                let result = try await web.callAsyncJavaScript(prelude + body, contentWorld: .page)
                let data = try JSONSerialization.data(withJSONObject: result ?? NSNull(), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                print(String(data: data, encoding: .utf8)!)
                exit(0)
            } catch {
                print("failed: \(error)")
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let runner = Runner(Array(CommandLine.arguments.dropFirst()))
app.delegate = runner
app.run()
