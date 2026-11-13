# Router v2: four ways to use a wide window (2026-11-13)

The first wide layout was turned down: the column grew to 1120 pt, so the ages sat far from their words, the names
far from their content, and a thread's own sentence had a quote-like rail. The owner asked for options that use the
width and save the rows that thread names take, without stretching the reading column. That layout is removed: the
real page keeps its 720 column at any width (shot `v2-items-1600`) until one of these is chosen.

Four options are built as real components on the page's own records, bar, dock, cards and peeks. They are behind a
demo-only switch and the real page is unchanged.

```sh
swift build
.build/debug/Fjord --window-shots .build/shots-lab v2-wide-                                 # 16 shots, light and dark
FJORD_WIDE=a .build/debug/Fjord --window-shots .build/shots-lab-a v2-items                   # any shot in one option
```

Shots: `window-v2-wide-<a|b|c|d>[-card][-dark].png`, at 1600 × 1000, on `RouterDemo.items`; `-card` has Checkpoint
boot's Decide open. Code: `RouterLab.swift` (the switch, each option's columns, the pane, the board's second column,
the ledger) and `RouterLabRows.swift` (the rows).

In every option: no rail by a thread's own words, the reading column is 720 pt at most, and the line, hover and card
layers and the Surfaces rules are the page's.

## A. Margin notes

- **Idea.** The 720 column stays where it is. Each thread's name hangs in a margin left of it, right-aligned so it ends
  22 pt from its first row, with its project before it. The column is only rows: a mark, the words, and the age right
  after the last word. A thread's own sentence is its first row (the working dots or Done's check as its mark).
- **Gains.** No row is spent on a name: Needs you takes about 390 pt instead of 530, and the whole demo page fits in about
  750 pt (920 today). Names and ages are both beside the words they belong to. Marks line up in one column, so states read
  down it. A card opens in the column, on its row, with the page's own geometry. It works from a 1200 pt window (the
  margin narrows to 150 and the column moves right); below that the page is today's.
- **Costs.** Ages no longer form a column, so comparing waits takes more reading. A name longer than the margin wraps
  to two lines, and T3's raw title is cut there until the model names the thread. The name loses its mark (the row has
  it), which is a small change to the approved name.

## B. List and pane

- **Idea.** The list as it is today, in a 600 column on the left with the composer under it. The selected row's card
  opens in a pane on the right (440 to 620 pt) that starts level with the list's first line: the line, the thread's own
  words, the open item's sentence, then the card.
- **Gains.** A card never pushes the list, so ↑↓ keeps every row where it was, and a long card (a plan, a history) has
  the page's height. The rows are exactly the approved ones.
- **Costs.** No rows are saved: names keep their own row, and the list is as tall as today (about 920 pt). With nothing
  selected the right half is empty. The eye travels from the row to the pane and back to the composer. It needs about
  1400 pt of window; below that the page is today's.

## C. Board

- **Idea.** Needs you keeps the reading column, as it is today. Done and Working move to a 340 pt column beside it,
  each thread as its name line with its sentence wrapped under it; the housekeeping line ends that column.
- **Gains.** What asks something of you is never pushed down or scrolled away by what is only running, and the page
  fits in about 640 pt. The Needs you rows are exactly the approved ones.
- **Costs.** No name rows are saved in Needs you (about 530 pt, as today). Two columns to scan, and a line that changes
  section would cross between them. A card opened in the second column is narrow. It needs about 1300 pt of window
  (the reading column narrows to 600 there, and is 720 from about 1420).

## D. Ledger by project

- **Idea.** A's rows, grouped by project instead of by state: the project once in a rail on the far left with what it
  has in each state under it, then the names' margin, then the column. No section headers; the colours and marks say
  the state, and the bar's tokens still filter by it.
- **Gains.** The densest: the page fits in about 700 pt. One project's threads read together, which suits working on one
  project at a time, and no row repeats its project.
- **Costs.** It undoes the grouping by state approved on 2026-11-12: Needs you is no longer one list at the top, and a
  thread that needs you can sit below running ones of another project. Three columns of labels before the words.

## Recommendation

**A, margin notes.** It is the only option that answers all three remarks directly: the column does not grow, ages and
names sit against their words, and the name rows are gone. It keeps the sections, the card in place and every approved
rule but the mark inside the name, and it holds from a 1200 pt window, so most windows would get it.

What I would take from the others, later and only if needed:

- From C, the second column for Done and Working, added to A once the window is about 1700 pt wide. It keeps Needs you
  on screen when many threads run.
- From D, the grouping as a choice in the filter bar rather than the page's default.
- B only if cards grow long enough that pushing the list becomes the main complaint. It saves no rows.

## What the demo components leave out

They are looks to choose from. Rows are placed at once, with no glides, sheen or streaming words. A split message's
pending lines and ghost rows are not drawn, and a selection is not scrolled into view. Clicks, hover, peeks, picks, the
dock and the filters work. Building the chosen one for real means giving its rows the page's hosted lines and glides,
and deleting the other options.
