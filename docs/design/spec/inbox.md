# Inbox: categories of things

Agreed with the user (2026-10-10). Replaces Needs you / Bots / Done tabs and the Repositories page entirely; no migration, delete what's obsolete.

## Shape
- The bar's inbox cell is the GitHub mark (not the tray icon).
- Categories are user-made, plus two built-ins: **Done** (always there, not a category, special) and **CI** (default, deletable? no: default, can be hidden).
- Each category: name, SF Symbol (preselected by Jev from the name as you type), color (CategoryColor), rules, notifies (native notifications on/off), hidden.
- Each visible category (not Done) has its own icon in the bar with a notification dot/count when something arrives; clicking opens it.
- Categories are drag-reorderable; order = priority (first match wins).
- Show/hide categories like showing/hiding table columns (a checkmark menu). Hidden = muted (no notifications, no bar icon) but still collects; the menu shows its count.
- ⌃1…9 jumps to category N in order.
- Category pill/dot styling shared with the Router's dots and badges.

## Rules
A category is a list of rules; a thing is in it if any rule matches. A rule:

```
[PRs] by [me] in [Contributing]   (+ to, + in … added with +; unset slot = any, not shown)
when [any ▾ | all] of:
  • condition chip
  • condition chip
```
No conditions = every open thing in scope.

