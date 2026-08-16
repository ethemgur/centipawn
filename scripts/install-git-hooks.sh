#!/usr/bin/env bash
# Install scripts/check-docs-freshness.sh as this clone's pre-commit hook.
# Opt-in: git hooks are not shared through the repository.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
hooks_dir=$(git rev-parse --git-path hooks)
target="$hooks_dir/pre-commit"

mkdir -p "$hooks_dir"

if [ -e "$target" ] && ! grep -q 'check-docs-freshness.sh' "$target" 2>/dev/null; then
  echo "A pre-commit hook already exists and is not ours:" >&2
  echo "  $target" >&2
  echo "Add this line to it manually instead:" >&2
  echo '  "$(git rev-parse --show-toplevel)"/scripts/check-docs-freshness.sh' >&2
  exit 1
fi

cat >"$target" <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/install-git-hooks.sh
exec "$(git rev-parse --show-toplevel)"/scripts/check-docs-freshness.sh
HOOK

chmod +x "$target"
chmod +x "$root/scripts/check-docs-freshness.sh"

echo "Installed pre-commit hook: $target"
echo "It warns (never blocks) when lib/ or pubspec.yaml change without a doc update."
echo "Set DOCS_CHECK_STRICT=1 to make it fail instead; git commit --no-verify skips it."
