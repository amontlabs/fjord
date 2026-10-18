#!/bin/bash
# Assemble and sign the pinned Silo engine app embedded by build-app.sh.
# The engine is a published Silo release (scripts/silod.release). SILOD_ARCHIVE=/path/to/silo-engine-*.tar.gz
# uses a local archive instead (no pin check), to try an unreleased build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FJORD_APP="${1:?usage: build-silod.sh FJORD_APP SIGNING_IDENTITY}"
SIGNING_IDENTITY="${2:?usage: build-silod.sh FJORD_APP SIGNING_IDENTITY}"
RELEASE_FILE="$ROOT/scripts/silod.release"
SILOD_VERSION="$(sed -n 's/^SILOD_VERSION=//p' "$RELEASE_FILE" | tr -d '[:space:]')"
SILOD_SHA256="$(sed -n 's/^SILOD_SHA256=//p' "$RELEASE_FILE" | tr -d '[:space:]')"
[ -n "$SILOD_VERSION" ] || { echo "scripts/silod.release has no SILOD_VERSION." >&2; exit 1; }
SCHEMA_SHA256="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["schemaSha256"])' "$ROOT/schemas/silo-api/manifest.json")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

if [ -n "${SILOD_ARCHIVE:-}" ]; then
  [ -f "$SILOD_ARCHIVE" ] || { echo "SILOD_ARCHIVE not found: $SILOD_ARCHIVE" >&2; exit 1; }
  ARCHIVE="$SILOD_ARCHIVE"
  EXPECT_VERSION=""
else
  if [ -z "$SILOD_SHA256" ]; then
    echo "scripts/silod.release has no SILOD_SHA256 yet; publish engine-v$SILOD_VERSION in Silo and pin its tarball hash, or set SILOD_ARCHIVE." >&2
    exit 1
  fi
  EXPECT_VERSION="$SILOD_VERSION"
  ARCHIVE_NAME="silo-engine-$SILOD_VERSION-macos-universal.tar.gz"
  CACHE_DIR="$ROOT/build/silod-cache/$SILOD_VERSION"
  ARCHIVE="$CACHE_DIR/$ARCHIVE_NAME"
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$ARCHIVE" ] || [ "$(sha256_of "$ARCHIVE")" != "$SILOD_SHA256" ]; then
    curl --fail --location --retry 3 --silent --show-error --output "$ARCHIVE.part" \
      "https://github.com/amontlabs/silo/releases/download/engine-v$SILOD_VERSION/$ARCHIVE_NAME"
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  ACTUAL_SHA256="$(sha256_of "$ARCHIVE")"
  if [ "$ACTUAL_SHA256" != "$SILOD_SHA256" ]; then
    rm -f "$ARCHIVE"
    echo "$ARCHIVE_NAME hashes to $ACTUAL_SHA256; scripts/silod.release pins $SILOD_SHA256." >&2
    exit 1
  fi
fi

