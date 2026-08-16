#!/usr/bin/env bash
# Warn when a commit changes source without touching the documentation.
#
#   scripts/check-docs-freshness.sh          # check the staged diff
#   scripts/check-docs-freshness.sh --range origin/main..HEAD
#
# Exits 0 (warning only) unless DOCS_CHECK_STRICT=1, which makes drift fail.
# Install as a pre-commit hook with scripts/install-git-hooks.sh.
set -uo pipefail

range=""
if [ "${1:-}" = "--range" ] && [ -n "${2:-}" ]; then
  range="$2"
fi

if [ -n "$range" ]; then
  changed=$(git diff --name-only --diff-filter=ACMR "$range")
else
  changed=$(git diff --cached --name-only --diff-filter=ACMR)
fi

[ -n "$changed" ] || exit 0

source_changed=$(printf '%s\n' "$changed" | grep -E '^(lib/.*\.dart|pubspec\.yaml|packages/[^/]+/lib/.*\.dart)$' || true)
docs_changed=$(printf '%s\n' "$changed" | grep -E '^(CLAUDE\.md|docs/.*\.md)$' || true)

if [ -z "$source_changed" ] || [ -n "$docs_changed" ]; then
  exit 0
fi

{
  echo
  echo "  Documentation check: source changed, docs did not."
  echo
  printf '%s\n' "$source_changed" | sed 's/^/    /'
  echo
  echo "  If any of this changed documented behaviour — providers, engine API, eval"
  echo "  conventions, schema, models, PGN handling, UI layout, dependencies — update"
  echo "  CLAUDE.md and the matching page under docs/ (see"
  echo "  docs/documentation-maintenance.md), or run /update-docs in Claude Code."
  echo
} >&2

if [ "${DOCS_CHECK_STRICT:-0}" = "1" ]; then
  echo "  DOCS_CHECK_STRICT=1 — failing." >&2
  exit 1
fi

echo "  (warning only — commit continues; --no-verify skips this hook)" >&2
echo >&2
exit 0
