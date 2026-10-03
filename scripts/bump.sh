#!/usr/bin/env bash
# Cuts a release: next version from the commits (cocogitto), CHANGELOG.md regenerated, signed commit and tag.
# Pushing the tag runs the release workflow. Usage: scripts/bump.sh [--push]
set -euo pipefail

readonly HEADER='# Changelog

All notable changes to Tickler, generated from the commits by [cocogitto](https://github.com/cocogitto/cocogitto).

- - -
'

cd "$(git rev-parse --show-toplevel)"
[[ "$(git branch --show-current)" == "main" ]] || { echo "release from main only" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is not clean" >&2; exit 1; }
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main differs from origin/main" >&2; exit 1; }
cog check --from-latest-tag

version="$(cog bump --auto --dry-run)"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "nothing to release: $version" >&2; exit 1; }

# `tickler version`, the app's About and the release zip all read these two.
sed -i '' -E "s/static let version = \"[^\"]+\"/static let version = \"${version#v}\"/" Sources/TicklerCore/Version.swift
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"${version#v}\"/" project.yml
git diff --quiet Sources/TicklerCore/Version.swift && { echo "Version.swift not updated" >&2; exit 1; }

# The changelog is generated with the tag in place, then the tag moves to the commit that carries it.
git -c tag.gpgsign=false tag "$version"
# cat -s squeezes the blank runs cog leaves; $() drops the trailing ones.
printf '%s\n' "$({ printf '%s\n' "$HEADER"; cog changelog; } | cat -s)" > CHANGELOG.md
git tag -d "$version" > /dev/null
git add CHANGELOG.md Sources/TicklerCore/Version.swift project.yml
git commit --quiet -S -m "chore(release): ${version}"
git tag -s "$version" -m "$version"
echo "Tagged ${version}: $(git log -1 --format='%h %G?')"

if [[ "${1:-}" == "--push" ]]; then
    git push --quiet origin main "$version"
    echo "Pushed main and ${version}: the release workflow builds and publishes it."
else
    echo "Review CHANGELOG.md, then: git push origin main ${version}"
fi
