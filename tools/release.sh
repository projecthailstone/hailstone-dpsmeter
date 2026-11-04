#!/usr/bin/env bash
# Makes a release of DPS Meter as a Hailstone add-on (the client's docs/addons.md): packs dpsmeter/ (the client's
# tools/make_addon.py), signs hailstone-addon.txt, and with --publish uploads both as a GitHub release of this
# repository, the one players paste on the Add-ons screen. The tests run first.
#
#   tools/release.sh 1.0.0              pack into release/v1.0.0/, nothing uploaded
#   tools/release.sh 1.0.0 --publish    the same, then gh release create v1.0.0
#
# Needs a hailstone-client checkout ($HAILSTONE_CLIENT, default ../hailstone-client) for tools/make_addon.py and a
# built hailstone_sign ($HAILSTONE_SIGN, default $HAILSTONE_CLIENT/build/hailstone_sign), the add-on key's secret
# half ($ADDON_KEY, default ~/.config/hailstone-release/addon-key.secret: keep it off GitHub, and keep using the same
# one, since a player's client refuses an update signed with another), and lua5.4 for the tests.
set -euo pipefail

NAME=dpsmeter
CAPS=read,events,ui # README "For server owners"
RELEASE_REPO=projecthailstone/hailstone-dpsmeter
DESCRIPTION="A damage meter: your group's damage per second now, and every fight kept with its details."
AUTHOR="Project Hailstone"
MIN_CLIENT=0.3.0-alpha # hailstone.spawns, ui_function and the Modern pack's hud.Dialog

version=${1:?usage: tools/release.sh <version> [--publish]}
version=${version#v}
publish=${2:-}
here=$(cd "$(dirname "$0")/.." && pwd)
client=$(cd "${HAILSTONE_CLIENT:-$here/../hailstone-client}" && pwd)
sign=${HAILSTONE_SIGN:-$client/build/hailstone_sign}
key=${ADDON_KEY:-$HOME/.config/hailstone-release/addon-key.secret}
out=$here/release/v$version
tag=v$version

[ -f "$client/tools/make_addon.py" ] || { echo "no hailstone-client at $client (set HAILSTONE_CLIENT)" >&2; exit 1; }
[ -x "$sign" ] || { echo "no hailstone_sign at $sign: build the client, or set HAILSTONE_SIGN" >&2; exit 1; }
[ -f "$key" ] || { echo "no add-on key at $key: '$sign keygen $key' once, or set ADDON_KEY" >&2; exit 1; }
if [ -n "$(git -C "$here" status --porcelain)" ]; then
  echo "the working tree has changes: commit them first, so the release matches a commit" >&2
  exit 1
fi

(cd "$here" && lua5.4 tests/run.lua)
rm -rf "$out"
python3 "$client/tools/make_addon.py" --name "$NAME" --kind script --version "$version" --caps "$CAPS" \
    --dir "$here/dpsmeter" --author "$AUTHOR" --description "$DESCRIPTION" --min-client "$MIN_CLIENT" \
    --notes "https://github.com/$RELEASE_REPO/releases/tag/$tag" --out "$out"
"$sign" sign "$key" "$out/hailstone-addon.txt"
"$sign" verify "$("$sign" public "$key")" "$out/hailstone-addon.txt"
ls -l "$out"

if [ "$publish" = "--publish" ]; then
  gh release create "$tag" -R "$RELEASE_REPO" --target "$(git -C "$here" rev-parse HEAD)" --title "DPS Meter $version" \
     --notes "Install from Hailstone's Add-ons screen: paste https://github.com/$RELEASE_REPO." "$out"/*
fi
