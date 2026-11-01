# Phoenix CodeV iOS 1.2.0 build 49

本工程以 A 手机单机游戏为主路径：A 启动本 App、本机 CodevMobile 解码并驱动画中画雷达。签名包支持 Packet Tunnel 直接接管游戏流量；普通全能签不具备该能力时，改由同一台手机的 Shadowrocket 连接 `127.0.0.1:2025` 接管游戏流量。B/平板/电脑只作为可选的大屏观看端，访问 A 的局域网地址或授权异地链接。

生产构建不包含调试恢复密钥或免验证入口；本机 CodevMobile 只负责已授权会话的实时流量解析和本地面板，完整授权仍由服务器 `/api/activate` 执行。

## 构建关键点

1. Rust `codev-mobile` 分别编译 `aarch64-apple-ios`、`aarch64-apple-ios-sim` 和 `x86_64-apple-ios`；
2. 模拟器静态库用 `lipo` 合并；
3. 使用 `xcodebuild -create-xcframework` 生成 `Frameworks/CodevMobile.xcframework`，主 App 与 Packet Tunnel 扩展共用；
4. `xcodegen generate` 生成 Xcode 工程；
5. 真机 Release 使用 `iphoneos` 构建，随后由实际发布者证书签名/导出 IPA。

当前交付 IPA 无 Apple 开发者签名，需要用户自己的证书或签名工具重签。Packet Tunnel 路径依赖 iOS Network Extension 能力；普通全能签包走 Shadowrocket 回退路径，主 App 前台运行本机引擎，Shadowrocket 负责游戏流量接管。

完整操作方式见 `docs/全平台使用说明-build45.md`。

## build 49：A 设备单机游戏模式

A 手机就是唯一的游戏设备：A 启动本 App → 连接节点 → 点击「进入游戏模式」。带 Network Extension 的签名包由 Packet Tunnel 接管 A 的游戏流量；普通全能签包则在小火箭连接 `127.0.0.1:2025` 后接管。之后本机 CodevMobile 解码 → 雷达页预热画中画 → 横屏切到游戏。PiP 是实时雷达的小窗，位置由 iOS 系统管理，启动后可拖到左上角。

B 手机不再参与主链路，也不需要 Shadowrocket。B/平板/电脑只作为可选观看端：A 首页「局域网大屏观看」生成带令牌的局域网地址；异地设备继续使用授权雷达共享链接。它们只读地图，不接管 A 的游戏流量。

实现边界：主 App 退到后台后，Network Extension 扩展继续持有本机引擎、Packet Tunnel 和异地坐标上传；主 App 回到前台时通过 `sendProviderMessage` 重新取得当前面板地址与状态。真实 iPhone 验证需要带 Network Extension `packet-tunnel-provider` 能力的签名包；当前交付 IPA 是未签名测试包。

## VPN 启动说明

build49 同时输出两个测试包：

- `...build49-single-device-pip-unsigned.ipa`：仅用于界面/源码测试，不保证系统启动 Packet Tunnel；
- `...build49-single-device-pip-trollstore.ipa`：使用本机 `ldid` 给主 App 与 Tunnel 扩展写入 `packet-tunnel-provider`，优先用这个包测试“本机游戏通道”。

### 普通全能签安装流程

1. 打开 Phoenix，等待首页显示“本机节点已就绪”；
2. 在首页「普通签名 · 小火箭接管游戏」里复制配置，或手动新建 SOCKS5：地址 `127.0.0.1`、端口 `2025`，用户名和密码使用复制出的配置；
3. 打开小火箭并连接该节点；
4. 回到 Phoenix 点「进入游戏模式」，再横屏启动游戏。雷达页面和画中画继续使用本机 `127.0.0.1:18080` 面板。

普通全能签下不要在系统设置里开启“Phoenix VPN”；该入口属于 Packet Tunnel 路径，签名不带 Network Extension 时必然无法连接。

若 ldid 包仍无法在设备中开启 VPN，设备当前安装环境没有接受 Network Extension entitlement；需要给 `com.myrader.val.codev` 与 `com.myrader.val.codev.tunnel` 使用同一套已开通 Network Extension 的 Apple provisioning profile 重新签名。
