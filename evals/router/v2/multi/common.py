"""Shared pieces of the multi-place benchmark: paths, cached model calls (Claude, GPT via Codex, Gemini via Antigravity),
the board as the Router's Jev options describe it, and the place vocabulary.

A place is `session:<id>`, `new:<project>` or `fjord` (Fjord itself: a change to Fjord, or a question about the board).
Everything under DATA is gitignored (v2/.gitignore: data/). Nothing here prints message or board text."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROUTER = HERE.parents[1]
DATA = ROUTER / "v2" / "data" / "multi"
CACHE = DATA / "cache"
sys.path.insert(0, str(ROUTER))
sys.path.insert(0, str(ROUTER / "real"))
os.environ["JEV_ORDERED"] = "1"

HAIKU = "claude-haiku-5-5"
SONNET = "claude-sonnet-5-5"
GPT = "gpt-6.1-sol"
GEMINI = "gemini-4-argon-high"
# Argon's subscription quota ran out on 2026-10-19 (it resets a week later): Gemini calls not already made with it use
# Flash.
GEMINI_FALLBACK = "gemini-3.8-flash-high"
CLAUDE_FLAGS = ["--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
                "--output-format", "json"]
FAMILY_MODEL = {"claude": SONNET, "gpt": GPT, "gemini": GEMINI}


def jsonl(path):
    path = pathlib.Path(path)
    return [json.loads(l) for l in path.open() if l.strip()] if path.exists() else []


def write_jsonl(path, rows):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def _cached(tag, key_parts, call, cache_only=False):
    key = hashlib.sha256(json.dumps(key_parts, ensure_ascii=False).encode()).hexdigest()
    path = CACHE / tag / key[:2] / f"{key}.json"
    if path.exists():
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            pass
    if cache_only:
        return {"out": None, "text": None, "error": "not cached"}
    res = call()
    if res.get("error") is None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(res, ensure_ascii=False))
        os.replace(tmp, path)
    return res


def _claude_binary():
    """The Claude app's own Claude Code, as the app runs it (RouterStatus.findDefault); `claude` on PATH otherwise."""
    root = pathlib.Path.home() / "Library" / "Application Support" / "Claude" / "claude-code"
    if root.is_dir():
        versions = sorted((d.name for d in root.iterdir() if d.name[:1].isdigit()),
                          key=lambda v: [int(x) for x in re.findall(r"\d+", v)], reverse=True)
        for v in versions:
            for h in sorted(x.name for x in (root / v).iterdir() if not x.name.startswith(".")):
                path = root / v / h / "claude.app" / "Contents" / "MacOS" / "claude"
                if os.access(path, os.X_OK):
                    return str(path), v
    return "claude", "path"


CLAUDE_BIN, CLAUDE_VERSION = _claude_binary()


def claude(model, system, prompt, schema=None, tag="claude", timeout=180):
    """One isolated `claude -p` call (empty cwd, no tools, no settings, no MCP), as the app makes its Haiku runs.
    Returns {"out": structured output or None, "text", "cost", "elapsed", "error"}; cached by everything that goes in."""
    def call():
        args = [CLAUDE_BIN, "-p", "--model", model] + CLAUDE_FLAGS + (["--json-schema", json.dumps(schema)] if schema else []) \
            + ["--system-prompt", system]
        res = {}
        for attempt in range(3):
            t0 = time.time()
            res = {"out": None, "text": None, "cost": None, "error": None, "usage": None}
            with tempfile.TemporaryDirectory(prefix="multi-") as cwd:
                try:
                    p = subprocess.run(args, input=prompt, capture_output=True, text=True, cwd=cwd, timeout=timeout)
                    try:
                        out = json.loads(p.stdout)
                        if out.get("is_error"):
                            res["error"] = "API error: " + str(out.get("result"))[:200]
                        res["out"] = out.get("structured_output")
                        res["text"] = out.get("result")
                        res["cost"] = out.get("total_cost_usd")
                        res["usage"] = out.get("usage")
                        res["api_ms"] = out.get("duration_api_ms")
                    except json.JSONDecodeError:
                        res["error"] = f"exit {p.returncode}: not JSON"
                except subprocess.TimeoutExpired:
                    res["error"] = "timeout"
            res["elapsed"] = round(time.time() - t0, 2)
            if res["error"] is None and (schema is None or isinstance(res["out"], dict)):
                break
            if res["error"] is None:
                res["error"] = "no structured output"
            time.sleep(4 * (attempt + 1))
        return res
    return _cached(tag, [model, system, prompt, schema, CLAUDE_FLAGS, CLAUDE_VERSION], call)