### Kinds and what they offer (menus only offer these)
- **PRs** — slots: by · to (menu on the word: assigned / review requested / mentioned) · in.
  Activity (new since you last marked it done, unless it says otherwise, see **Since**): new comment by · new review by · new commits by · mentions.
  Conversation: last comment by (Conversation tab; reviews with text count; inline threads don't) · unresolved threads started by · last reply by (both optional).
  Review (each reviewer's latest review): approved by · changes requested by.
  Checks: checks failing / pending / passing · has conflicts · behind base branch (GitHub's mergeStateStatus BEHIND; it is only reported when the base branch's protection requires branches to be up to date, which the tooltip says). Fact key `behind:<head sha>` (the PR's updatedAt when the sha is unknown), so pushing and falling behind again is new.
  Status: is draft / ready / merged / closed · labeled · no activity for N days.
  Signals: Greptile score below N (read from `<!-- greptile_confidence_score:N -->` in the PR body; Greptile edits it each review; account is `greptile-apps[bot]`).
- **Issues** — slots: by · to (assigned / mentioned) · in. Activity: new comment by · mentions. Conversation: last comment by. Status: is closed · labeled · no activity for N days.
- **Workflows** — slots: in (required) · on branch (default: repo's default branch) · named. Status: is failing / passing / running.
  CI category = `Workflows in [repos] when is failing`; its editor only takes repos.

### Values
- People: me · @login (autocomplete; @greptile → greptile-apps[bot]) · user groups · **Maintainers** (GitHub authorAssociation OWNER/MEMBER/COLLABORATOR on that repo) · **Bots** (accounts GitHub marks as bots) · `except …`.
- Repos: owner/repo · owner/* · user groups · **Repos I own** · **Repos I contribute to** (repos with a merged or an open PR of yours; the set only grows, like before) · **anywhere you're involved** (PRs/issues only: author, assignee, requested reviewer, mentioned, commented — GitHub's `involves:`) · `except …`.
- Teams (only in `to`, PRs, with review requested): `@org/team` (a team asked to review; typed or picked from teams seen on fetched PRs and yours) and **My teams** (every team you're in: GraphQL `viewer.organizations.teams(userLogins:[me])`, needs the read:org scope, kept like owned/contributed repos and asked again daily; without it you're in none). Search side: `team-review-requested:org/team`; a rule naming only teams, none known yet, searches nothing. Teams in `by`, in a condition's people, in an issue's `to`, or with only assigned/mentioned are flagged red.
- Other: labels, branches, workflow names, N days, score 1–5 — autocompleted from repos in scope.
- Groups: named people or repo lists, usable as one chip in any slot of their kind; editing a group updates every rule. Created in a Groups section or inline ("Save as group…" from selected chips).

### Since (activity conditions)
New comment, new review, new commits and mentions count events after a point, set by an optional trailing chip (a dashed `+ since` on the row when it is the default, which is not shown):
- **since Done** (default): after the later of the rule's creation and the thing's last Done.
- **since my last review** (PRs): after your latest review on the thing (a review of any state, or a review with text). If you never reviewed it, the condition does not match (there is no point to count from). Done and the rule's creation don't move this point; Done still holds the facts it acknowledged.
- **since my last comment**: after your latest conversation comment, review with text, or thread reply. If you never commented, from the thing's creation.
Fact keys are the same whatever `since` says (`comment:<id>`, `review:<id>`, `commit:<oid>`, `mention:<id>`), so a fact notifies once and Done holds it however it came. Rules saved before `since` existed have none and read as since Done. A commit counts by when it came to the PR: one first seen on a PR read before without it (pushed later than it was made) counts from then; what a PR has when it is first read counts by its commit date. Since your last review, the commit it was made on and those before it are never new, though first seen after it (pushed and reviewed while Lookout was closed). Issues have no reviews: `since my last review` is flagged there and not offered.

### Jev's labels (emphasis, never filtering)
With a TypeSafe key and Settings' "Let Jev label new comments" on, each refresh asks Jev, in one batched call (others' text fenced as data), for one label per new message (comment, review's words, thread reply; not yours, from the last two weeks), a single choice: **asks** (a question or a decision for you), **todo** (a change or action from you: rebase, fix, address a review, resolve a conflict), **fyi** (nothing to do), **noise** (thanks, +1, an acknowledgement, bot chatter). Below 0.6 for his pick, no label (read, not asked again). Each review request to you or your teams, and each assignment, is rated low / normal / high / urgent.
- Labels and ratings never decide what is in a category or what notifies: only your rules do. Nothing waits for Jev, and nothing he says holds a banner back.
- **Rows**: a tag on the second line for the label that stands out most among the row's facts' messages (asks > todo > fyi > noise): *Asks you* (accent), *To do* (warning), *FYI* (plain), *Noise* (muted); *Important* (warning) or *Urgent* (danger) for a request rated high or urgent. A row whose every fact is about a noise-labeled message keeps a secondary title even unread, and a fact chip about one is muted. Within a category, a higher rating sorts first.
- **Rule conditions** (yours to add; no default category uses them): *new comment labeled* any of asks / to do / FYI / noise (`commentLabel`; asks and to do count only after your latest word there, the others since Done; fact keys `asks:`, `todo:`, `fyi:`, `noise:` + the message id); *new comment is noise, or from a person* (`noise`; before Jev reads it, or without him, a bot's is noise); *rated at least* (`importance`). What a rule matches as noise (`noise:` facts) is noted, never announced. A rule saved with *a comment asks me* (`asksMe`) reads as labeled asks or to do; signals saved as two readings read asks me → asks, noise → noise, neither → fyi.

### Review requests are facts
`to … (review requested)` yields a fact per matching request, keyed `requested:<reviewer>:<time of the request>` (the latest `ReviewRequestedEvent` for that reviewer, from `timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 5)`; the PR's creation when none is in those five). Review again, get asked again: a new request is a new fact, so it notifies again and returns a Done thing. A rule without conditions shows this fact instead of the neutral `open`; with conditions, the request is added to the facts once the conditions match. Label: `review requested`, or `review requested from @org/team`.

### Impossible combinations
- Never-matching values aren't offered: with `by me` → no "to me (review requested)", no "approved by me", no "changes requested by me".
- With `all of`, mutually exclusive values disappear (draft vs merged, failing vs passing).
- A value can't be both included and excepted in one slot.
- An edit that makes an existing chip impossible turns it red with the reason; can't save until fixed. Never silently greyed out.
- Switching kind keeps only supported chips and says which were dropped.

## Lifecycle (same for every kind)
- **Notify** when a thing gains a matching fact; the same fact (Fact.key) never notifies twice. CI: one notification per failure, until green. What notifies is decided only by your rules and the category's notifies switch: a banner never waits for Jev's reading, and nothing he says of a message holds one back (only a rule's own *noise* condition makes its facts noted, never announced).
- **Done** acknowledges the current facts; the item returns only when a new fact matches.
- **Leaves** quietly when nothing matches anymore (thread resolved, checks green).
- **Closed/merged** things only show in rules asking for them (is merged / is closed).
- **First match wins** top to bottom (drag order). Unmatched things dropped.
- Activity before the rule was created, or before Done, is old.
- **Rows** show the matched facts as chips in the rule's words: `Greptile 4/5 · 2 unresolved · last comment: @toksdotdev`.
- **Live preview** in the editor: the rule evaluated in memory against already-fetched things, debounced; no API calls. A repo never fetched says "no history yet for owner/repo".

## Fetching
One GraphQL search per refresh for PRs/issues covers every fact (threads + isResolved, comments, latest reviews, statusCheckRollup, mergeable, mergeStateStatus, review requests and when they were made, isDraft, labels, body for Greptile score, authorAssociation, author __typename Bot). Workflows via the existing REST CI code: one list of workflow runs plus the commit's checks and statuses per repo and branch gives one Thing per workflow (`workflow:owner/repo:<workflowId>@branch`, with its own state and failed jobs; external checks and statuses together are one more, `external`), so `named` filters and CI counts and notifies per failing workflow. Polled repos = repos named by rules + CI repos; `involved` uses `involves:@me` search.

## Code map
- `InboxModel.swift` — types (contract). `InboxEngine.swift` — pure matching. `InboxStore.swift` — Store API. `InboxSync.swift` — fetching. `CategoriesView.swift` — editor. Hub* — bar, lists.

## Actions
A category can have a **Then** list (editor, below Rules): actions it runs by itself for a thing in it. No confirmation prompts.
- **Kinds**: *Send to the Router* (a prompt; the Router decides where it goes, among your claude.ai projects), *Comment on GitHub* (PRs and issues), *Re-run failed checks* (PR: failing workflow runs of the head commit; workflow: that workflow's latest failed run; `rerun-failed-jobs`). `{title} {url} {number} {repo} {author}` are filled in a comment. The prompt is written as the Router's composer is: @ inserts a snippet's text or tags a project, a session or a category, and "@this notification" (offered first) stands for the thing; without it, the thing is tagged at the end. The prompt is sent through the Router as yours, from the category ("Contributions · …" in its history), with the thing's pill: what GitHub wrote (title, author, why it is here, failing jobs, last comment) only reaches a model in the thing's fenced block. Saved prompts keep their pills (`prompt` with a mark per pill, `pointers`); one saved before had its placeholders made "this notification" (`{repo}#{number}`, `{url}`, `{title}`) and `{author}` "its author". Saved "start a session" and "Ask the Router" actions read as Send to the Router with the same prompt.
- **Trigger** per action: once per thing when it comes in (default; a thing that left and came back within an hour is the same visit, so a re-run that fails again isn't re-run forever), or on each new fact (one run per sync per thing, covering that sync's new facts).
- **Never old news**: what is in the category when it is created, when its rules change in any way, or when an action is added, is taken as already handled (a baseline, kept across launches). What a change newly asks GitHub for (a repo not read yet) is taken in only once a refresh has read it, and nothing runs until then, a quit and relaunch in between included (what was read, and the wait, are saved with the state). While a search it waits for keeps failing, the inbox's status tooltip says "Actions paused until <repo> can be read". A review request or assignment of yours already there, that Jev rates only later (his reading failed, or waited for his cap), is old news too: what its rating alone brings into the category (its entering, or its importance fact) doesn't run; what came since (a comment after it was taken in) still does, and so does its entering when that brings it in. Done things don't run.
- **Loop guard**: facts made by you (your comments, reviews, commits, replies) never trigger, so an action's own comment can't start another. Each (category, thing, action, trigger key) runs at most once; a failure is not retried. At most 10 runs per refresh; the rest wait ("queued") for the next.
- **Rows** show a ⚡ chip: "sent to <project or thread>" (opens it), "waiting on you in the Router" while the Router asks where its message goes (opens it; it updates once you pick), "commented" (opens the comment), "re-ran 2 jobs", "failed: <reason>" (danger), "queued". Category rows and tabs show a ⚡ when the category has actions.
- **Try on latest match** previews the message as it would be sent and where it could go (the repo's local clones), the comment, or the runs that would be re-run; it does nothing and asks no model.
- Runs are kept in `actions.json` beside the state file. The demo and the playground never do anything. Code: `InboxActions.swift` (planning, ledger, performer), `ActionEditor.swift`.
- The Router is the only bridge to claude.ai, and only while Triage and the Router are both on (else the action is held). The action's message is routed as any message of yours is: a project or thread you tagged goes there with no model, else the project decider (Jev, then Sonnet) picks among your claude.ai projects, or the Router proposes a new project. Unattended, when it isn't sure (or can't be asked) nothing is sent: an ask-back card waits for you. Code: `ActionPrompt.swift`, `RouterDispatcher`.
