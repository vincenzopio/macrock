#!/bin/sh
# vendor-engine.sh VERSION [--from DIR]: put the account service of a macrock-engine release where
# the app build takes it. The app downloads the runtime itself.
#
# DIR holds index.json and the release archives, as the engine's packages directory does; without
# it they are downloaded with gh. The service archive must match the index. The service is signed
# again with the local identity, as the launcher is: it serves only a launcher signed with its own
# certificate.
#
# Writes Vendor/engine: xodus-service, its licenses, the messages of its launcher channel
# (proto/, for scripts/generate-protos.sh), and service-pin.json, which holds the service's code
# directory hash and the protocol the runtime must speak with it.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/Vendor/engine"
IDENTITY=${SIGNING_IDENTITY:-macrock Local}

die() { printf 'vendor-engine: %s\n' "$*" >&2; exit 1; }
usage() { die "usage: vendor-engine.sh VERSION [--from DIR]"; }

[ $# -ge 1 ] || usage
version=$1
shift
from=
case $# in
  0) ;;
  2) [ "$1" = --from ] || usage; from=$2 ;;
  *) usage ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/vendor-engine.XXXXXX")
trap 'rm -rf "$work" "$OUT.new"' EXIT
trap 'exit 130' INT TERM

if [ -z "$from" ]; then
  gh release download "v$version" -R vincenzopio/macrock-engine -D "$work/release" \
    -p index.json -p 'xodus-service-*.aar'
  from=$work/release
fi
index=$from/index.json
[ -f "$index" ] || die "no index.json in $from"

field() { plutil -extract "$1" raw -o - "$index"; }
sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

[ "$(field schema)" = 2 ] || die "index.json has an unknown schema"
[ "$(field version)" = "$version" ] || die "index.json is for version $(field version)"

archive=$from/$(field helper.file)
[ "$(stat -f %z "$archive")" = "$(field helper.size)" ] || die "service archive: wrong size"
[ "$(sha256 "$archive")" = "$(field helper.sha256)" ] || die "service archive: wrong SHA-256"
aa extract -i "$archive" -d "$work"

helper=$work/$(field helper.path)
helper_dir=$(dirname "$helper")
[ "$(lipo -archs "$helper")" = arm64 ] || die "xodus-service is not arm64"
for file in LICENSE THIRD-PARTY-LICENSES.md SOURCES.md proto/common.proto proto/launcher.proto; do
  [ -s "$helper_dir/$file" ] || die "xodus-service: $file is missing"
done
codesign --force --options runtime --timestamp=none --identifier dev.macrock.xodus-service \
  --sign "$IDENTITY" "$helper"

rm -rf "$OUT.new"
mkdir -p "$OUT.new/Licenses/xodus-service"
cp "$helper" "$OUT.new/xodus-service"
for license in LICENSE THIRD-PARTY-LICENSES.md SOURCES.md; do
  cp "$helper_dir/$license" "$OUT.new/Licenses/xodus-service/"
done
cp -R "$helper_dir/proto" "$OUT.new/proto"
cat > "$OUT.new/service-pin.json" <<EOF
{
  "cdhash": "$(cdhash "$OUT.new/xodus-service")",
  "serviceProtocol": $(field service_protocol)
}
EOF
rm -rf "$OUT"
mv "$OUT.new" "$OUT"
printf 'vendored the xodus-service of macrock-engine %s into %s\n' "$version" "$OUT"
