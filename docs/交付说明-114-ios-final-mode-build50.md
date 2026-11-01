# Phoenix CodeV · 114 测试版 iOS 最终模式版交付说明（Build 52 本机地图修复）

日期：2026-10-12  
范围：仅 114 测试版 iOS 客户端、114 使用的共享算法组件与测试代码；未修改 43 正式源码、140 生产服务器或正式包。

## 1. 用户流程

### 首屏

- 首次打开不展示任何二维码。
- 先选择「本机雷达模式」或「双机雷达模式」；选择后才展开对应教程和节点二维码。
- 「共享雷达」是独立操作：点击后复制外网房间链接，并提示“将链接发给别人，浏览器打开即可访问雷达画面”。不再展示浏览器雷达二维码。
- 首页显示连接状态、算法服务状态、坐标流状态、后台状态及代理分层自检结果。

### 本机雷达模式

1. 在 A 手机选择「本机雷达模式」。
2. 按教程导入本机节点；启动本机雷达和节点后，确认首页显示连接成功。
3. 进入游戏；A 手机可开启画中画，在游戏左上角查看雷达。
4. 其他设备可通过「共享雷达」复制的外网链接查看大屏雷达。

### 双机雷达模式

1. A 手机选择「双机雷达模式」，A 负责雷达与算法服务。
2. B 手机按教程导入双机节点并运行游戏。
3. B 的游戏流经 A 的局域网节点，A 显示雷达。
4. 双机模式不显示画中画入口；需要小窗时使用另一台设备打开「共享雷达」链接。

## 2. 关键实现

- `Sources/MainConsoleView.swift`：模式选择、模式教程、专属节点二维码、共享雷达按钮、连接反馈和代理诊断面板。
- `Sources/AppModel.swift`：模式状态、外网分享链接、连接状态、代理诊断和前后台生命周期协调。
- `Sources/ProxyDiagnosticsSnapshot.swift`：分层结果解码，拆分监听、SOCKS 握手、DNS、TCP、UDP、接口状态。
- `Sources/BackgroundRuntime.swift`：前台/后台状态与能力如实显示；普通签名显示“后台恢复已安排 · 可能需要重新同步节点”，Network Extension 可显示“网络扩展后台运行”。
- `Sources/PhoenixApp.swift`：scene phase 切换时恢复健康检查；普通签名后台被系统挂起后，重新拉起中继可能生成新节点凭据，界面会明确提示重新同步。
- `Sources/RadarWebView.swift` / `Sources/LocalMapServer.swift`：本机地图资源服务；面板 CSP 放行随机回环地图端口，避免 WKWebView 拦截地图纹理。
- `rust/codev-mobile/src/lib.rs`：新增 `codev_engine_diagnostics` C ABI；执行本地监听、认证、DNS、TCP 域名连接和 UDP DNS 回包检查，并只返回脱敏 JSON。
- `rust/codev-proxy/src/{config,policy,server,netbind,diagnostics}.rs`：DNS 端口显式开关、iOS 域名解析改走物理出口、旧物理接口绑定失败自动回退、局域网 UDP 回包不走公网接口、UDP 广告地址修正和诊断数据结构。
- `rust/codev-web/src/lib.rs`：CSP 允许 iOS 本地地图服务的随机回环端口。
- `rust/codev-web/static/index.html`：共享雷达浏览器页的状态文案统一为“实时算法”，避免暴露部署位置。
- `Tunnel/GamePacketTunnelProvider.swift`：错误文案统一为“算法服务”，不暴露实现位置。

## 3. 验证记录

### 自动化测试

```bash
python3 Tests/RadarControlMarkupTests.py
# 29 tests passed

cargo test -p codev-web -p codev-protocol -p codev-proxy \
  --manifest-path /Users/Admin/Desktop/源码/Phoenix-副本本地/Phoenix-CodeV-Source/rust/Cargo.toml
# codev-protocol 15 passed；codev-proxy 55 passed；codev-web 83 passed

cargo test -p codev-mobile \
  --manifest-path /Users/Admin/Desktop/源码/Phoenix-副本本地/Phoenix-CodeV-Source/rust/Cargo.toml
# 5 passed
```