def _json_in(text):
    """The last JSON object or array in a model's text answer (fences tolerated)."""
    if not text:
        return None
    text = re.sub(r"```(?:json)?", "", text)
    for opener, closer in (("{", "}"), ("[", "]")):
        start = text.find(opener)
        end = text.rfind(closer)
        if start != -1 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError:
                continue
    # Prose around it with braces of its own: the longest object that decodes from some opening brace.
    decoder, best = json.JSONDecoder(), None
    for i, ch in enumerate(text):
        if ch == "{":
            try:
                obj, end = decoder.raw_decode(text, i)
            except json.JSONDecodeError:
                continue
            if best is None or end - i > best[0]:
                best = (end - i, obj)
    return best[1] if best else None


def codex(prompt, tag="gpt", effort="high", timeout=900):
    """`codex exec` with GPT-6.1 Sol, read-only, from an empty folder; the answer parsed as JSON."""
    def call():
        res = {}
        for attempt in range(3):
            t0 = time.time()
            res = {"out": None, "text": None, "error": None}
            with tempfile.TemporaryDirectory(prefix="multi-gpt-") as cwd:
                out_file = pathlib.Path(cwd) / "answer.txt"
                try:
                    subprocess.run(["codex", "exec", "-m", GPT, "-c", f"model_reasoning_effort={effort}", "--sandbox",
                                    "read-only", "--skip-git-repo-check", "-o", str(out_file), "-"],
                                   input=prompt, capture_output=True, text=True, cwd=cwd, timeout=timeout)
                    res["text"] = out_file.read_text() if out_file.exists() else None
                    res["out"] = _json_in(res["text"])
                    if res["out"] is None:
                        res["error"] = "no JSON"
                except subprocess.TimeoutExpired:
                    res["error"] = "timeout"
            res["elapsed"] = round(time.time() - t0, 2)
            if res["error"] is None:
                break
            time.sleep(10 * (attempt + 1))
        return res
    return _cached(tag, [GPT, effort, prompt], call)


def gemini(prompt, tag="gemini", timeout=420, model=GEMINI, cache_only=False):
    """Gemini through Antigravity (`agy -p`, sandboxed; plan mode hangs on long prompts) from an empty folder; the answer parsed as JSON."""
    def call():
        res = {}
        for attempt in range(3):
            t0 = time.time()
            res = {"out": None, "text": None, "error": None}
            with tempfile.TemporaryDirectory(prefix="multi-gemini-") as cwd:
                try:
                    p = subprocess.run(["agy", "-p", prompt, "--model", model, "--output-format", "json", "--sandbox",
                                        "--print-timeout", f"{timeout - 60}s"], capture_output=True, text=True, cwd=cwd, timeout=timeout,
                                       stdin=subprocess.DEVNULL)
                    try:
                        wrapper = json.loads(p.stdout)
                        res["text"] = wrapper.get("response")
                        if wrapper.get("status") != "SUCCESS":
                            res["error"] = "status " + str(wrapper.get("status"))
                    except json.JSONDecodeError:
                        # Log lines around the wrapper: decode it from where it starts.
                        i = p.stdout.find('{"conversation_id"')
                        try:
                            wrapper = json.JSONDecoder().raw_decode(p.stdout, i)[0] if i >= 0 else {}
                        except json.JSONDecodeError:
                            wrapper = {}
                        res["text"] = wrapper.get("response") or p.stdout
                    res["out"] = _json_in(res["text"])
                    if res["out"] is None and res["error"] is None:
                        res["error"] = "no JSON"
                        debug = DATA / "debug"
                        debug.mkdir(parents=True, exist_ok=True)
                        (debug / f"{tag}-{int(time.time())}.txt").write_text(p.stdout + "\n--- stderr\n" + p.stderr)
                except subprocess.TimeoutExpired:
                    res["error"] = "timeout"
            res["elapsed"] = round(time.time() - t0, 2)
            if res["error"] is None:
                break
            time.sleep(5)  # a hung agent turn is common; a fresh one usually answers in 1–2 minutes
        return res
    return {**_cached(tag, [model, prompt], call, cache_only), "model": model}


