#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# ⚠️ 2026-10-06：本脚本默认取「镜像树」的 rust（$ROOT/../../rust），
# 而那棵树比正本树 Phoenix-CodeV-Source/rust 旧 29 个文件，
# 且**不含 codev-decode 与 S2 的会话密钥 C ABI** —— 用它打包会得到
# "Swift 找不到 codev_open_dictionary" 之类的编译错误。
# 需要正本树时用环境变量覆盖（不改默认行为）：
#   PHOENIX_RUST_ROOT="/Users/Admin/Desktop/源码/Phoenix-副本本地/Phoenix-CodeV-Source/rust" \
#     bash build-release-hardened.sh
RUST_ROOT="${PHOENIX_RUST_ROOT:-$(cd "$ROOT/../../rust" && pwd)}"
TARGET_DIR="$ROOT/build/rust-target"
FRAMEWORK="$ROOT/Frameworks/CodevMobile.xcframework"
DERIVED="$ROOT/build/DerivedDataRelease"
DIST="$ROOT/dist"
mkdir -p "$DIST"   # dist 被清掉时脚本原来会 zip 失败（2026-10-13 补）

# ===== 本次改动的两个开关 =====
# SKIP_RUST=1：改动面只有 Swift（Sources/*.swift）时**不重编 Rust**，
#   直接复用仓库里现有的 Frameworks/CodevMobile.xcframework。
#   少了这一步，打包要跑 3 个 Rust target + xcframework 重建，纯属浪费时间与风险。
SKIP_RUST="${SKIP_RUST:-0}"
BUILD_NUMBER="${BUILD_NUMBER:-54}"
# 安装包名 = 日期 + 更新公告；BUILD_NOTE 会写进 Info.plist 的 PhoenixBuildNote
IPA_NAME="${IPA_NAME:-}"
BUILD_NOTE="${BUILD_NOTE:-}"
BUILD_SLUG="${BUILD_SLUG:-heading-up}"
# GATEWAY_ORIGIN=https://... ：正式包换网关地址**只传参数**，不改源码（构建后自动还原 project.yml）
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-}"
# MINIFY_PAGE=0：关闭内嵌雷达页压缩（默认开启 —— 混淆用，构建期替换、结束自动还原）
MINIFY_PAGE="${MINIFY_PAGE:-1}"

# ===== 发布前自检（2026-10-25 新增，防止漏开混淆）=====
if [ "$MINIFY_PAGE" != "1" ]; then
  echo ""
  echo "  ⚠️⚠️⚠️  本次构建 MINIFY_PAGE=$MINIFY_PAGE —— 雷达页面【未混淆】"
  echo "  ⚠️⚠️⚠️  仅供内部调试，【不要对外发布】"
  echo ""
fi


# —— 内嵌雷达页压缩（混淆：去注释 + 变量名混淆；构建期替换，构建后还原）——
PAGE_FILE=""
PAGE_BAK=""
if [ "$MINIFY_PAGE" = "1" ]; then
  # 页面/压缩器路径按"就近优先"找，换目录布局也不会静默跳过混淆。
  for base in "$ROOT/../../../../Phoenix-CodeV-Source" "$ROOT/../../../Phoenix-CodeV-Source" \
              "$ROOT/../../rust/.." "${PHOENIX_RUST_ROOT:-/nonexistent}/.."; do
    if [ -f "$base/rust/codev-web/static/index.html" ] && [ -f "$base/rust/scripts/minify-page.py" ]; then
      PAGE_FILE="$base/rust/codev-web/static/index.html"
      MINIFIER="$base/rust/scripts/minify-page.py"
      break
    fi
  done
  PAGE_FILE="${PAGE_FILE:-${PHOENIX_PAGE_FILE:-}}"
  MINIFIER="${MINIFIER:-${PHOENIX_MINIFIER:-}}"
  if [ -f "$PAGE_FILE" ] && [ -f "$MINIFIER" ]; then
    PAGE_BAK="$(mktemp)"
    cp "$PAGE_FILE" "$PAGE_BAK"
    python3 "$MINIFIER" "$PAGE_FILE" "$PAGE_FILE.tmp" && mv "$PAGE_FILE.tmp" "$PAGE_FILE"
  else
    echo "  ⚠️ 找不到页面或压缩脚本，跳过压缩"
  fi
fi

if [ "$SKIP_RUST" != "1" ]; then
export CARGO_TARGET_DIR="$TARGET_DIR"
export CARGO_PROFILE_RELEASE_DEBUG=false
export CARGO_PROFILE_RELEASE_STRIP=debuginfo
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1

cd "$RUST_ROOT"
python3 scripts/encode-page.py codev-web/static/index.html codev-web/static/index.html.enc   # 硬化：页面加密后进二进制
cargo build -p codev-mobile --release --target aarch64-apple-ios
cargo build -p codev-mobile --release --target aarch64-apple-ios-sim
cargo build -p codev-mobile --release --target x86_64-apple-ios

