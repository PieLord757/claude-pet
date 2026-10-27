#!/bin/zsh
# Usage: scripts/release.sh 0.4.1
# Bumps VERSION, commits, tags and pushes. GitHub Actions then builds, tests and publishes
# the release, and the Homebrew tap picks it up within a day (or run its "Bump cask" workflow).
set -e
cd "${0:A:h}/.."
v="${1:?usage: scripts/release.sh X.Y.Z}"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 1.2.3"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
echo "$v" > VERSION
./build.sh
git commit -qam "Release v$v"
git tag "v$v"
git push -q origin HEAD "v$v"
echo "Pushed v$v. Watch the release build: gh run watch"
