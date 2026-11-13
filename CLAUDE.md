# Fjord: notes for agents

Building, tests and every debug flag: [DEVELOPMENT.md](DEVELOPMENT.md).

## Checking the UI

Don't build the app bundle and launch it to see how something looks. Render it offscreen from the debug binary, on demo data:

```sh
swift build
.build/debug/Fjord --window-shots .build/shots v2-home settings
```

- `--window-shots <dir> [name…]` renders the window's pages (`window-<name>.png`). Given names, it renders only the shots whose names contain one of them. The catalog is in `Sources/Fjord/AppWindowShots.swift`: `v2-home`, `v2-card-plan`, `v2-drawer`, `v2-setup`, `v2-off`, `router-collapsed`, `settings`, `categories`, `category-collapsed`, and more (the Router page's shots are the `v2-` ones, light and dark).
- `--playground-shots <dir> [name…]` renders the bar: every edge, every demo scenario, and the accessibility variants (`right-open`, `top-rest-signed-out`, and so on).
- `FJORD_THEME=dark|light|claude` pins the theme for a run.
- Then read the PNGs. A run takes about 2 s per shot after an incremental `swift build`, with no Dock icon, no focus change and no Keychain prompt.

When the state you need isn't in a catalog, add a shot: a `Shot` with a `compose` closure that sets the state up on `Demo.populate`'s data, or a new `Demo` scenario. That's quicker than reaching the state by driving the live app, and the next agent can reuse it.

Shots can't show:
- Liquid Glass: they always draw the opaque chrome.
- Hover: the bar opening when the pointer reaches it.
- Animation and motion.
- Real interaction: typing, clicks, focus.

Only for those, and only when the user asks for a live check, build the bundle (`./scripts/build-app.sh`) and drive it with LCU. Live runs steal focus and add to the Dock.

## Commits

Every commit message starts with a conventional type and no scope: `feat: `, `fix: `, `perf: `, `refactor: `, `test: `, `docs: `, `build: `, `ci: `, `chore: `, `style: ` or `revert: `, then the usual plain sentence about the result. The Commits workflow fails on a push to main with a commit that doesn't.

## Tests

Run `scripts/test.sh`, or a filtered `swift test --filter <Suite>` while iterating. One run at a time; never run test loads in parallel or in loops.