mkdir -p "$ROOT/build" "$ROOT/Frameworks" "$DIST"
lipo -create \
  "$TARGET_DIR/aarch64-apple-ios-sim/release/libcodev_mobile.a" \
  "$TARGET_DIR/x86_64-apple-ios/release/libcodev_mobile.a" \
  -output "$ROOT/build/libcodev_mobile_sim.a"

TMP_FRAMEWORK="$ROOT/Frameworks/.CodevMobile.hardened.xcframework"
rm -rf "$TMP_FRAMEWORK"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libcodev_mobile.a" \
  -headers "$RUST_ROOT/codev-mobile/include" \
  -library "$ROOT/build/libcodev_mobile_sim.a" \
  -headers "$RUST_ROOT/codev-mobile/include" \
  -output "$TMP_FRAMEWORK"
rm -rf "$FRAMEWORK"
mv "$TMP_FRAMEWORK" "$FRAMEWORK"

else
  echo "SKIP_RUST=1：跳过 Rust 与 xcframework 重建，复用现有 $FRAMEWORK"
fi

cd "$ROOT"

# —— 网关地址注入（用后即还原，源码不留痕）——
PROJECT_YML_BAK=""
if [ -n "$GATEWAY_ORIGIN" ]; then
  PROJECT_YML_BAK="$(mktemp)"
  cp project.yml "$PROJECT_YML_BAK"
  python3 - "$GATEWAY_ORIGIN" <<'PYEOF'
import re, sys
value = sys.argv[1]
p = 'project.yml'
s = open(p, encoding='utf-8').read()
s = re.sub(r'(PhoenixGatewayOrigin:\s*)\S+', r'\g<1>' + value, s)
open(p, 'w', encoding='utf-8').write(s)
print(f'  注入网关地址: {value}')
PYEOF
  trap '[ -n "$PROJECT_YML_BAK" ] && cp "$PROJECT_YML_BAK" project.yml; [ -n "$PAGE_BAK" ] && cp "$PAGE_BAK" "$PAGE_FILE"' EXIT
fi
# 开发机未安装 xcodegen 时直接复用仓库内已生成的工程；
# project.yml 与提交的 xcodeproj 同步维护，避免打包流程被工具缺失卡住。
XCODEGEN_BIN="${XCODEGEN_BIN:-/Users/Admin/bin/xcodegen}"
if [ -x "$XCODEGEN_BIN" ]; then
  "$XCODEGEN_BIN" generate
else
  echo "xcodegen 未安装，使用仓库内已生成的 PhoenixCodeV.xcodeproj"
fi
rm -rf "$DERIVED"
xcodebuild -project PhoenixCodeV.xcodeproj \
  -scheme Phoenix \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=15.0 \
  -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Release-iphoneos/Phoenix.app"
PAYLOAD="$ROOT/build/ipa/Payload"
rm -rf "$ROOT/build/ipa"
mkdir -p "$PAYLOAD"
cp -R "$APP" "$PAYLOAD/"
# 界面上那行「构建」= 日期 + 更新公告（PhoenixBuildNote），同时注入 build 号
NOTE="${BUILD_NOTE:-$(date +%Y-%m-%d)}"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :PhoenixBuildNote $NOTE" "$PAYLOAD/Phoenix.app/Info.plist" 2>/dev/null \
  || $PB -c "Add :PhoenixBuildNote string $NOTE" "$PAYLOAD/Phoenix.app/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$PAYLOAD/Phoenix.app/Info.plist" 2>/dev/null \
  || $PB -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PAYLOAD/Phoenix.app/Info.plist"
echo "  注入 PhoenixBuildNote: $NOTE"
echo "  注入 CFBundleVersion: $BUILD_NUMBER"
rm -rf "$PAYLOAD/Phoenix.app/_CodeSignature"
IPA="$DIST/${IPA_NAME:-Phoenix-iOS-iPad-v1.2.0-build${BUILD_NUMBER}-${BUILD_SLUG}-unsigned.ipa}"
rm -f "$IPA"
(cd "$ROOT/build/ipa" && zip -qr "$IPA" Payload)

