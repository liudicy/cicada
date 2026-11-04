#!/usr/bin/env bash
# Merges the latest upstream (wquguru/cicada) into this fork's main, keeping the
# fork's own commits on top. Run on main:  scripts/sync-upstream.sh
#
# The fork's rule for conflicts:
#   - Where upstream now ships the same feature the fork added, take upstream's
#     version:  git checkout --theirs -- <file>
#   - Everywhere else, keep the fork's behaviour and merge by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

branch=$(git rev-parse --abbrev-ref HEAD)
[[ "$branch" == "main" ]] || { echo "Run this on main (currently on $branch)." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean." >&2; exit 1; }

git fetch upstream
if git merge-base --is-ancestor upstream/main HEAD; then
  echo "Already up to date with upstream."
  exit 0
fi
echo "Merging upstream/main ($(git rev-parse --short upstream/main)) into main…"
if git merge --no-edit upstream/main; then
  echo "Merged cleanly. Review, run scripts/test.sh, then: git push origin main"
else
  cat <<'EOF'
Merge stopped on conflicts. Resolve them with the fork's rule:
  - Upstream already ships this feature → take upstream:  git checkout --theirs -- <file>
  - Anything else → keep the fork's behaviour, merge by hand.
Then:  git add -A && git merge --continue && scripts/test.sh && git push origin main
EOF
  exit 1
fi
