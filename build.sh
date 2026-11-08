#!/bin/bash
# 构建 ReSettle.app：SwiftPM 编译 → 手工组装 .app → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/ReSettle.app"

echo "==> swift build -c $CONFIG"
# --disable-sandbox：本包无外部依赖，在受限 shell 环境里 SwiftPM 自带的 manifest 沙箱会报
# "sandbox_apply: Operation not permitted"，所以这里关掉它。
swift build -c "$CONFIG" --disable-sandbox

BIN=".build/$CONFIG/ReSettle"
if [ ! -f "$BIN" ]; then
    echo "build product missing: $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReSettle"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 用 Apple Development 证书签名：TCC（辅助功能授权）按“证书 + Bundle ID”记账，
# 以后重新编译不会被要求重新授权。没有证书就退回 ad-hoc（每次重编译可能要重授权）。
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    echo "==> signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier com.vajoylan.resettle "$APP"
else
    echo "==> no signing identity, using ad-hoc"
    codesign --force --sign - --identifier com.vajoylan.resettle "$APP"
fi

echo "==> done"
echo "    $PWD/$APP"
echo ""
echo "运行:  open $APP"
echo "诊断:  $APP/Contents/MacOS/ReSettle --dump"
