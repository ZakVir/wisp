#!/bin/bash
# Ship one version end to end: tests → version bump commit → signed release (tools/release.sh --publish: installer
# on the public releases repo + update feed + source tag) → main fast-forwarded to it.
#
# Usage: tools/ship_version.sh <version> <build>      (needs docs/release-notes/<version>.md and a clean tree)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$1; BUILD=$2
[ -f "docs/release-notes/$VERSION.md" ] || { echo "write docs/release-notes/$VERSION.md first"; exit 1; }
# Output captured first: `swift test | grep -q` can die of SIGPIPE under pipefail.
TESTS=$(cd app/Packages/WispKit && swift build >/dev/null && swift test 2>&1 || true)
grep -q "with 0 failures" <<<"$TESTS" && ! grep -q "with [1-9][0-9]* failures" <<<"$TESTS" || { echo "tests failed"; exit 1; }
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" app/project.yml
git add app/project.yml "docs/release-notes/$VERSION.md"
git diff --cached --quiet || git commit -qm "Wisp $VERSION (build $BUILD)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "uncommitted changes"; git status --short; exit 1; }
git push -q origin HEAD
tools/release.sh "$VERSION" "$BUILD" --publish
git push -q origin HEAD:main
echo "shipped $VERSION ($BUILD); main is at $(git rev-parse --short HEAD)"
