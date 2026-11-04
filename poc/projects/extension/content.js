// Reads what the page shows and types in its real composer. Selects by test id, never by visible text.
const wait = (ms) => new Promise((done) => setTimeout(done, ms));
const all = (id) => [...document.querySelectorAll(`[data-testid="${id}"]`)];

async function ready(id, tries = 20) {
  for (let i = 0; i < tries; i++) {
    if (all(id).length) return true;
    await wait(250);
  }
  return false;
}

function read() {
  return {
    title: document.title,
    visibility: document.visibilityState,
    threads: all("overview-thread-row").map((row) => ({ thread: row.getAttribute("data-home-card"), text: row.innerText.replace(/\n+/g, " | ") })),
  };
}

async function send(text, inThread) {
  if (!(await ready("code-prompt-input"))) return { sent: false, reason: "no composer" };
  if (!inThread) {
    const back = all("overview-thread-crumb-back")[0];
    if (back) { back.click(); await wait(800); }
  } else {
    for (let i = 0; i < 80 && all("code-prompt-input").length < 2; i++) await wait(250);
  }
  const boxes = all("code-prompt-input");
  const box = boxes[inThread ? boxes.length - 1 : 0];
  box.focus();
  document.execCommand("selectAll");
  document.execCommand("delete");
  await wait(300);
  const typed = document.execCommand("insertText", false, text);
  await wait(500);
  const sends = all("code-prompt-send");
  const button = sends[inThread ? sends.length - 1 : 0];
  for (let i = 0; i < 40; i++) {
    if (button && !button.disabled) {
      button.click();
      await wait(1200);
      if (!box.textContent.trim()) return { sent: true, tries: i + 1, typed, visibility: document.visibilityState, focused: document.hasFocus() };
    }
    await wait(500);
  }
  return { sent: false, typed, left: box.textContent.slice(0, 80), disabled: button?.disabled, visibility: document.visibilityState, focused: document.hasFocus() };
}

chrome.runtime.onMessage.addListener((command, _sender, reply) => {
  (async () => {
    if (command.kind === "read") {
      await ready("code-prompt-input");
      for (let i = 0; i < 12 && !all("overview-thread-row").length; i++) await wait(250);
      return read();
    }
    if (command.kind === "send") return send(command.text, command.inThread);
    if (command.kind === "diagnose") {
      const ids = new Set([...document.querySelectorAll("[data-testid]")].map((e) => e.getAttribute("data-testid")));
      return { path: location.pathname, title: document.title, visibility: document.visibilityState, focused: document.hasFocus(), nodes: document.querySelectorAll("*").length, testids: ids.size, composer: ids.has("code-prompt-input"), text: document.body.innerText.slice(0, 200) };
    }
    return { error: "unknown command" };
  })().then(reply, (error) => reply({ error: String(error) }));
  return true;
});

// Measures how far a hidden tab's timers drift. Each beat records the gap since the last one.
let last = Date.now();
setInterval(() => {
  const now = Date.now();
  chrome.runtime.sendMessage({ beat: { from: "page", gap: now - last, hidden: document.hidden } }).catch(() => {});
  last = now;
}, 5000);
