<div align="center">

<img src="docs/assets/icon.png" width="128" height="128" alt="Fjord icon">

# Fjord

**The power without the storm.**

Coding agents multiply what you ship, and what you have to keep up with. Fjord sits between them and everything they work with, and brings you only what you need to know or decide.

[Download](https://github.com/amontlabs/fjord/releases/latest) · [Install](#install) · [Privacy](#privacy) · [Development](DEVELOPMENT.md)

</div>

> [!WARNING]
> Work in progress. Expect rough edges and breaking changes between releases.

<!-- TODO: hero screenshot (the bar at the screen's edge, the window open on the Router).
     Render it with `--window-shots` / `--playground-shots` (see DEVELOPMENT.md), save it as
     docs/screenshots/hero.png, then replace this comment with:
<p align="center"><img src="docs/screenshots/hero.png" width="860" alt="Fjord: the bar at the screen's edge and the window beside it"></p>
-->

Keep the apps you use. Fjord joins GitHub, CI and your Claude Code sessions, passing work between them, while you still see everything and make every call.

## Why Fjord

Several sessions at once are a real boost, and they send a lot back: questions, plans waiting for a yes, sessions finished or stuck, pull requests, red CI, and everything that has to pass between your agents and GitHub.

Fjord takes that on. Questions come to you; a failing check goes, by your rules, to the session that can fix it; the rest stays out of your way. You keep the boost and shed most of its weight.

## How it works

Fjord has two tools, the Router and Triage. Each works alone, and the first launch asks which you want. Both live in a slim bar against any edge of any screen (no Dock icon unless its window is open): hover it to see what's inside, click it to open the window.

### Router: one chat above all your Claude Code sessions

- **See who needs you.** Every session from the Claude desktop app on one page: *Needs you*, *Worth a look*, *Waiting* and *Working*. Each question, plan to approve, finished or stuck session is a card you answer right there; it stays until you do.
- **Type once.** The Router picks the session your message is for and delivers your exact words as your own message. When it isn't sure, it asks *Where should this go?*
- **Change your mind.** Cancel a message, edit and resend it, or fork the session from just before it.
- **Look away.** Working sessions show what they're doing, live, with a summary one click away.
- **Bring things in.** `@` adds a project, a session, a GitHub item or a saved prompt to your message.
- **It only talks.** It never edits files, runs commands or acts on GitHub.

### Triage: your GitHub inbox and CI, sorted by your rules

- **Write rules you can read.** Each is a sentence about pull requests, issues or workflows:
  > PRs by me in *Repos I contribute to*, when any of: new review by *Maintainers*, checks failing
- **Order your categories.** The first that matches keeps the item. You start with *My repos* and add your own.
- **Let a category act.** Comment on GitHub, re-run failed jobs, or, with the Router on, hand the item to a Claude Code session in your clone of the repo.
- **Archive what you've handled.** It comes back only when something new matches.

With both tools on, you can also set up Triage by talking to the Router (*"make a category for PRs by bots"*); each change shows in the Router's history with **Open** and **Revert**.

## Install

1. Download `Fjord-<version>.zip` from [Releases](https://github.com/amontlabs/fjord/releases/latest), unzip it, and move **Fjord.app** to `/Applications`.
2. It isn't notarized yet, so clear the quarantine flag once, in Terminal:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Fjord.app"
   ```
3. Open it and pick your tools.

Requires **macOS 14** or later, Apple silicon or Intel.

| Tool | Also needs |
| --- | --- |
| Triage | GitHub access: `gh auth login`, `GH_TOKEN` / `GITHUB_TOKEN`, or a token pasted in Settings (kept in your Keychain). |
| Router | The [Claude desktop app](https://claude.ai/download). The Router follows sessions started in its Code tab, not `claude` in a terminal. |

Switching the Router on adds a small hook (`~/.claude/hooks/fjord-form.sh`) and the `fjord@fjord` plugin to Claude Code, backing up `~/.claude/settings.json` first; switching it off removes both. The Router reads Claude's local session files, which aren't a public API: if a Claude update changes them, the Router says so, and Triage keeps working.

Updates download in the background and are verified (checksum, and the same signing certificate as your copy); a small restart icon on the bar installs them. Settings → Updates turns the checks off.

## Privacy

Fjord has no server and no account. What leaves your Mac:

- **GitHub**: Triage reads your pull requests, issues and workflows through GitHub's API; updates come from this repo's Releases.
- **Anthropic**: the Router's briefs, summaries and replies are written by Claude Haiku through your own Claude Code, on your account.
- **TypeSafe** *(optional)*: with a [TypeSafe](https://typesafe.ai) API key, its classifier (Jev) helps route your messages, read how each session's turn ended, label new comments (*asks you*, *to do*, *FYI*, *noise*) and pick icons. It receives your messages and drafts, sessions' titles, activity and final messages, project names and, for labels, the comment and its pull request or issue details. Without a key, nothing is sent there.

Everything else stays on your Mac, in `~/Library/Application Support/Fjord/`. Code folders you add in Settings are scanned locally for git clones.

## Keyboard

| Shortcut | Action |
| --- | --- |
| <kbd>⌃⌥L</kbd> | Show or hide the window, from anywhere |
| <kbd>⌃⌥R</kbd> | Open the Router, from anywhere |
| <kbd>Return</kbd> | Open the selected inbox item on GitHub |
| <kbd>⌘↩</kbd> | Open it in the Router |
| <kbd>Space</kbd> | Mark it read or unread (<kbd>⌥Space</kbd>: all read) |
| <kbd>⌫</kbd> | Archive it (<kbd>⌘Z</kbd> undoes it for 30 seconds) |
| <kbd>⌘R</kbd> | Refresh the inbox |

Change any of them in Settings → Shortcuts. <kbd>⌘F</kbd> searches, and <kbd>⌘1</kbd>–<kbd>⌘4</kbd> answer *Where should this go?*

## Development

Building from source, tests, debug flags and releasing: [DEVELOPMENT.md](DEVELOPMENT.md).

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center">Made by <a href="https://amontlabs.com">Amont Labs</a>. All rights reserved.</p>
