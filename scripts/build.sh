#!/bin/zsh
# 编译并打包 QuickUse.app 到 build/。
# 用法：scripts/build.sh            只打包
#      scripts/build.sh --install  打包后安装到 /Applications，设为登录时启动并重新启动
set -euo pipefail
cd "${0:A:h}/.."

# 让二进制如实记录所用 SDK 版本；否则系统会按旧 SDK 的兼容模式显示，失去新系统的原生外观。
SDK_VERSION=$(xcrun --show-sdk-version)
FLAGS=(-c release -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$SDK_VERSION")
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/QuickUse"

APP=build/QuickUse.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuickUse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/StatusIcon.svg Resources/AppIcon.icns "$APP/Contents/Resources/"

# 本地自签名。注意：每次重新签名后，系统可能会重新询问定位、自动化、钥匙串权限。
codesign --force --sign - --identifier com.austen.quickuse "$APP"
echo "已生成 $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x QuickUse 2>/dev/null || true
  rm -rf /Applications/QuickUse.app
  cp -R "$APP" /Applications/
  open /Applications/QuickUse.app --args --enable-login-item
  echo "已安装到 /Applications/QuickUse.app，已设为登录时启动"
fi
