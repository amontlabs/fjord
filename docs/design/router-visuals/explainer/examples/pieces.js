// Every piece and motion of the kit in one film: a catalogue to look at, and the kit's smoke test.
explainer({
  title: "The kit's pieces",
  answer: "Every piece and motion in the kit, one scene per family.",
  scenes: [
    { caption: "Actors, cards, chips and a region.", source: null },
    { caption: "A terminal types; a document and a thread fill in.", source: null },
    { caption: "Flow, a cut link, a docked chip, a counter.", source: null },
    { caption: "Spotlight and big type.", source: null },
  ],
  build(K, tl, scene) {
    scene(0);
    const you = K.actor(150, 200, "you", "You", { tone: "you", sub: "asked at 17:49" });
    const agent = K.actor(150, 480, "agent", "Agent", { sub: "claude-opus-5-5" });
    const svc = K.card(520, 200, "Token service", { sub: "refreshes every hour", icon: "key", tone: "warn" });
    const plain = K.card(520, 330, "A plain card");
    const ghost = K.card(520, 480, "Maybe a cache", { sub: "the agent wasn't sure", icon: "database", dashed: true });
    const cloud = K.card(900, 200, "api.anthropic.com", { icon: "cloud", tone: "accent" });
    const chips = [K.chip(840, 330, "token", { tone: "warn", icon: "key" }), K.chip(950, 330, "ok", { tone: "ok", icon: "check" }),
                   K.chip(840, 390, "failed", { tone: "bad" }), K.chip(950, 390, "solid", { solid: true }), K.chip(895, 450, "swift test", { tone: "ink", mono: true })];
    const acct = K.region([svc, plain, ghost], "your Mac", { icon: "laptop" });
    const l1 = K.link(you, svc, { tone: "you", label: "asks" }), l2 = K.link(svc, cloud, { tone: "warn" }), l3 = K.link(agent, ghost, { dashed: true, label: "probably" });
    K.appear([you, agent], { stagger: 0.15 });
    K.appear(acct, { at: "<0.2" });
    K.appear([svc, plain, ghost, cloud], { at: "<0.1" });
    K.draw([l1, l2, l3], { at: "<0.3" });
    K.appear(chips, { from: "pop", stagger: 0.06, at: "<0.2" });
    K.appear(K.badge(svc, "expired", { tone: "bad", icon: "clock" }), { from: "pop" });
    K.appear(K.mark(cloud, "ok"), { from: "pop", at: "<" });
    K.appear(K.icon(1150, 200, "lock", { tone: "ok", size: 40 }), { at: "<" });

    scene(1);
    const all = [you, agent, svc, plain, ghost, cloud, acct, l1, l2, l3, ...chips];
    const term = K.terminal(300, 1000, "zsh · lookout", { w: 480, h: 200 });
    const cmd = term.line("swift test --filter Router"), out1 = term.line("Executed 212 tests", { prompt: false }), out2 = term.line("0 failures", { prompt: false, tone: "ok" });
    const file = K.doc(720, 1000, "register.tsx", { h: 250 });
    const lines = [file.line(), file.line("untag(text)", { tone: "warn" }), file.line(), file.line("return child.run()"), file.line(), file.line()];
    const chat = K.thread(1060, 1000, "Fix tag lookup", { w: 330, h: 300 });
    const says = [chat.say("you", "Why did the transcript show up?"), chat.say("Claude", "The steer hid lastdrop's tag, so plain Opus took over."), chat.say("you", "So it's a bug?")];
    K.camera([term, file, chat], { pad: 50 });
    K.appear([term, file, chat], { stagger: 0.12, at: "<0.5" });
    K.type(cmd);
    K.appear([out1, out2], { stagger: 0.2 });
    K.appear(lines, { stagger: 0.05, at: "<" });
    K.appear(says, { stagger: 0.35, at: "<0.2" });

    scene(2);
    const win = K.window(1750, 330, "Router", { h: 220, icon: "route" });
    const rows = [win.row("Settings layout", { tone: "warn", meta: "25m" }), win.row("Bar count", { icon: "check", muted: true, meta: "50m" }), win.row("Disk test", { tone: "bad", meta: "1h" })];
    const src = K.card(1400, 180, "Runner", { icon: "machine", tone: "accent" }), dead = K.card(1400, 480, "Old route", { icon: "plug" });
    const a = K.link(src, rows[0], { tone: "accent" }), b = K.link(dead, rows[2]);
    const cost = K.chip(1400, 330, "$0", { tone: "ok", icon: "money" });
    const pkt = K.chip(0, 0, "result", { size: 14 }), parked = K.chip(0, 0, "queued", { tone: "warn", size: 14 });
    K.camera([win, src, dead]);
    K.appear([src, dead, win, ...rows], { at: "<0.5" });
    K.draw([a, b]);
    K.flow([a, b]);
    K.travel(pkt, a, { at: "<0.3" });
    K.travel(parked, b, { land: "dock", at: "<0.2" });
    K.cut(b);
    K.appear(cost, { from: "pop", at: "<" });
    K.count(cost, 0, 380, { prefix: "$", at: "<" });
    K.recolor(rows[0], "ok");
    K.relabel(rows[0], "Settings layout: answered", { at: "<" });
    K.glow(src, { tone: "accent", at: "<" });

    scene(3);
    const n = K.big(640, 330, "$380", { sub: "spent before anyone looked" });
    K.camera(null);
    K.spotlight([svc], { at: "<" });
    K.pulse(svc, { tone: "warn" });
    K.spotlight([]);
    K.appear(n, { at: "<0.2" });
    K.count(n, 0, 380, { prefix: "$", at: "<" });
  },
});