tar -xzf "$ARCHIVE" -C "$WORK"
set -- "$WORK"/*/
if [ "$#" -ne 1 ] || [ ! -f "${1}release.json" ]; then
  echo "$ARCHIVE is not a Silo engine release (expected one top-level directory with release.json)." >&2
  exit 1
fi
RELEASE_DIR="${1%/}"

# A download must be the pinned version; any release must match the schema snapshot Fjord's client is generated from.
[ -f "$RELEASE_DIR/api/silo-api.schema.json" ] || { echo "Engine release has no api/silo-api.schema.json." >&2; exit 1; }
ARCHIVE_SCHEMA_SHA256="$(sha256_of "$RELEASE_DIR/api/silo-api.schema.json")"
python3 -I - "$RELEASE_DIR/release.json" "$EXPECT_VERSION" "$SCHEMA_SHA256" "${UNIVERSAL:-0}" "$ARCHIVE_SCHEMA_SHA256" <<'PY'
import json
import sys

path, expect_version, schema_sha256, universal, file_sha256 = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    release = json.load(handle)
if expect_version and release.get("engineVersion") != expect_version:
    sys.exit(f"Engine release is {release.get('engineVersion')}; scripts/silod.release pins {expect_version}.")
if release.get("schemaSha256") != file_sha256:
    sys.exit(f"Engine release api/silo-api.schema.json hashes to {file_sha256}, not the {release.get('schemaSha256')} in its release.json.")
if release.get("schemaSha256") != schema_sha256:
    sys.exit(
        f"Engine release schemaSha256 {release.get('schemaSha256')} differs from schemas/silo-api/manifest.json "
        f"({schema_sha256}); update the schema snapshot from the release's api/silo-api.schema.json."
    )
if universal == "1":
    missing = {"aarch64-apple-darwin", "x86_64-apple-darwin"} - set(release.get("targets", []))
    if missing:
        sys.exit(f"UNIVERSAL=1 needs both architectures; the engine release lacks {', '.join(sorted(missing))}.")
PY
ENGINE_VERSION="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["engineVersion"])' "$RELEASE_DIR/release.json")"
SOURCE_COMMIT="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["sourceCommit"])' "$RELEASE_DIR/release.json")"

APP_CONTENTS="$FJORD_APP/Contents"
ENGINE_APP="$APP_CONTENTS/Resources/SiloEngineDistribution/Silo Engine.app"
ENGINE_CONTENTS="$ENGINE_APP/Contents"
ENGINE_RESOURCES="$ENGINE_CONTENTS/Resources"
ENGINE_EXECUTABLE="$ENGINE_CONTENTS/MacOS/silod"
AGENT_NAME="org.silo.preview.engine.plist"
SOURCE_BINARY="$RELEASE_DIR/bin/silod"
SOURCE_PLIST="$RELEASE_DIR/macos/LaunchAgents/$AGENT_NAME"
SOURCE_INFO="$RELEASE_DIR/macos/Info.production.plist"
SOURCE_MANIFEST="$RELEASE_DIR/macos/resources/engine-manifest.production.json"

for required in "$SOURCE_BINARY" "$SOURCE_PLIST" "$SOURCE_INFO" "$SOURCE_MANIFEST"; do
  [ -f "$required" ] || { echo "Missing silod packaging input in the engine release: $required" >&2; exit 1; }
done

CODE_REQUIREMENT="${SILOD_PRODUCTION_CODE_REQUIREMENT:-}"
if [ -z "$CODE_REQUIREMENT" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
  CERT_HASH="$(security find-identity -p codesigning | awk -v identity="$SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { print $2; exit }')"
  if [ -n "$CERT_HASH" ]; then
    CODE_REQUIREMENT="certificate leaf = H\"$CERT_HASH\""
  fi
fi
if [ -z "$CODE_REQUIREMENT" ]; then
  # Local ad-hoc builds still verify the signed bundle and its identifier. Release builds
  # inherit the Fjord signing certificate and pin its leaf certificate above.
  CODE_REQUIREMENT='identifier "org.silo.preview.engine"'
fi

rm -rf "$ENGINE_APP"
mkdir -p "$ENGINE_CONTENTS/MacOS" "$ENGINE_CONTENTS/Library/LaunchAgents" "$ENGINE_RESOURCES"
cp "$SOURCE_BINARY" "$ENGINE_EXECUTABLE"
chmod 755 "$ENGINE_EXECUTABLE"
cp "$SOURCE_INFO" "$ENGINE_CONTENTS/Info.plist"
cp "$SOURCE_PLIST" "$ENGINE_CONTENTS/Library/LaunchAgents/$AGENT_NAME"
cp "$SOURCE_MANIFEST" "$ENGINE_RESOURCES/engine-manifest.json"
# silod reads its signer from its own Info.plist; the signature below seals it.
plutil -replace SiloEngineCodeRequirement -string "$CODE_REQUIREMENT" "$ENGINE_CONTENTS/Info.plist"

# SMAppService resolves this plist from Fjord.app. The executable remains in the
# self-contained Silo Engine.app so silod sees its own bundle identifier and resources.
OUTER_AGENT="$APP_CONTENTS/Library/LaunchAgents/$AGENT_NAME"
mkdir -p "$(dirname "$OUTER_AGENT")"
cp "$SOURCE_PLIST" "$OUTER_AGENT"
plutil -replace BundleProgram -string \
  "Contents/Resources/SiloEngineDistribution/Silo Engine.app/Contents/MacOS/silod" \
  "$OUTER_AGENT"

# A tarball made on a Mac can carry com.apple.provenance/FinderInfo, which codesign rejects as detritus.
xattr -cr "$ENGINE_APP"

# Sign nested code first. Do not use --deep: it would replace the engine's signature.
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
  --entitlements "$ROOT/Resources/SiloEngineEntitlements.plist" "$ENGINE_APP"
codesign --verify --strict --verbose=2 "$ENGINE_APP"
codesign --display --entitlements :- "$ENGINE_EXECUTABLE" 2>&1 \
  | python3 -c 'import plistlib, sys; text = sys.stdin.read(); start = text.find("<?xml"); (start >= 0) or sys.exit("codesign returned no entitlement plist"); entitlements = plistlib.loads(text[start:].encode()); sys.exit(0 if entitlements.get("com.apple.security.virtualization") is True else 1)' \
  || { echo "silod is missing com.apple.security.virtualization" >&2; exit 1; }
plutil -lint "$OUTER_AGENT" "$ENGINE_CONTENTS/Library/LaunchAgents/$AGENT_NAME" >/dev/null

echo "Embedded silod $ENGINE_VERSION (Silo $SOURCE_COMMIT) in $ENGINE_APP"
