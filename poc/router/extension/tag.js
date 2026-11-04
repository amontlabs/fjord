// Runs before the page: the app drops the address's `#fjord` as it loads, so a restored tab would no longer know it is Fjord's.
globalThis.__fjordTagged = location.hash === "#fjord";
