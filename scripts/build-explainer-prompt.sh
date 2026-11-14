#!/bin/bash
# Builds the Show me creator's instructions, Resources/Explainer/CLAUDE.md, from the prompt source and its worked example:
# docs/design/router-visuals/explainer/system.src.md with its `{{EXAMPLE}}` line replaced by examples/lastdrop.js.
# The built file is committed, so a plain `swift build` has it; ExplainerProjectTests.promptIsBuilt fails when it's stale.
set -euo pipefail
cd "$(dirname "$0")/.."
EX=docs/design/router-visuals/explainer
OUT=Resources/Explainer/CLAUDE.md
[ "$(grep -c '^{{EXAMPLE}}$' "$EX/system.src.md")" = "1" ] || { echo "$EX/system.src.md needs one {{EXAMPLE}} line" >&2; exit 1; }
{
  sed '/^{{EXAMPLE}}$/,$d' "$EX/system.src.md"
  cat "$EX/examples/lastdrop.js"
  sed '1,/^{{EXAMPLE}}$/d' "$EX/system.src.md"
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "Built $OUT"
