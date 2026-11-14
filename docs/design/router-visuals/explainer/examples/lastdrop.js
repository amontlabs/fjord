explainer({
  title: "Why the transcript appeared",
  answer: "lastdrop ran the first 74 minutes; a mid-run steer hid its tag, so plain Opus took over.",
  scenes: [
    { caption: "lastdrop runs the child. The thread shows only Thinking.",
      source: "the thread showed only the \"Thinking\" step with its progress lines" },
    { caption: "The orchestrator steers while that turn is still running.",
      source: "The steer interrupted the turn, which wrote no assistant message" },
    { caption: "Task and steer probably merge. The tag is no longer last.",
      source: "only finds the tag when the text *ends* with it" },
    { caption: "lastdrop lets go. Opus runs natively: the full transcript you saw.",
      source: "every tool call written to the thread. That's the full transcript you saw" },
    { caption: "It looked right, but Opus started blind: a bug.",
      source: "The native model never saw the 74 minutes of work the runner had done" },
  ],
  build(K, tl, scene) {
    // The cast, laid out once as one world. The camera does the travelling.
    const task = K.chip(136, 250, "task", { tone: "ink", icon: "file" });
    const tag = K.chip(262, 250, "build-hard", { icon: "tag" });
    const msg = K.region({ x: 250, y: 238, w: 410, h: 124 }, "first message", { icon: "message" });
    const orch = K.actor(250, 500, "agent", "Orchestrator");
    const runner = K.card(650, 170, "lastdrop runner", { sub: "build-hard route", icon: "route", tone: "accent" });
    const opus = K.card(650, 500, "Opus, natively", { sub: "the child's own account", icon: "model" });
    const thread = K.window(1050, 335, "T3 thread", { w: 330, h: 290, icon: "thread" });   // h keeps room for the rows of scene 4
    const thinking = thread.row("Thinking", { icon: "brain", muted: true, meta: "···" });
    const toRunner = K.link(msg, runner, { tone: "accent" });
    const toOpus = K.link(msg, opus, { tone: "accent" });
    const runnerOut = K.link(runner, thinking, { tone: "accent" });

    // 1. lastdrop runs the child. Open close on the message, then pull back to the whole route.
    //    Hero: traffic streaming into the thread while the minutes tick.
    scene(0);
    const clock = K.badge(runner, "0 min", { tone: "accent", icon: "clock" });
    K.camera([msg, runner], { dur: 0 });
    K.appear([msg, task, tag], { stagger: 0.1 });
    K.appear(runner, { at: "<0.3" });
    K.draw(toRunner, { at: "<0.3" });
    K.flow(toRunner);
    K.camera(null, { at: "<0.2" });
    K.appear([opus, thread], { at: "<0.3" });
    K.dim(opus, { to: 0.45, at: ">" });
    K.draw(runnerOut, { at: "<" });
    K.flow(runnerOut);
    K.appear(thinking, { at: "<0.4" });
    K.appear(clock, { from: "pop", at: "<" });
    K.count(clock, 0, 74, { suffix: " min", dur: 1.8, at: "<0.1" });

    // 2. a steer arrives mid-run. Hero: the chip parks after the tag and the runner turns amber.
    scene(1);
    const steer = K.chip(250, 418, "steer", { tone: "warn", icon: "send" });
    K.camera({ x: 400, y: 340 }, { zoom: 1.35 });          // the left two thirds: message, orchestrator, runner
    K.appear(orch, { at: "<0.3" });
    K.appear(steer, { from: "pop", at: ">-0.2" });
    K.dock(steer, tag, { side: "right", dur: 0.8 });
    K.recolor([runner, clock], "warn", { at: "<0.5" });
    K.relabel(clock, "interrupted", { at: "<" });
    K.pulse(runner, { tone: "warn", at: "<" });

    // 3. they merge; the tag isn't last anymore. Push in; hero: the spotlight on the last two chips.
    scene(2);
    const verdict = K.badge(msg, "ends with the tag? no", { tone: "bad", side: "bottom", icon: "cross" });
    K.camera(msg, { pad: 130 });
    K.relabel(msg, "probably merged", { color: "warn", at: "<0.5" });
    K.recolor(msg, "warn", { at: "<" });
    K.spotlight([tag, steer], { at: ">" });
    K.pulse(steer, { tone: "warn", at: "<0.2" });
    K.spotlight(null, { at: ">0.5" });
    K.appear(verdict, { from: "above", at: "<0.1" });

    // 4. the route switches. Hero: the old link breaks, the work lands on Opus, tool calls fill the thread.
    scene(3);
    const work = K.chip(0, 0, "task + steer", { size: 15, icon: "message" });
    const calls = ["Read register.tsx", "Edit register.tsx", "Bash swift test", "Edit register.tsx"]
      .map(s => thread.row(s, { mono: true, icon: s.startsWith("Bash") ? "command" : "code" }));
    const opusOut = K.link(opus, calls[3], { tone: "accent" });
    K.camera(null);
    K.hide([orch, verdict], { at: "<" });
    K.cut(toRunner, { at: "<0.5" });
    K.dim([runner, runnerOut, clock], { at: "<0.1" });
    K.dim(opus, { to: 1, at: "<" });
    K.draw(toOpus, { at: "<0.2" });
    K.travel(work, toOpus, { at: ">-0.3" });
    K.glow(opus, { at: ">-0.15" });
    K.draw(opusOut, { at: "<0.1" });
    K.flow([toOpus, opusOut]);
    K.appear(calls, { stagger: 0.2, at: "<0.3" });

    // 5. it looked normal, but Opus never got the 74 minutes. Hero: the number.
    scene(4);
    const blind = K.link(runner, opus, { dashed: true, tone: "bad", label: "never handed over" });
    const lost = K.big(270, 470, "74 min", { tone: "bad", sub: "of work Opus never saw" });
    K.dim([runner, clock], { to: 1 });
    K.spotlight([runner, opus, blind], { at: "<" });
    K.draw(blind, { at: "<0.3" });
    K.appear(lost, { at: "<0.3" });
    K.count(lost, 0, 74, { suffix: " min", dur: 1.2, at: "<" });
    K.appear(K.mark(opus, "bad"), { from: "pop", at: ">-0.4" });
  },
});
