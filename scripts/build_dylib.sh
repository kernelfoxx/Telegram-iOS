#!/usr/bin/env bash
#
# Build ReynardGramDebug.dylib for iOS (arm64/arm64e) and ad-hoc sign it.
# Designed to be used locally on macOS or inside GitHub Actions.
#
# Usage: ./scripts/build_dylib.sh [output_dir]
#
set -euo pipefail

OUT_DIR="${1:-build}"
SRC="tools/ReynardGramDebug.m"
OUT="$OUT_DIR/ReynardGramDebug.dylib"

if [ ! -f "$SRC" ]; then
    echo "ERROR: Source not found: $SRC" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "ERROR: Xcode command line tools (xcrun) not found. Run this on macOS with Xcode." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
MIN_IOS="15.0"

echo "[+] SDK:        $SDK_PATH"
echo "[+] Clang:      $CLANG"
echo "[+] Targets:    arm64, arm64e"
echo "[+] Min iOS:    $MIN_IOS"
echo "[+] Output:     $OUT"

$CLANG -dynamiclib \
    -arch arm64 -arch arm64e \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$MIN_IOS" \
    -fobjc-arc \
    -fmodules \
    -Os \
    -g0 \
    -framework Foundation \
    -framework UIKit \
    "$SRC" \
    -o "$OUT"

echo ""
echo "[+] Build OK"
file "$OUT"
echo ""
echo "[+] Linked libraries:"
otool -L "$OUT"

# Signing
echo ""
if command -v ldid >/dev/null 2>&1; then
    echo "[+] Signing with ldid"
    ldid -S "$OUT"
else
    CODESIGN="$(xcrun --sdk iphoneos --find codesign)"
    echo "[+] ldid not found, signing with codesign (ad-hoc): $CODESIGN"
    $CODESIGN --force --sign - --timestamp=none "$OUT"
fi

echo ""
echo "[+] Signing info:"
codesign -dv "$OUT" 2>&1 || true

echo ""
echo "[✓] Done. Dylib is at: $OUT"
echo "    Inject it into your IPA (ESign: add dylib on import; otherwise"
echo "    insert_dylib -> @executable_path/Frameworks/ReynardGramDebug.dylib)."
echo "    Logs will appear in the app's Documents/ReynardGramDebug.log and"
echo "    get copied to the clipboard on every write so you can paste them"
echo "    even if the app crashes/black-screens immediately."
