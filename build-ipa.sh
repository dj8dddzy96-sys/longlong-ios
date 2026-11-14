#!/usr/bin/env bash
# 任意 Mac 上一键出未签名 IPA（TrollStore 直装 / Sideloadly 重签）
# 用法: ./build-ipa.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || { echo "安装 xcodegen..."; brew install xcodegen; }

xcodegen generate

xcodebuild build \
  -project PocketStash.xcodeproj \
  -scheme PocketStash \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=NO

APP=$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name "*.app" | head -1)
rm -rf out && mkdir -p out/Payload
cp -R "$APP" out/Payload/
( cd out && zip -qry PocketStash-unsigned.ipa Payload )

echo
echo "=== 出包完成 ==="
echo "IPA: $(pwd)/out/PocketStash-unsigned.ipa"
ls -lh out/PocketStash-unsigned.ipa
