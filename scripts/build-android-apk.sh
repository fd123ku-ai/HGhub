#!/usr/bin/env bash
# 本地 / CI 通用：初始化 Android 工程 → 按 ABI 打 release APK → 签名 → 拷到 artifacts/
#
# 依赖：
#   - Rust stable + targets: aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   - JDK 17+（JAVA_HOME）
#   - Android SDK（ANDROID_HOME / ANDROID_SDK_ROOT）
#   - NDK（NDK_HOME，建议与 CI 一致：ndk;28.2.13676358）
#   - pnpm
#
# 签名：
#   若设置了 ANDROID_KEY_BASE64 + ANDROID_KEY_ALIAS + ANDROID_KEYSTORE_PASSWORD + ANDROID_KEY_PASSWORD，
#   则用正式密钥；否则生成/复用本地 debug keystore（仅自用安装，勿对外分发）。
#
# 用法：
#   ./scripts/build-android-apk.sh
#   OUT_DIR=/tmp/hghub-apk ./scripts/build-android-apk.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
: "${ANDROID_SDK_ROOT:=${ANDROID_HOME:-}}"
: "${JAVA_HOME:=}"

die() { echo "error: $*" >&2; exit 1; }

[[ -n "${ANDROID_HOME:-}" ]] || die "请设置 ANDROID_HOME（Android SDK 根目录）"
[[ -n "${NDK_HOME:-}" ]] || die "请设置 NDK_HOME（例如 \$ANDROID_HOME/ndk/28.2.13676358）"
[[ -d "$ANDROID_HOME" ]] || die "ANDROID_HOME 不存在: $ANDROID_HOME"
[[ -d "$NDK_HOME" ]] || die "NDK_HOME 不存在: $NDK_HOME"
command -v pnpm >/dev/null || die "需要 pnpm"
command -v rustc >/dev/null || die "需要 rustc"

VERSION="$(node -p "require('./src-tauri/tauri.conf.json').version")"
OUT_DIR="${OUT_DIR:-$ROOT/artifacts/android}"
mkdir -p "$OUT_DIR"

BT="$(ls "$ANDROID_SDK_ROOT/build-tools" | sort -V | tail -1)"
APKSIGNER="$ANDROID_SDK_ROOT/build-tools/$BT/apksigner"
ZIPALIGN="$ANDROID_SDK_ROOT/build-tools/$BT/zipalign"
[[ -x "$APKSIGNER" ]] || die "找不到 apksigner：$APKSIGNER"

echo "==> 安装前端依赖"
pnpm install --frozen-lockfile

if [[ ! -d src-tauri/gen/android ]]; then
  echo "==> 生成 Android 工程"
  pnpm tauri android init --ci
fi

echo "==> 同步安卓图标"
node scripts/sync-android-icons.mjs

echo "==> 编译 APK（aarch64 / armv7 / x86_64）"
pnpm tauri android build --apk --split-per-abi --target aarch64 armv7 x86_64

# ---- 签名密钥 ----
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

KS="$TMP_DIR/release.keystore"
KEY_ALIAS=""
STORE_PASS=""
KEY_PASS=""

if [[ -n "${ANDROID_KEY_BASE64:-}" ]]; then
  : "${ANDROID_KEY_ALIAS:?缺少 ANDROID_KEY_ALIAS}"
  : "${ANDROID_KEYSTORE_PASSWORD:?缺少 ANDROID_KEYSTORE_PASSWORD}"
  : "${ANDROID_KEY_PASSWORD:?缺少 ANDROID_KEY_PASSWORD}"
  echo "$ANDROID_KEY_BASE64" | base64 -d > "$KS"
  KEY_ALIAS="$ANDROID_KEY_ALIAS"
  STORE_PASS="$ANDROID_KEYSTORE_PASSWORD"
  KEY_PASS="$ANDROID_KEY_PASSWORD"
  echo "==> 使用正式密钥签名"
else
  KS="$TMP_DIR/debug.keystore"
  KEY_ALIAS=hghub
  STORE_PASS=android
  KEY_PASS=android
  keytool -genkeypair -keystore "$KS" -alias "$KEY_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
    -dname "CN=HGhub Debug, OU=Dev, O=HGhub, L=Local, ST=NA, C=US" \
    >/dev/null
  echo "==> 未配置正式密钥，使用临时 debug keystore（仅自用安装）"
fi

map_abi() {
  case "$1" in
    arm64) echo aarch64 ;;
    arm) echo armv7 ;;
    x86_64) echo x86_64 ;;
    *) echo "$1" ;;
  esac
}

echo "==> 对齐并签名"
found=0
while IFS= read -r -d '' f; do
  abi_dir="$(basename "$(dirname "$(dirname "$f")")")"
  abi="$(map_abi "$abi_dir")"
  aligned="$TMP_DIR/${abi}-aligned.apk"
  out="$OUT_DIR/HGhub_${VERSION}_${abi}.apk"
  "$ZIPALIGN" -f -p 4 "$f" "$aligned"
  "$APKSIGNER" sign \
    --ks "$KS" --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "pass:$STORE_PASS" --key-pass "pass:$KEY_PASS" \
    --v4-signing-enabled false \
    --out "$out" "$aligned"
  "$APKSIGNER" verify --print-certs "$out" >/dev/null
  ls -lh "$out"
  found=$((found + 1))
done < <(find src-tauri/gen/android/app/build/outputs/apk -name '*-release*.apk' -print0)

[[ "$found" -gt 0 ]] || die "没有找到 release APK"
echo "==> 完成：$found 个 APK → $OUT_DIR"
