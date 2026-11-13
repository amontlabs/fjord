"""44 synthetic drafts in the owner's style for the split eval (no real transcripts): lowercase, short, typos, missing apostrophes.

kind 'split': parts for different places; gold = [(place, the words that belong there)], place a thread id or ("new", project).
kind 'near':  one place only (two things for one thread, one thing in several sentences, a place named in passing): must not split.
kind 'unsure': a split whose part marked `?` is ambiguous between `ok` places: a sure send elsewhere is wrong, asking is fine.
`pills`: item or thread pills in the draft as the Swift pointed block names them [(said, thread, item words or None)]; `answer`:
an answer pill taken out of the words (sent by code), so the decider sees only the rest."""
NEW = lambda p: ("new", p)
S = lambda d, gold, **k: dict(kind="split", draft=d, gold=gold, **k)
Nr = lambda d, place, **k: dict(kind="near", draft=d, gold=[(place, d)], **k)
U = lambda d, gold, ok, **k: dict(kind="unsure", draft=d, gold=gold, ok=ok, **k)

DRAFTS = [
 # splits, two places
 S("one scrolling page. and for the tab handover the spacing is off again", [("t-a1", "one scrolling page"), ("t-b2", "the spacing is off again")]),
 S("ship the trial build to beta. also merge the install guide pr", [("t-c3", "ship the trial build to beta"), ("t-d4", "merge the install guide pr")]),
 S("plan looks good go ahead. new thread in silo: add a quota warning at 90%", [("t-e5", "plan looks good go ahead"), (NEW("silo"), "add a quota warning at 90%")]),
 S("updater: silent, stable channel. disk test: retry it once the vpn is back", [("t-f6", "silent, stable channel"), ("t-g7", "retry it once the vpn is back")]),
 S("tabs across the top. bar count, push it", [("t-a1", "tabs across the top"), ("t-h8", "push it")]),
 S("the guide should mention brave too, not only chrome. and start smth new for fjord: a keyboard shortcut cheatsheet window", [("t-d4", "the guide should mention brave too, not only chrome"), (NEW("fjord"), "a keyboard shortcut cheatsheet window")]),
 S("go with sidebar. snapshot api - owed live tests first, dont ship yet", [("t-a1", "go with sidebar"), ("t-c3", "owed live tests first, dont ship yet")]),
 S("approve the briefs plan but keep the old table for a week. updater ask first", [("t-e5", "approve the briefs plan but keep the old table for a week"), ("t-f6", "ask first")]),
 S("disk test failed again? rerun with the bigger disk. and new lcu thread: record a demo of the approval panel", [("t-g7", "disk test failed again? rerun with the bigger disk"), (NEW("lcu"), "record a demo of the approval panel")]),
 S("bar count is fine merge it. tab handover stop editing the swift file and write the test first", [("t-h8", "bar count is fine merge it"), ("t-b2", "stop editing the swift file and write the test first")]),
 S("one page pls. install guide: add a screenshot of the extension popup", [("t-a1", "one page pls"), ("t-d4", "add a screenshot of the extension popup")]),
 S("new thread docs-site: a changelog page. snapshot api ship it to beta now", [(NEW("docs-site"), "a changelog page"), ("t-c3", "ship it to beta now")]),
 S("for the briefs: yes go. for the settings window: tabs", [("t-e5", "yes go"), ("t-a1", "tabs")]),
 S("updater -> beta channel, silent. bar count -> also count snoozed ones", [("t-f6", "beta channel, silent"), ("t-h8", "also count snoozed ones")]),
 S("thx for the install guide, merge. and the disk test, look at the logs before retrying", [("t-d4", "thx for the install guide, merge"), ("t-g7", "look at the logs before retrying")]),
 S("sidebar with sections. also in silo start a thread to clean up old snapshots older than 30 days", [("t-a1", "sidebar with sections"), (NEW("silo"), "clean up old snapshots older than 30 days")]),
 # splits, three places
 S("tabs. ship the trial build. merge the guide", [("t-a1", "tabs"), ("t-c3", "ship the trial build"), ("t-d4", "merge the guide")]),
 S("briefs plan ok. updater silent. disk test retry", [("t-e5", "briefs plan ok"), ("t-f6", "silent"), ("t-g7", "retry")]),
 S("one scrolling page, tab handover pls add a test for the gap, and new fjord thread: dark mode for the router page", [("t-a1", "one scrolling page"), ("t-b2", "pls add a test for the gap"), (NEW("fjord"), "dark mode for the router page")]),
 S("merge bar count. snapshot api owed live tests. install guide also mention brave", [("t-h8", "merge bar count"), ("t-c3", "owed live tests"), ("t-d4", "also mention brave")]),
 # a shared part
 S("thanks both, ship it — bar count and the install guide", [("t-h8", "thanks both, ship it"), ("t-d4", "thanks both, ship it")]),
 S("good work, merge them: bar count and install guide pr", [("t-h8", "good work, merge them"), ("t-d4", "good work, merge them")]),
 # pills: item or thread pills hint the place
 S("@trial build → ship it. and @Tab handover the gap is still there on retina", [("t-c3", "ship it"), ("t-b2", "the gap is still there on retina")],
   pills=[("@trial build", "t-c3", "trial build"), ("@Tab handover", "t-b2", None)]),
 S("@silent or ask first? silent. @sidebar, one page, or tabs? tabs", [("t-f6", "silent"), ("t-a1", "tabs")],
   pills=[("@silent or ask first?", "t-f6", "silent or ask first?"), ("@sidebar, one page, or tabs?", "t-a1", "sidebar, one page, or tabs?")]),
 S("@Disk test retry. new thread silo: log the vpn drops", [("t-g7", "retry"), (NEW("silo"), "log the vpn drops")],
   pills=[("@Disk test", "t-g7", None)]),
 S("ship it @trial build, and @Bar count merge", [("t-c3", "ship it"), ("t-h8", "merge")],
   pills=[("@trial build", "t-c3", "trial build"), ("@Bar count", "t-h8", None)]),
 # answer pill taken out (sent by code): the rest still splits
 S("also the guide needs brave. and tab handover: write the test first", [("t-d4", "also the guide needs brave"), ("t-b2", "write the test first")],
   answer="Settings layout → one scrolling page"),
 # unsure parts
 U("tabs. and the spacing is off again", [("t-a1", "tabs"), ("t-b2", "the spacing is off again")], ok={"t-b2", "t-a1"}),
 U("ship the trial build. and fix the flaky test", [("t-c3", "ship the trial build"), ("?", "fix the flaky test")], ok={"t-b2", "t-c3", NEW("fjord"), NEW("silo")}),
 U("merge the guide. and someone should look at the vpn thing", [("t-d4", "merge the guide"), ("?", "someone should look at the vpn thing")], ok={"t-g7", NEW("silo"), NEW("lcu")}),
 U("go ahead with the plan. the count is wrong tho", [("t-e5", "go ahead with the plan"), ("?", "the count is wrong tho")], ok={"t-h8", "t-e5"}),
 U("silent. and make it faster", [("t-f6", "silent"), ("?", "make it faster")], ok={"t-f6", "t-b2", "t-g7", NEW("lcu"), NEW("fjord"), NEW("silo")}),
 U("one page. also add a readme section about it", [("t-a1", "one page"), ("?", "also add a readme section about it")], ok={"t-a1", "t-d4", NEW("docs-site"), NEW("fjord")}),
 # near-misses: one place
 Nr("one scrolling page, and keep the sidebar icons in the page headers", "t-a1"),
 Nr("ship the trial build to beta. then write the release notes for it", "t-c3"),
 Nr("merge the install guide pr. also fix the typo in step 3", "t-d4"),
 Nr("the plan is fine. but keep the old table a week, and copy rows in batches", "t-e5"),
 Nr("silent, stable channel. and log every update check", "t-f6"),
 Nr("retry the disk test. if it fails again check the vpn", "t-g7"),
 Nr("the gap is still there. like the settings window had before", "t-b2"),
 Nr("bar count: push it, and make the snapshot count use the same rule", "t-h8"),
 Nr("new thread in fjord: a cheatsheet window. it should list every shortcut, like the install guide does for setup", NEW("fjord")),
 Nr("tabs across the top. same as the briefs window", "t-a1"),
 Nr("ship it, the tab handover can wait", "t-c3"),
]
