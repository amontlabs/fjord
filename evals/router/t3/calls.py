"""Model calls for N1, disk-cached under data/cache (gitignored). Keys come from the Keychain in-process, never printed.

Sonnet is called the way the app calls it (AnthropicClient, RouterProjectDecide.swift): raw Messages API, the role as one cached
system block, the board and message as the user text, JSON-schema output, thinking `between_tools` (off), max_tokens 700.
Jev goes through evals/router/jev.py, pinned to jev-1.14.0, with questions in the app's wire order."""
import hashlib
import json
import os
import pathlib
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

os.environ["JEV_ORDERED"] = "1"
HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parent))
import jev  # noqa: E402

CACHE = HERE / "data" / "cache"
_K = None
_TLS = ssl.create_default_context(cafile="/etc/ssl/cert.pem" if os.path.exists("/etc/ssl/cert.pem") else None)


def _key():
    global _K
    if _K is None:
        _K = subprocess.run(["security", "find-generic-password", "-s", "fjord-anthropic-key", "-w"],
                            capture_output=True, text=True, check=True).stdout.strip()
    return _K


def anthropic(system, user, schema=None, model="claude-sonnet-5-5", max_tokens=700, thinking={"type": "between_tools"},
              cache_system=True, tag="", effort=None, timeout=180):
    body = {"model": model, "max_tokens": max_tokens,
            "system": [{"type": "text", "text": system, **({"cache_control": {"type": "ephemeral"}} if cache_system else {})}],
            "messages": [{"role": "user", "content": user}]}
    if thinking is not None: body["thinking"] = thinking
    oc = {}
    if schema is not None: oc["format"] = {"type": "json_schema", "schema": schema}
    if effort: oc["effort"] = effort
    if oc: body["output_config"] = oc
    raw = json.dumps(body, sort_keys=True)
    digest = hashlib.sha256((raw + "#" + tag).encode()).hexdigest()
    path = CACHE / "anthropic" / digest[:2] / f"{digest}.json"
    if path.exists():
        return json.loads(path.read_text())
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(), headers={
        "x-api-key": _key(), "anthropic-version": "2023-06-01", "content-type": "application/json"})
    for att in range(6):
        t0 = time.time()
        try:
            r = json.load(urllib.request.urlopen(req, timeout=timeout, context=_TLS))
            sec = time.time() - t0
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 529) and att < 5:
                time.sleep(3 * (att + 1)); continue
            raise RuntimeError(f"HTTP {e.code}: {e.read()[:200]!r}")
        except (urllib.error.URLError, TimeoutError):
            if att < 5: time.sleep(3 * (att + 1)); continue
            raise
    text = next((c["text"] for c in r["content"] if c["type"] == "text"), "")
    try: ans = json.loads(text) if schema is not None else text
    except ValueError: ans = None
    out = {"answer": ans, "sec": sec, "usage": r.get("usage"), "stop": r.get("stop_reason"), "model": r.get("model")}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out))
    return out


def jev_ask(state, questions, model="jev-1.14.0", sample=0):
    return jev.ask(state, questions, model=model, sample=sample)