# ===== 界面元素在包门禁（2026-10-09 加）=====
# 2026-10-20：异地观看已下线，锚点从「外网雷达链接已复制 / 异地观看」
# 换成「局域网雷达链接已复制 / 已收到」——门禁跟着功能走，不能留死锚点。
# 为什么需要：`SWIFT_COMPILATION_MODE: wholemodule` 曾经把雷达页左上角那颗状态点
# （`RadarStatusDot`）整块优化掉 —— 编译通过、链接通过、App 能跑，
# 只有那个视图不见了，翻遍构建日志都看不出来（详见 project.yml 里的注释）。
# 这里按**二进制里的界面字符串**逐个核对（用 python 搜字节：BSD grep 不支持 -a，
# 会把带非 ASCII 的 Mach-O 当二进制直接跳过，反而永远"找不到"）。
#
# ⚠️ 一处例外（2026-10-09 实测，原因未明）：`RadarStatusDot` 的两句 VoiceOver 文案
# （"连接状态：…" / "回到主界面"）在 Debug 与 Release 产物里都查不到字节，
# 而同一个文件里的其它视图文案都在、该视图在模拟器上渲染正常、
# 它的 accessibilityIdentifier 也能查到。也就是说**这一条门禁查不到它，不等于它不在**。
# 所以这里只核对那个标识符当锚点；那两句文案另行人工确认（见交付报告"未验证项"）。
BIN="$PAYLOAD/Phoenix.app/Phoenix"
UI_CHECKS='
雷达页 · 状态点（构建锚点）|radar-status-dot
雷达页 · 画中画|画中画
主界面 · 一键游戏模式|进入游戏模式
主界面 · 连接节点|连接节点
主界面 · 本机游戏通道反馈|本机游戏通道已启用
雷达页 · 返回连接|返回连接节点
主界面 · 算法服务|算法服务
主界面 · 本机模式|本机雷达模式
主界面 · 双机模式|双机雷达模式
主界面 · 局域网共享雷达|局域网雷达链接已复制
主界面 · 本机数据流|已收到
连接详情 · 入口|连接详情与配对步骤
连接详情 · 解除授权|解除本机授权
雷达页 · 加密页已进包（硬化和锚点）|CVPAGE1
'
if ! UI_CHECKS="$UI_CHECKS" python3 - "$BIN" <<'PYGATE'
import os, sys
bin_path = sys.argv[1]
data = open(bin_path, 'rb').read()
rows = [r for r in os.environ.get('UI_CHECKS', '').splitlines() if '|' in r]
missing = []
for row in rows:
    label, needle = row.split('|', 1)
    if needle.encode('utf-8') not in data:
        missing.append(label.strip())
        print(f"❌ 界面元素缺失：{label.strip()}（二进制里找不到「{needle.strip()}」）")
if missing:
    sys.exit(1)
print(f"✓ 界面元素门禁：{len(rows)}/{len(rows)} 个界面元素都在包里")
PYGATE
then
  echo "❌ 有界面元素没进包 —— 不能交付。"
  exit 1
fi

# 页面还原保险：minify 是"构建期替换、结束还原"，万一还原失败，
# 从 index.html.orig 兜底，别让源码树停在压缩态（2026-10-20 踩过一次）。
PAGE_SRC="${PAGE_FILE:-}"
if [ -n "$PAGE_SRC" ] && [ -f "$PAGE_SRC" ] && ! grep -q "brand-skin" "$PAGE_SRC"; then
  if [ -f "$PAGE_SRC.orig" ]; then
    cp "$PAGE_SRC.orig" "$PAGE_SRC"
    echo "  ⚠️ 检测到页面仍是压缩态，已从 index.html.orig 还原"
  else
    echo "  ⚠️ 页面疑似未还原，且没有 .orig 备份 —— 请手动检查 $PAGE_SRC"
  fi
fi

shasum -a 256 "$IPA"
ls -lh "$IPA"

# TrollStore / ldid 测试包：未配置 Apple Developer 证书时，普通 unsigned IPA
# 可以安装界面但系统不会启动 Packet Tunnel。若本机有 ldid，就同时产出带
# packet-tunnel-provider entitlement 的伪签名包，供本地测试环境直接安装。
LDID_BIN="${LDID_BIN:-/Users/Admin/.local/bin/ldid}"
if [ -n "$IPA_NAME" ]; then
  SIGNED_IPA="$DIST/${IPA_NAME%.ipa}-trollstore.ipa"
else
  SIGNED_IPA="$DIST/Phoenix-iOS-iPad-v1.2.0-build${BUILD_NUMBER}-${BUILD_SLUG}-trollstore.ipa"
fi
if [ -x "$LDID_BIN" ]; then
  SIGN_WORK="$ROOT/build/ipa-ldid"
  rm -rf "$SIGN_WORK"
  cp -R "$ROOT/build/ipa" "$SIGN_WORK"
  "$LDID_BIN" -S"$ROOT/Tunnel/PhoenixTunnel.entitlements" \
    "$SIGN_WORK/Payload/Phoenix.app/PlugIns/PhoenixTunnel.appex/PhoenixTunnel"
  "$LDID_BIN" -S"$ROOT/Phoenix.entitlements" \
    "$SIGN_WORK/Payload/Phoenix.app/Phoenix"
  rm -f "$SIGNED_IPA"
  (cd "$SIGN_WORK" && zip -qr "$SIGNED_IPA" Payload)
  echo "✓ ldid 测试包：$(shasum -a 256 "$SIGNED_IPA" | awk '{print $1}')"
  ls -lh "$SIGNED_IPA"
else
  echo "未找到 ldid，跳过 TrollStore 伪签名包"
fi
