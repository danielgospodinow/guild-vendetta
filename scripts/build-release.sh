#!/usr/bin/env bash
# Builds dist/GuildVendetta-<VERSION>.zip: only the addon folder, at the zip's top level, so players
# unzip it straight into Interface/AddOns. The TOC's "## Version:" is stamped from VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(tr -d '[:space:]' < VERSION)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be MAJOR.MINOR.PATCH, got '$version'" >&2; exit 1; }

rm -rf dist && mkdir -p dist/stage
cp -R addon/GuildVendetta dist/stage/
sed -i.bak "s/^## Version: .*/## Version: $version/" dist/stage/GuildVendetta/GuildVendetta.toc
rm dist/stage/GuildVendetta/GuildVendetta.toc.bak
(cd dist/stage && zip -qr "../GuildVendetta-$version.zip" GuildVendetta -x '*.DS_Store')
rm -rf dist/stage
echo "dist/GuildVendetta-$version.zip"
