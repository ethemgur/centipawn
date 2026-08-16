#!/usr/bin/env bash
# Stop hook — if source files were edited this turn (recorded by
# mark-docs-stale.sh), hand control back to Claude once with a reminder to
# reconcile CLAUDE.md and docs/ before the turn ends.
#
# Fires at most once per turn: the state file is cleared as the block is emitted,
# and a turn that is already a continuation of a Stop block is never re-blocked.
set -uo pipefail

payload=$(cat)

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
session=$(printf '%s' "$payload" | jq -r '.session_id // "default"' 2>/dev/null)
state="$root/.claude/.docs-stale-${session:-default}"

[ -s "$state" ] || exit 0

# Loop guard: this Stop was itself triggered by a previous block.
if [ "$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  rm -f "$state"
  exit 0
fi

files=$(sort -u "$state" | sed 's/^/  - /')
rm -f "$state"

jq -n --arg files "$files" '{
  decision: "block",
  reason: (
    "Documentation upkeep (.claude/hooks/docs-freshness-reminder.sh): you changed these files this turn:\n"
    + $files
    + "\n\nBefore finishing, reconcile the docs with what you just changed:\n"
    + "  1. Re-read the CLAUDE.md section covering the area you touched, and the matching page in docs/\n"
    + "     (architecture.md, evaluation.md, data-model.md, ui-map.md — the mapping table is in\n"
    + "     docs/documentation-maintenance.md).\n"
    + "  2. Fix anything your change made untrue: provider names, method signatures, schema version,\n"
    + "     eval conventions, file layout, dependencies.\n"
    + "  3. If nothing documented changed, say so in one line and finish — do not invent edits.\n\n"
    + "This reminder fires once per turn and has already cleared itself."
  )
}'
