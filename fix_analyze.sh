#!/usr/bin/env bash
set -euo pipefail

# This script fixes the flutter analyze failure WITHOUT needing flutter/dart
# installed locally. It just edits the two files with unused imports (the
# actual cause of "Process completed with exit code 1"), then commits and
# pushes so GitHub Actions can re-run the build.
#
# The 5 "info"-level prefer_const_constructors suggestions are NOT fatal on
# their own (only warnings/errors fail flutter analyze by default), so they
# are left alone here to avoid risky blind text edits to your widget code.

fix_unused_import() {
  local file="$1"
  local line_no="$2"
  local expected_pattern="$3"

  if [ ! -f "$file" ]; then
    echo "❌ File not found: $file (are you running this from the repo root?)"
    exit 1
  fi

  local actual_line
  actual_line=$(sed -n "${line_no}p" "$file")

  if [[ "$actual_line" == *"$expected_pattern"* ]]; then
    echo "==> Removing unused import from $file (line $line_no):"
    echo "      $actual_line"
    sed -i "${line_no}d" "$file"
  else
    echo "⚠️  Line $line_no in $file doesn't look like the expected unused import."
    echo "    Expected line to contain: $expected_pattern"
    echo "    Actual line found:        $actual_line"
    echo "    Skipping this file — please remove the unused import manually."
  fi
}

echo "==> Fixing flutter analyze unused_import warnings..."
fix_unused_import "lib/core/router/app_router.dart" 1 "package:flutter/material.dart"
fix_unused_import "lib/main.dart" 3 "package:go_router/go_router.dart"

echo ""
echo "==> Staging and committing changes..."
git add -A

if git diff --cached --quiet; then
  echo "No changes to commit — nothing was modified (check warnings above)."
else
  git commit -m "fix: remove unused imports flagged by flutter analyze"
  echo "==> Pushing to remote..."
  git push
  echo "✅ Done — pushed fix commit. Check the Actions tab for the new run."
fi
