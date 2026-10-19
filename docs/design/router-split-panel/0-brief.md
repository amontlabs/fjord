You are one of three independent advisors on a design question for Fjord, a macOS app in the repository in your working directory. You have read-only access to this repository: read anything you need (specs, code, git history), but do not modify, create or delete any file, and do not run builds or tests. Do not implement anything. Your deliverable is a design, written as your final answer.

## Brief

**Fjord** is a macOS app where I watch and talk to my Claude Code sessions. Its **Router** is a composer: I write a message, and the Router decides where it goes. That's one of my sessions, a new session in a project, or Fjord itself (changing Fjord's settings, or answering a question about what my sessions are doing). The Router is a dispatcher, not a chat. Read `docs/design/spec/router.md`, "B. You type" and around it. Code: `Sources/Fjord/RouterDispatcher.swift`, `RouterRoute.swift`, `RouterRun.swift`, `RouterPrepare.swift`, `RouterPointer.swift`, `RouterDecisions.swift`, `ClaudePlugin.swift`.

How it works today, in short:
- Deterministic rules first. A reply chip armed on a card, or an @session/@project tag, fixes where it goes.
- Otherwise Jev, a fast calibrated classifier, scores the destinations and answers side questions in the same call (does it answer a waiting card, does it ask for things in several places…). When sure, it acts. When unsure, an ask card lists the top destinations, and nothing is sent until I pick.
- A Haiku run (`claude -p`, typed output, only the tools needed) only for what needs judgment or tools: changing Fjord, questions about state.
- A message reaches a session through Fjord's plugin, signed with a key only Fjord holds. The plugin submits it as my own prompt, so the session sees it exactly as if I'd typed it. Today the Router also never lets a model reword what it sends: a session gets only my own words, with addressing like a leading @project pill removed by fixed rules. One reason is safety: a model rewriting my message reads text I didn't write (session titles, transcripts, PR descriptions), and its output would carry my authority. Another is keeping my intent intact. **This rule is open to discussion.** What I care about is that (1) the message reads as mine, never as relayed from Fjord or another session, and (2) my intent survives, including what's for that session and what isn't.
- Every message is one decision with one destination. The history shows it as one line flying to where it went. Cancel, send elsewhere, edit and resend, and fork are built on that.

**The problem.** I often write one message that concerns several sessions, or several sessions and Fjord. Today that breaks:
- Tagging several sessions doesn't work: the Router picks one of them, or asks me to pick one.
- An untagged message for several places ("tell CI to rerun and tell docs to add the page") goes to a confusing path: Fjord's own run handles any Fjord part, then asks me to send the whole message to one session, or to split it by hand.
- If the Router reads it as one request, the whole thing goes to one session.

Fjord tried splitting once, with a model writing each session's part. It was removed a day later because the parts reworded me (commit e2b3a47).

**What I want.** One message can be meant for several places. Each gets what's meant for it: not a copy of everything, not a mangled version. Parts that are for Fjord itself aren't forwarded. Tags I add (@ tags, the reply chip, and ⌘-clicking several items on the Brief page) should help. It should be reliable, consistent and obvious in hindsight: no pile of special cases, and changing existing structures is fine if it makes the whole simpler.

**What I'm asking.** What's the best design for this, end to end? That covers how the Router decides where things go, how a message gets divided (or doesn't), what each session receives and in what words, what I see and confirm, how it shows in the history, and what to change or remove in what exists. If you think the problem is framed wrong, say so.

## How to answer

Give me your best design for the bigger picture, in your own terms. Specific sub-questions are not the point: you're free to reframe the problem, question how the Router works today, or propose something nobody has thought of. Ground it in what the code and spec actually do (cite files and functions where it matters), and be concrete about the cases that make or break it: several tags, no tags, a message mixing Fjord and sessions, shared context that more than one place needs, pronouns, a reply chip plus a tag, what happens when something fails. Say what you'd remove. Be direct about trade-offs and about what you're unsure of. Aim for something I could read in ten minutes: dense, no padding.
