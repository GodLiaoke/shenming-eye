这两个文件是「S2 会话密钥 + 本机解密」切换时要用到的，现在**未参与编译**。

SessionDictionaryService.swift
  向云端换取 35 分钟会话密钥 → 调用 CodevMobile 的 codev_open_dictionary 本地解开
  按会话加密的字段字典 → codev_set_dictionary 注入引擎 → 到期自动续期，
  续期失败则 codev_clear_dictionary 回退内嵌字典（止损）。

启用前提（缺一不可）：
  1. project.yml 中**用 Frameworks/CodevMobile.xcframework 替换** PhoenixCloudRelay.xcframework
     （两个并存会因同名 module.modulemap 冲突导致构建失败）
  2. 把 Sources-Legacy-本机解密版/ 的 LocalCodeVEngine.swift、LanRelay.swift 移回 Sources/
  3. 把本文件移回 Sources/
  4. 服务端已部署 S2 接口（POST /api/v1/session/key，35 分钟 TTL）

⚠️ 切换前必须确认：引擎实际用的是云端下发的字典，而不是内嵌的那份。
   校验方式：codev_dictionary_is_injected() 必须返回 1。
