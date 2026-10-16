#!/bin/sh
# generate-protos.sh: generate the Swift messages of the account service's launcher channel into
# LauncherCore, from the .proto files vendor-engine.sh puts in Vendor/engine/proto. The generated
# files are committed: run this again whenever the vendored service's messages change.
#
# protoc comes from Homebrew's protobuf. protoc-gen-swift is built from the SwiftProtobuf the
# package resolved, so that the generated code matches the library it compiles against.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE="$ROOT/LauncherCore"
PROTO="$ROOT/Vendor/engine/proto"
OUT="$PACKAGE/Sources/LauncherCore/Xodus"

die() { printf 'generate-protos: %s\n' "$*" >&2; exit 1; }

[ -d "$PROTO" ] || die "no $PROTO; run vendor-engine.sh"
command -v protoc >/dev/null 2>&1 || die "protoc not found; install Homebrew's protobuf"

swift build --package-path "$PACKAGE" -c release --product protoc-gen-swift
plugin=$(swift build --package-path "$PACKAGE" -c release --show-bin-path)/protoc-gen-swift
protoc --plugin=protoc-gen-swift="$plugin" --proto_path="$PROTO" --swift_out="$OUT" \
  "$PROTO/common.proto" "$PROTO/launcher.proto"
printf 'generated the launcher channel messages into %s\n' "$OUT"
