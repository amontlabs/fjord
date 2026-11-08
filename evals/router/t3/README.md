# Refitting the Jev-led path

`Sources/Fjord/RouterJevPath.swift` fuses one Jev call (where the message goes, and two yes/no checks on the 3 latest idle threads) with recency and a BM25 into one probability, using 8 weights fit on E5's 182 moments ([E5](../../../docs/design/t3-research/E5-jev-wrapper.md)). E5 says to refit them on Fjord's own log, because its recency prior was learned on messages typed inside a session, and to keep the path in shadow until about 200 logged decisions show no wrong send.

Every attended decision writes the path's answer to `~/Library/Application Support/Fjord/decider-log.jsonl` (`fused`: every place's features and fused P, Jev's answers, the BM25, the gates; `preview`: what the composer showed and whether it missed). The log holds your words and stays on your Mac.

```sh
python3 evals/router/t3/refit.py                       # the default log
python3 evals/router/t3/refit.py path/to/log.jsonl --bar 0.9 --guard 0.25
```

It needs `numpy` and `scipy`. It prints how the shipped weights did on the log, leave-one-day-out refits (each day scored by weights fit without it), and the refit on everything as a Swift line for `JevPath.weights`. Change the weights only when the leave-one-day-out line keeps 0 wrong sends at the bar. The path is always on (no setting, no shadow mode), so watch the log for wrong sends: about 200 decisions with none is the first check, and certifying 0.5% wrong takes about 600.

Where each message went comes from the log's outcomes: an ask's pick, or a send that was never moved with Send elsewhere. Dismissed asks, answers in Fjord and picks from the preview's menu aren't used for the fit.

# N1: the new-work benchmark from T3 history

[N1](../../../docs/design/t3-research/N1-new-work-benchmark.md). Everything it writes goes to `data/` (gitignored: it holds message text).

```sh
python3 evals/router/t3/extract.py    # T3's statev2.sqlite, read-only -> data/history.json (cut imports filled from their transcripts)
python3 evals/router/t3/moments.py    # moments, boards as they stood, gold, flags, dev/test by day -> data/moments.jsonl
python3 evals/router/t3/purposes.py   # one purpose sentence per project from dev-day titles (then rerun moments.py)
python3 evals/router/t3/judge.py      # Sonnet judge: first messages (continues / same topic / unrelated, owner or agent brief), 80 follow-ups
python3 evals/router/t3/run.py jev    # Jev's fused path as shipped, every moment
python3 evals/router/t3/run.py sonnet # Sonnet as the app calls it: all first messages + 30% of follow-ups
python3 evals/router/t3/score.py      # tables; follow-ups reweighted to the natural ratio, CIs bootstrapped over days
```

`board.py` ports `DeciderBoard`, the Sonnet request and gates, and `JevPath` from the Swift. The test days are sealed: tune on dev only.
