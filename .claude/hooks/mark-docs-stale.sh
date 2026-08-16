#!/usr/bin/env bash
# PostToolUse hook — records source files Claude edits so the Stop hook can ask for
# a CLAUDE.md / docs/ reconciliation before the turn ends.
#
# Reads the tool payload as JSON on stdin. Always exits 0: this hook must never
# block or fail a tool call.
set -uo pipefail

payload=$(cat)

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)
[ -n "$file" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
rel="${file#"$root"/}"

# Only source changes need a doc pass. Editing the docs themselves must not re-arm
# the reminder, or the turn can never end cleanly.
case "$rel" in
  lib/*.dart | pubspec.yaml | packages/*/lib/*.dart | packages/*/lib/*/*.dart) ;;
  *) exit 0 ;;
esac

session=$(printf '%s' "$payload" | jq -r '.session_id // "default"' 2>/dev/null)
state="$root/.claude/.docs-stale-${session:-default}"

mkdir -p "$root/.claude" 2>/dev/null || exit 0
grep -qxF "$rel" "$state" 2>/dev/null || printf '%s\n' "$rel" >>"$state" 2>/dev/null

exit 0
