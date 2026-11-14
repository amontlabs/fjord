"""Build one self-contained page: a dock-like list of every explainer, one player, versions per explainer."""
import base64, json, pathlib, re
HERE = pathlib.Path(__file__).parent
kit = HERE / "kit"
libs = "\n".join((kit / "vendor" / f).read_text() for f in
                 ["gsap.min.js", "MotionPathPlugin.min.js", "DrawSVGPlugin.min.js", "MorphSVGPlugin.min.js", "CustomEase.min.js", "icons.js"])
player = (kit / "player.html").read_text()
# The page is one file, so Fjord's fonts go in as data URLs where player.css names kit/fonts/.
MIME = {".otf": "font/otf", ".ttf": "font/ttf", ".woff2": "font/woff2"}
def font(m):
    f = kit / m.group(1)
    return f'url("data:{MIME[f.suffix]};base64,{base64.b64encode(f.read_bytes()).decode()}")'
css = re.sub(r'url\("(fonts/[^"]+)"\)', font, (kit / "player.css").read_text())
assert "url(\"fonts/" not in css and css.count("base64,") == 3, "player.css: expected three fonts to inline"
player = player.replace('<link rel="stylesheet" href="KIT/player.css">', "<style>" + css + "</style>")
player = re.sub(r'(<script src="KIT/vendor/[^"]+"></script>\n?)+', "<script>__LIBS__</script>\n", player)
player = player.replace('<script src="KIT/kit.js"></script>', "<script>" + (kit / "kit.js").read_text() + "</script>")
player = player.replace('<script src="explainer.js"></script>', "<script>__CODE__</script>")

items = []
for c in sorted((HERE / "cases2").iterdir()):
    if not (c / "final.js").exists(): continue
    run = json.loads((c / "run.json").read_text())
    vers = sorted(c.glob("v*.js"), key=lambda p: int(p.stem[1:]))
    codes = [v.read_text() for v in vers]
    final = (c / "final.js").read_text()
    if not codes or codes[-1].strip() != final.strip(): codes.append(final)
    old = HERE / "cases" / c.name / "final.js"
    before = old.read_text() if old.exists() else None
    title = re.search(r'title:\s*("(?:[^"\\]|\\.)*")', final)
    items.append({"name": c.name, "title": json.loads(title.group(1)) if title else c.name, "ask": (c / "ask.txt").read_text(),
                  "project": re.search(r'project="([^"]*)"', (c / "user.md").read_text()).group(1),
                  "versions": codes, "cost": run.get("total_cost_usd"), "secs": round((run.get("duration_ms") or 0) / 1000),
                  "input": (c / "user.md").read_text(), "before": before})

