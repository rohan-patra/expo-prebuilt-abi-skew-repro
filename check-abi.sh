#!/usr/bin/env bash
# Verifies that every ExpoModulesCore symbol imported by the prebuilt Expo module
# xcframeworks (shipped inside the npm packages under prebuilds/output/) is
# actually exported by the resolved expo-modules-core prebuilt binary.
# Requires: macOS with Xcode command line tools (nm, tar).
set -euo pipefail

FLAVOR="${1:-release}"
CORE_TGZ="node_modules/expo-modules-core/prebuilds/output/$FLAVOR/xcframeworks/ExpoModulesCore.tar.gz"

if [[ ! -f "$CORE_TGZ" ]]; then
  echo "error: $CORE_TGZ not found — run 'npm install' first" >&2
  exit 1
fi

find_binary() {
  find "$1" -path '*ios-arm64/*' -not -path '*dSYM*' -name "$2" -type f | head -1
}

CORE_VERSION=$(node -p "require('./node_modules/expo-modules-core/package.json').version")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tar xzf "$CORE_TGZ" -C "$WORK"
CORE_BIN=$(find_binary "$WORK" ExpoModulesCore)
nm -gU "$CORE_BIN" | awk '{print $3}' | sort -u > "$WORK/core_exports.txt"
echo "expo-modules-core@$CORE_VERSION prebuilt ($FLAVOR, ios-arm64): $(wc -l < "$WORK/core_exports.txt" | tr -d ' ') exported symbols"
echo

STATUS=0
for PKG in expo-file-system expo-font; do
  TGZ=$(ls node_modules/$PKG/prebuilds/output/$FLAVOR/xcframeworks/*.tar.gz 2>/dev/null | head -1) || true
  if [[ -z "${TGZ:-}" ]]; then
    echo "$PKG: no prebuilt artifact, skipping"
    continue
  fi
  PRODUCT=$(basename "$TGZ" .tar.gz)
  VERSION=$(node -p "require('./node_modules/$PKG/package.json').version")
  D=$(mktemp -d "$WORK/XXXX")
  tar xzf "$TGZ" -C "$D"
  BIN=$(find_binary "$D" "$PRODUCT")
  { nm -m "$BIN" | grep '(from ExpoModulesCore)' || true; } \
    | sed -E 's/.* (_[^ ]+) \(from ExpoModulesCore\).*/\1/' | sort -u > "$D/imports.txt"
  MISSING=$(comm -23 "$D/imports.txt" "$WORK/core_exports.txt")
  TOTAL=$(wc -l < "$D/imports.txt" | tr -d ' ')
  if [[ -n "$MISSING" ]]; then
    COUNT=$(echo "$MISSING" | grep -c '^_')
    echo "❌ $PKG@$VERSION ($PRODUCT): $COUNT of $TOTAL ExpoModulesCore imports are NOT exported by expo-modules-core@$CORE_VERSION:"
    echo "$MISSING" | sed 's/^/     /'
    echo "   → dyld will abort at app launch (Symbol not found), and App Store Connect emits ITMS-90863."
    STATUS=1
  else
    echo "✅ $PKG@$VERSION ($PRODUCT): all $TOTAL ExpoModulesCore imports resolve"
  fi
  echo
done
exit $STATUS
