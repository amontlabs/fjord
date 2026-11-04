"""The worker (background.js) run against a fake `chrome`: after an extension reload nothing stays without a page."""
import json, os, shutil, subprocess, tempfile, textwrap, unittest

EXT = os.path.join(os.path.dirname(__file__), "..", "extension")

HARNESS = r"""
const fs = require("fs");
const listeners = {};
const ev = (name) => ({ addListener: (f) => (listeners[name] ??= []).push(f) });
let injected = 0, failures = +process.argv[2], status = process.argv[3];
const tab = { id: 7, url: "https://claude.ai/code/projects/browse#fjord", status, windowId: 1 };
let connectCb = null;
globalThis.chrome = {
  runtime: { onConnect: ev("connect"), onStartup: ev("startup"), onInstalled: ev("installed"), onMessage: ev("msg"),
    connectNative: () => ({ postMessage() {}, disconnect() {}, onMessage: ev("n"), onDisconnect: ev("nd") }), reload() {} },
  alarms: { create() {}, onAlarm: ev("alarm") },
  storage: { session: { _d: {}, get: async function (k) { return { [k]: this._d[k] }; }, set: async function (o) { Object.assign(this._d, o); }, remove: async function (k) { delete this._d[k]; } } },
  tabs: { query: async () => [tab], get: async () => tab, update: async () => tab, create: async () => tab, remove: async () => {},
    sendMessage: async () => { throw new Error("no receiver"); }, onActivated: ev("act"), onRemoved: ev("rem"), onUpdated: ev("upd") },
  windows: { getAll: async () => [{ id: 1 }], onCreated: ev("wc") },
  scripting: { executeScript: async () => { injected++; if (failures-- > 0) throw new Error("not ready"); setTimeout(() => {
    const port = { name: "fjord-page", sender: { tab }, postMessage() {}, disconnect() {}, onMessage: ev("pm"), onDisconnect: ev("pd") };
    listeners.connect.forEach((f) => f(port)); }, 5); } },
};
globalThis.chrome.storage.session._d = {};  // an extension reload clears the remembered tab
const real = setTimeout; globalThis.setTimeout = (f, ms, ...a) => real(f, Math.min(ms, 20), ...a);
eval(fs.readFileSync(process.argv[4], "utf8"));
listeners.installed.forEach((f) => f({ reason: "update" }));
real(() => {
  if (status === "loading") { tab.status = "complete"; listeners.upd.forEach((f) => f(7, { status: "complete" })); }
  real(() => { console.log(JSON.stringify({ injected })); process.exit(0); }, 600);
}, 100);
"""


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class ReloadRecovers(unittest.TestCase):
    def run_worker(self, failures, status):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "h.js")
            open(path, "w").write(HARNESS)
            out = subprocess.run(["node", path, str(failures), status, os.path.join(EXT, "background.js")],
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout.strip().splitlines()[-1])["injected"]

    def test_injection_refused_at_first_is_tried_again(self):
        self.assertEqual(self.run_worker(2, "complete"), 3)

    def test_tab_still_loading_is_ensured_when_it_completes(self):
        self.assertGreaterEqual(self.run_worker(0, "loading"), 1)


if __name__ == "__main__":
    unittest.main()