page = """<meta charset="utf-8">
<title>Explainer Dock</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
/* layout: a dock list beside one player, stacked on narrow screens */
:root{--bg:#eef0f1;--card:#ffffff;--fg:#101418;--muted:#5d6871;--line:#d0d5d9;--accent:#2b63c6;--font:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0f1316;--card:#21262b;--fg:#eef0ee;--muted:#99a1a6;--line:#353c42;--accent:#6da7ec;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0f1316;--card:#21262b;--fg:#eef0ee;--muted:#99a1a6;--line:#353c42;--accent:#6da7ec;color-scheme:dark}
*{box-sizing:border-box} body{background:var(--bg);color:var(--fg);font:13px/1.4 var(--font);padding-block:20px;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}
header{max-width:1240px;margin:0 auto 14px} header h1{font-size:18px;margin:0;text-wrap:balance} header p{margin:4px 0 0;color:var(--muted);max-width:70ch}
.wrap{display:grid;grid-template-columns:250px minmax(0,1fr);gap:16px;max-width:1240px;margin:0 auto}
@media (max-width:820px){.wrap{grid-template-columns:minmax(0,1fr)}}
.list{display:flex;flex-direction:column;gap:4px;min-width:0}
.item{all:unset;cursor:pointer;padding:9px 11px;border-radius:9px;border:1px solid transparent}
.item:hover{border-color:var(--line)} .item:focus-visible{outline:2px solid var(--accent)} .item.on{border-color:var(--line);background:var(--card)}
.item b{display:block;font-weight:600;font-size:13px} .item span{color:var(--muted);font-size:11.5px}
.bar{display:flex;gap:8px;align-items:center;margin:0 0 8px;flex-wrap:wrap;color:var(--muted);font-size:12px}
.bar button{all:unset;cursor:pointer;border:1px solid var(--line);border-radius:6px;padding:2px 9px;font-size:12px;color:var(--fg)}
.bar button:focus-visible{outline:2px solid var(--accent)}
.bar button.on{background:var(--fg);color:var(--bg)}
iframe{width:100%;border:0;height:640px;display:block;border-radius:12px;background:var(--bg)}
pre{white-space:pre-wrap;font:11px/1.45 var(--mono);max-height:340px;overflow:auto;border:1px solid var(--line);border-radius:9px;padding:12px;margin-top:10px;background:var(--card)}
</style>
<header><h1>Explainer Dock</h1><p>Eight real moments: you asked an agent to explain, it answered, and Opus 5.5 turned that answer into a motion explainer. Drafts are previews it rendered and then corrected. "Before" is the earlier run that had only the question. "What went in" is the exact input.</p></header>
<div class="wrap"><div class="list" id="list"></div><div style="min-width:0">
<div class="bar" id="bar"></div><iframe id="f" title="Explainer player"></iframe><pre id="input" hidden></pre></div></div>
<script>
const LIBS=__LIBSJSON__, PLAYER=__PLAYERJSON__, ITEMS=__ITEMSJSON__;
const f=document.getElementById('f'), bar=document.getElementById('bar'), list=document.getElementById('list'), inp=document.getElementById('input');
let cur=0;
const theme=()=>document.documentElement.getAttribute('data-theme');
f.onload=()=>{try{f.style.height=f.contentDocument.documentElement.scrollHeight+'px'}catch(e){}};
function load(i,v){cur=i;const it=ITEMS[i];v=v??it.versions.length-1;const all=it.before?[...it.versions,it.before]:it.versions;
  let doc=PLAYER.replace('__LIBS__',()=>LIBS);if(theme())doc=doc.replace('<html lang="en">','<html lang="en" data-theme="'+theme()+'">');f.srcdoc=doc.replace('__LIBS__',()=>LIBS).replace('ASK_JSON',()=>JSON.stringify(it.ask)).replace('__CODE__',()=>all[v]);
  [...list.children].forEach((b,k)=>b.classList.toggle('on',k===i));
  bar.innerHTML=all.map((_,k)=>`<button data-v="${k}" class="${k===v?'on':''}">${k===it.versions.length?'before (no answer)':k===it.versions.length-1?'final':'draft '+(k+1)}</button>`).join('')
    +`<span>${it.secs}s · $${(it.cost||0).toFixed(2)}</span><button data-in>What went in</button>`;
  bar.querySelectorAll('[data-v]').forEach(b=>b.onclick=()=>load(i,+b.dataset.v));
  bar.querySelector('[data-in]').onclick=()=>{inp.hidden=!inp.hidden};
  inp.textContent=it.input;}
ITEMS.forEach((it,i)=>{const b=document.createElement('button');b.className='item';b.innerHTML=`<b></b><span></span>`;
  b.querySelector('b').textContent=it.title;b.querySelector('span').textContent=it.project+' · '+it.ask.slice(0,60)+(it.ask.length>60?'…':'');
  b.onclick=()=>load(i);list.appendChild(b)});
load(0);
</script>"""
page = page.replace("__LIBSJSON__", json.dumps(libs).replace("</", "<\\/")).replace("__PLAYERJSON__", json.dumps(player).replace("</", "<\\/")) \
           .replace("__ITEMSJSON__", json.dumps(items).replace("</", "<\\/"))
(HERE / "explainer-dock.html").write_text(page)
print(len(items), "explainers,", len(page) // 1024, "KB")