def family_call(family, prompt, tag, system="Answer with JSON only."):
    """A writer or labeller call by family: Claude (Sonnet, no schema: the JSON is read from its text), GPT, Gemini."""
    if family == "claude":
        if os.environ.get("MULTI_CLAUDE_VIA") == "agent":
            return via_agent(system, prompt, tag)
        res = claude(SONNET, system, prompt, None, tag=tag, timeout=600)
        return {**res, "out": _json_in(res.get("text")) if res.get("error") is None else None}
    if family == "gpt":
        return codex(system + "\n\n" + prompt, tag=tag)
    if family == "gemini":
        res = gemini(system + "\n\n" + prompt, tag=tag, cache_only=True)
        if res.get("error") is None:
            return res
        return gemini(system + "\n\n" + prompt, tag=tag, model=GEMINI_FALLBACK)
    raise ValueError(family)


AGENT = DATA / "agent"


def via_agent(system, prompt, tag):
    """Claude-family writing and labelling through Claude Code subagents (Sonnet), for when `claude -p` can't log in:
    the prompt is left in agent/<tag>/<key>.prompt.txt, a subagent writes its JSON answer to <key>.answer.json."""
    key = hashlib.sha256(json.dumps([system, prompt], ensure_ascii=False).encode()).hexdigest()[:24]
    folder = AGENT / tag
    folder.mkdir(parents=True, exist_ok=True)
    answer = folder / f"{key}.answer.json"
    if answer.exists():
        text = answer.read_text()
        out = _json_in(text)
        return {"out": out, "text": text, "error": None if out is not None else "no JSON"}
    (folder / f"{key}.prompt.txt").write_text(system + "\n\n" + prompt)
    return {"out": None, "text": None, "error": "awaiting agent"}


# ---------------------------------------------------------------- the board, as the Router's Jev options say it

_MODULES = None


def legacy():
    """The shipped format's builder (combo-o), loaded once through the v2 replay's adapter."""
    global _MODULES
    if _MODULES is None:
        from v2.run import episodes
        system = episodes.RouterSystem(cache_only=True)
        _MODULES = system._load()
    return _MODULES


def options(state, message, context=None):
    """The places on this board, keyed for a model, described as the Router's Jev route options describe them today
    (title, project, what it is doing now, what you last told it). Returns [(key, place, description)]."""
    from v2.run import adapter
    formats = legacy()[0]
    case = adapter.to_case(state, message=message, context={k: v for k, v in (context or {}).items() if k != "tags"},
                           case_id="mp")
    built, questions, keymap = formats.build("combo-o", case)
    criteria = questions["route"]["criteria"]
    rows, n = [], 0
    for name, desc in criteria.items():
        target = keymap.get(name, name)
        if target in ("compound", "unclear"):
            continue
        if target == "change_fjord":
            rows.append(("fjord-change", "change_fjord", "Fjord itself: " + desc.replace("Lookout", "Fjord")))
        elif target == "question":
            rows.append(("fjord-question", "question", "Fjord itself: " + desc.replace("Lookout", "Fjord")))
        elif target.startswith("new:"):
            rows.append((target, target, json.dumps(desc, ensure_ascii=False)))
        else:
            n += 1
            d = dict(desc) if isinstance(desc, dict) else {"about": desc}
            d = {"title": name, **d}
            rows.append((f"S{n}", "session:" + target, json.dumps(d, ensure_ascii=False)))
    # Every project the board knows can take a new session (the format may cap them).
    have = {r[1] for r in rows}
    for p in state.get("projects", []):
        if "new:" + p not in have:
            rows.append(("new:" + p, "new:" + p, json.dumps({"kind": "new session", "project": p})))
    return rows


def place_of(target):
    """A target in the v2 vocabulary as a place: Fjord's intents are one place."""
    if target in ("change_fjord", "question", "compound"):
        return "fjord"
    return target


def norm_words(text):
    return re.findall(r"[\w'’]+", (text or "").lower())
