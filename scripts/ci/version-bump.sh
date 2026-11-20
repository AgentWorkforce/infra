#!/usr/bin/env bash
# Fail when a chart changed against the base ref without a Chart.yaml version
# bump. chart-releaser only publishes on a version change, so an unbumped edit
# would silently never ship.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:-origin/main}
fail=0
for chart in $(git diff --name-only "$base"...HEAD -- charts/ | cut -d/ -f2 | sort -u); do
  [ -f "charts/$chart/Chart.yaml" ] || continue  # chart removed
  # Changes confined to ci/ test values, or to top-level Markdown docs
  # (README.md, UPSTREAM.md, ...), change no rendered output and need no bump;
  # the docs ship with the chart's next version.
  git diff --name-only "$base"...HEAD -- "charts/$chart" \
    | grep -v "^charts/$chart/ci/" | grep -qv "^charts/$chart/[^/]*\.md$" || continue
  new=$(sed -n 's/^version: *//p' "charts/$chart/Chart.yaml" | tr -d '"')
  old=$(git show "$base:charts/$chart/Chart.yaml" 2>/dev/null | sed -n 's/^version: *//p' | tr -d '"' || true)
  if [ -n "$old" ] && [ "$old" = "$new" ]; then
    echo "::error::$chart changed but its version is still $new; bump charts/$chart/Chart.yaml"
    fail=1
  elif [ -n "$old" ] && [ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -1)" != "$new" ]; then
    # A lower version may already be released; chart-releaser (skip_existing)
    # would then silently skip the change.
    echo "::error::$chart version went backwards ($old -> $new); it must increase"
    fail=1
  elif git tag -l "$chart-$new" | grep -q .; then
    echo "::error::$chart $new is already released (tag $chart-$new); pick a new version"
    fail=1
  else
    echo "$chart: ${old:-new} -> $new"
  fi
done
exit $fail
