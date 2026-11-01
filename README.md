# 神明之眼 1.0 · iOS

本地雷达客户端的 **去卡密 + 白色液态玻璃** 重制版。基于 Phoenix/Codev iOS 工程（`PhoenixCodeV.xcodeproj`）构建。

## 本次改动

| 项 | 改动 |
|---|---|
| 卡密验证 | **整条链路移除**：`AppModel.x0()` 启动即构造本机 grant → 直接进雷达页；`GatewayClient.activate()` 短路，不发 `/api/activate`、不读钥匙串卡密、不判设备绑定与到期；Info.plist 里的网关地址键删除 |
| 名称 | 显示名 **神明之眼**，版本 **1.0 (1)**，Bundle ID `com.shenming.eye` / 扩展 `com.shenming.eye.tunnel`（可与旧版共存） |
| 主题 | 白底纸色 + 半透明白玻璃：`PhoenixTheme` 全部 token 重定色，新增 `GlassPanel` / `glassPanel()` / `glassCapsule()`（`.ultraThinMaterial` + 镜面描边 + 墨色软投影），`preferredColorScheme(.light)` |
| 雷达页 | 仍是引擎本机页面（`127.0.0.1:18080`），数据仍由 `CodevMobile` 本机解码，不出网 |

## 构建

`main` 分支推送即触发 GitHub Actions（`macos-15`）：

```
xcodebuild -project PhoenixCodeV.xcodeproj -scheme Phoenix \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

产物：`ipa/shenming-eye-1.0-unsigned.ipa`（unsigned，供 TrollStore / 自签工具安装）。
仓库内 `Frameworks/CodevMobile.xcframework` 是预编译静态库，构建不需要 Rust 工具链。

## 安装说明

- **TrollStore**：直接安装 IPA（TrollStore 会自行 ldid 签名）。
- **自签（AltStore/Sideloadly/全能签）**：需要网络扩展 entitlement 的签名配置才能启用内置 VPN 通道；否则走「小火箭 → `127.0.0.1:2025`」回退路径，雷达功能不受影响。