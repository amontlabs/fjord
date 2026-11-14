"""MCP server: one tool, preview(code, at). Renders the explainer offscreen and returns frames.
Each previewed version is saved as v1.js, v2.js… in CASE_DIR: that's the live stream a viewer would watch."""
import os, json, re, html, subprocess, pathlib, concurrent.futures as cf
from mcp.server.fastmcp import FastMCP, Image

KIT = pathlib.Path(__file__).parent / "kit"
CASE = pathlib.Path(os.environ["CASE_DIR"]); CASE.mkdir(parents=True, exist_ok=True)
ASK = os.environ.get("ASK", "")
SHELL = os.path.expanduser("~/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell")
mcp = FastMCP("explainer")

def page(code: str, ver: int) -> pathlib.Path:
    d = CASE / f"v{ver}"; d.mkdir(exist_ok=True)
    h = (KIT / "player.html").read_text().replace("KIT/", KIT.as_uri() + "/").replace("ASK_JSON", json.dumps(ASK))
    (d / "index.html").write_text(h); (d / "explainer.js").write_text(code)
    (CASE / f"v{ver}.js").write_text(code)
    return d / "index.html"

def shot(url: str, out: pathlib.Path):
    subprocess.run([SHELL, "--virtual-time-budget=4000", f"--screenshot={out}", "--window-size=1000,760", "--hide-scrollbars", "--allow-file-access-from-files", url],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    return out

@mcp.tool()
def preview(code: str, at: list[float] | None = None) -> list:
    """Render your explainer and look at it. `code` is the full explainer({...}) call.
    Returns timing, any errors, and the held frame at the end of every scene; `at` adds frames at those seconds."""
    ver = len(list(CASE.glob("v*.js"))) + 1
    p = page(code, ver)
    dom = subprocess.run([SHELL, "--virtual-time-budget=4000", "--dump-dom", "--allow-file-access-from-files", p.as_uri() + "?scene=0"],
                         capture_output=True, text=True, timeout=60).stdout
    err = re.search(r'<pre id="errors">(.*?)</pre>', dom, re.S)
    err = html.unescape(err.group(1)).strip() if err else "page did not load"
    tm = re.search(r'data-timing="([^"]*)"', dom)
    timing = json.loads(html.unescape(tm.group(1))) if tm else None
    out = [f"Version {ver}. " + (f"Total {timing['total']} s. Scenes start at " + ", ".join(f"{i}: {s[0]} s" for i, s in enumerate(timing['scenes'])) if timing else "No timing: build() failed.")
           + ("\nErrors and layout notes to fix:\n" + err if err else "\nNo errors, no layout notes.")]
    if not timing: return out
    jobs = [(f"End of scene {i} ({timing['scenes'][i][1]} s)", f"scene={i}") for i in range(len(timing["scenes"]))]
    jobs += [(f"At {t} s", f"t={t}") for t in (at or [])]
    with cf.ThreadPoolExecutor(3) as ex:
        files = list(ex.map(lambda j: shot(p.as_uri() + "?" + j[1], p.parent / (j[1].replace("=", "-") + ".png")), jobs))
    for (label, _), f in zip(jobs, files):
        out += [label, Image(path=str(f))]
    return out

if __name__ == "__main__":
    mcp.run()