### iOS 模拟器

设备：`PhoenixTest`，arm64，iOS Simulator 26.3.1。  
结果：**14 passed / 0 failed / 0 skipped**。

```bash
python3 - <<'PY'
import shutil
shutil.rmtree('build/DerivedDataFinalSim', ignore_errors=True)
PY
xcodebuild test -quiet -project PhoenixCodeV.xcodeproj \
  -scheme Phoenix \
  -destination 'platform=iOS Simulator,id=36B8F693-C89A-491A-8D9C-BC2274E815C5' \
  -derivedDataPath build/DerivedDataFinalSim \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```

### Release 打包

```bash
PHOENIX_RUST_ROOT=/Users/Admin/Desktop/源码/Phoenix-副本本地/Phoenix-CodeV-Source/rust \
  bash build-release-hardened.sh
```

构建门禁：**14/14 个界面元素存在**。包内二进制扫描确认没有旧部署位置文案；诊断符号 `_codev_engine_diagnostics` 已进入 arm64 静态库。

## 4. 测试包

### 未签名 IPA

路径：

`/Users/Admin/Desktop/源码/Phoenix-副本本地/测试-镜像模式-20261002/客户端源码/ios/Phoenix/dist/Phoenix-iOS-iPad-v1.2.0-build52-local-map-fix-unsigned.ipa`

SHA-256：`c85e79827c3bb1f4a451618fe9e29732b60267821de77ed39baec797540d10f9`  
大小：约 15 MB。

### TrollStore / ldid 测试包

路径：

`/Users/Admin/Desktop/源码/Phoenix-副本本地/测试-镜像模式-20261002/客户端源码/ios/Phoenix/dist/Phoenix-iOS-iPad-v1.2.0-build52-local-map-fix-trollstore.ipa`

SHA-256：`4460ff8817eceb48361c796f8a42dfbd1c32602ad6ad7b931bacfe21d10440c6`  
大小：约 15 MB。

普通未签名包可验证 SwiftUI、WebView、模式流程和普通代理监听；Packet Tunnel 的系统级后台能力需要带 Network Extension entitlement 的实际签名环境。应用会在首页明确显示当前后台能力，不把普通签名伪装成完整后台隧道。

## 5. 真机验收顺序

1. 安装 TrollStore 包，选择一个模式，确认首次未选择时没有二维码。
2. 导入对应节点并启动，确认首页先显示“监听/握手/DNS/TCP/UDP/接口”逐层结果，再允许进入雷达。
3. 本机模式：开游戏、开画中画、切到游戏，确认小窗持续显示；双机模式确认没有画中画入口。
4. 点击「共享雷达」，把复制的链接发到另一台设备浏览器，确认能打开外网雷达页面。
5. 横竖屏各切换一次，确认返回连接中心、等待面板、雷达控制浮层不放大、不遮挡主画面。
6. 将 App 切后台再回前台，确认凭据不变、节点不需要重新扫码，状态能恢复。
7. 用 Shadowrocket/真实游戏流验证 HTTPS、DNS、UDP 三条路径；把失败层级记录回传，禁止只报“已连接”。

## 6. 回滚

只回滚 114 客户端时，恢复以下文件即可：

- `Sources/MainConsoleView.swift`
- `Sources/AppModel.swift`
- `Sources/ProxyDiagnosticsSnapshot.swift`
- `Sources/BackgroundRuntime.swift`
- `Sources/PhoenixApp.swift`
- `Sources/LocalRelay.swift`
- `Tunnel/GamePacketTunnelProvider.swift`
- `Frameworks/CodevMobile.xcframework`
- `project.yml`、`PhoenixCodeV.xcodeproj`、`build-release-hardened.sh`

服务器未改动，不需要服务器回滚；43/140 正式链路未触碰。
