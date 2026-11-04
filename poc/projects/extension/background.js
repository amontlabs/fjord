// Takes commands from Fjord's local bridge and runs them in one pinned background claude.ai tab.
const BRIDGE = "http://127.0.0.1:47831";
const PIN_URL = "https://claude.ai/code/projects/browse";
let polling = false;

async function fjordTab() {
  const { tabId } = await chrome.storage?.session?.get?.("tabId") ?? {};
  const known = tabId ? await chrome.tabs.get(tabId).catch(() => null) : null;
  if (known) return known;
  const [existing] = await chrome.tabs.query({ url: "https://claude.ai/code/*", pinned: true });
  const tab = existing ?? await chrome.tabs.create({ url: PIN_URL, pinned: true, active: false });
  await chrome.tabs.update(tab.id, { autoDiscardable: false }).catch(() => {});
  await chrome.storage?.session?.set?.({ tabId: tab.id });
  return tab;
}

function loaded(tabId) {
  return new Promise((done) => {
    const finish = () => { chrome.tabs.onUpdated.removeListener(listen); done(); };
    const listen = (id, change) => { if (id === tabId && change.status === "complete") finish(); };
    chrome.tabs.onUpdated.addListener(listen);
    setTimeout(finish, 15000);
  });
}

async function run(command) {
  const tab = await fjordTab();
  if (command.url && tab.url !== command.url) {
    await chrome.tabs.update(tab.id, { url: command.url });
    await loaded(tab.id);
  }
  const info = await chrome.tabs.get(tab.id);
  let result;
  for (let i = 0; i < 20; i++) {
    result = await chrome.tabs.sendMessage(tab.id, command).catch((error) => ({ error: String(error) }));
    if (!String(result?.error).includes("Receiving end")) break;
    await new Promise((done) => setTimeout(done, 500));
  }
  return { ...result, tab: { active: info.active, discarded: info.discarded, frozen: info.frozen, status: info.status } };
}

async function post(path, body) {
  await fetch(BRIDGE + path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}

async function poll() {
  if (polling) return;
  polling = true;
  try {
    for (;;) {
      const reply = await fetch(BRIDGE + "/next");
      const command = await reply.json();
      if (!command.id) continue;
      const started = Date.now();
      const result = await run(command).catch((error) => ({ error: String(error) }));
      await post("/result", { id: command.id, ms: Date.now() - started, ...result });
    }
  } catch {
    // The bridge isn't running. The alarm tries again.
  } finally {
    polling = false;
  }
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.beat) { post("/beat", message.beat).catch(() => {}); poll(); }
});
chrome.alarms.create("fjord", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => { post("/beat", { from: "worker", at: Date.now() }).catch(() => {}); poll(); });
chrome.runtime.onInstalled.addListener(poll);
chrome.runtime.onStartup.addListener(poll);
poll();
