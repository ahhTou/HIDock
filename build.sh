#!/bin/bash
# HIDock 打包:裸二进制 → 正式 .app(Info.plist + 代码签名)
#
# 用法:
#   ./build.sh                       构建 build/HIDock.app 并自动签名
#   ./build.sh --dist                额外产出 dist/HIDock-<版本>-<架构>.zip(分发用)
#   SIGN=adhoc ./build.sh --dist     强制 ad-hoc 签名的分发包(不嵌开发者邮箱)
#   ./build.sh --notarize            有 Developer ID 证书时:提交公证 + staple(需先配置
#                                    xcrun notarytool store-credentials HIDock ...)
#   ARCHS="arm64 x86_64" ./build.sh  通用二进制(Intel Mac 也能跑)
#
# 签名自动按钥匙串里现有的证书降级:
#   Developer ID Application → 配合 --notarize,任何人下载即可直接打开(不被 Gatekeeper 拦)
#   Apple Development        → 自用,多台自己的 Mac 之间蓝牙权限稳定不重弹
#   都没有 → ad-hoc          → 本机随便用;发给别人,对方需放行一次(见 README)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HIDock"
VERSION=$(defaults read "$PWD/Info.plist" CFBundleShortVersionString)
ARCHS="${ARCHS:-$(uname -m)}"
BUILD="build"
DIST="dist"
APP="$BUILD/$APP_NAME.app"

# ---------- 1. 编译 ----------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
echo "==> 编译 ($ARCHS)"
OBJS=()
for a in $ARCHS; do
    o="$BUILD/$APP_NAME.$a"
    swiftc -O -target "$a-apple-macos15.0" -o "$o" main.swift
    OBJS+=("$o")
done
lipo -create "${OBJS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "${OBJS[@]}"
cp Info.plist "$APP/Contents/Info.plist"

# ---------- 2. 选签名证书 ----------
# SIGN=adhoc 强制 ad-hoc 签名,供分发产物使用:Apple Development 证书的签名里
# 嵌着开发者邮箱,而未公证时它对下载者的 Gatekeeper 待遇与 ad-hoc 完全相同,
# 发布版本不带个人信息为净
if [[ "${SIGN:-}" == "adhoc" ]]; then
    IDENTITY="-"
    SIGN_MODE="adhoc"
else
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=$(echo "$IDENTITIES" | sed -nE 's/.*"([^"]*Developer ID Application[^"]*)".*/\1/p' | head -n1)
SIGN_MODE="developer-id"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(echo "$IDENTITIES" | sed -nE 's/.*"([^"]*Apple Development[^"]*)".*/\1/p' | head -n1)
    [[ -n "$IDENTITY" ]] && SIGN_MODE="apple-development"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    SIGN_MODE="adhoc"
fi
fi
echo "==> 签名 ($SIGN_MODE): $IDENTITY"

# ---------- 3. 签名(hardened runtime 是公证的硬性要求,对普通 AppKit 应用无副作用) ----------
codesign --force --options runtime --sign "$IDENTITY" "$APP"

# ---------- 4. 校验 ----------
codesign --verify --strict --verbose=2 "$APP"
echo "--- Gatekeeper 评估(ad-hoc/未公证显示 rejected 属预期,本机运行不受影响) ---"
spctl -a -vv "$APP" 2>&1 || true
echo

# ---------- 5. 公证 + staple(可选) ----------
if [[ "${1:-}" == "--notarize" ]]; then
    if [[ "$SIGN_MODE" != "developer-id" ]]; then
        echo "错误:公证需要 Developer ID Application 证书(Apple Developer Program, \$99/年)" >&2
        exit 1
    fi
    mkdir -p "$DIST"
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile HIDock --wait
    xcrun stapler staple "$APP"
    spctl -a -vv "$APP"
    rm "$DIST/notarize.zip"
fi

# ---------- 6. 分发 zip(可选) ----------
# 必须用 ditto --keepParent:普通 zip 会丢资源分支/破坏签名结构
if [[ "${1:-}" == "--dist" ]]; then
    mkdir -p "$DIST"
    ARCH_TAG=$(echo "$ARCHS" | tr ' ' '-')
    ZIP="$DIST/${APP_NAME}-${VERSION}-${ARCH_TAG}.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> $ZIP"
fi

echo "==> 完成: $APP  (open $APP 即可启动)"
