"""Build kit/vendor/icons.js from lucide-static (ISC), pinned in npm/package.json: the kit's names → Lucide's drawings.
Run: python3 -I icons.py"""
import pathlib, re, json
HERE = pathlib.Path(__file__).parent.resolve()
SRC = HERE / "npm" / "node_modules" / "lucide-static"
NAMES = {
    "agent": "bot", "model": "sparkles", "you": "user", "people": "users", "terminal": "square-terminal", "command": "terminal",
    "file": "file-text", "code": "file-code", "folder": "folder", "thread": "messages-square", "message": "message-square",
    "cloud": "cloud", "server": "server", "database": "database", "key": "key-round", "lock": "lock", "unlock": "lock-open",
    "machine": "cpu", "process": "settings", "clock": "clock", "timer": "timer", "money": "coins", "check": "check", "cross": "x",
    "warn": "triangle-alert", "alert": "circle-alert", "bolt": "zap", "globe": "globe", "branch": "git-branch", "search": "search",
    "eye": "eye", "hidden": "eye-off", "package": "package", "send": "send", "inbox": "inbox", "layers": "layers", "brain": "brain",
    "tool": "wrench", "plug": "plug", "shield": "shield", "link": "link", "unlink": "unlink", "window": "app-window",
    "laptop": "laptop", "tag": "tag", "route": "route", "split": "split", "workflow": "workflow", "refresh": "refresh-cw",
    "ban": "ban", "bug": "bug", "list": "list", "mail": "mail", "bell": "bell", "image": "image", "play": "play", "pause": "pause",
}
ver = json.loads((SRC / "package.json").read_text())["version"]
out = {}
for name, lucide in NAMES.items():
    svg = (SRC / "icons" / f"{lucide}.svg").read_text()
    inner = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.S).group(1)
    out[name] = re.sub(r"\s+", " ", inner).replace("> <", "><").strip()
(HERE / "kit" / "vendor" / "icons.js").write_text(
    f"/* Icons: lucide-static v{ver} (ISC License, © Lucide Contributors), drawn on a 24 grid, stroked. Built by icons.py. */\n"
    "window.FJORD_ICONS = " + json.dumps(out, indent=0) + ";\n")
print(len(out), "icons, lucide-static", ver)
