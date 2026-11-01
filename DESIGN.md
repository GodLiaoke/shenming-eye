---
name: Phoenix CodeV · iOS
description: 双机自用的无畏契约实时雷达 —— 主界面负责配置与连接，全屏雷达由地图、状态点、网页控制抽屉和画中画入口组成。
colors:
  accent: "#5CC8FF"
  signal-go: "#34D97B"
  signal-wait: "#FFB340"
  signal-fault: "#FF6B80"
  neutral-bg: "#060812"
  neutral-panel: "#0F1321"
  neutral-panel-raised: "#14182B"
  neutral-text-secondary: "#9199B0"
  hairline: "rgba(255,255,255,0.10)"
typography:
  display:
    fontFamily: "SF Pro Rounded (system .largeTitle, bold)"
    fontWeight: 700
  title:
    fontFamily: "SF Pro Rounded (system .title2, bold)"
    fontWeight: 700
  section:
    fontFamily: "SF Pro Rounded (system .headline)"
  status-line:
    fontFamily: "SF Pro Rounded (system .subheadline, semibold)"
    fontWeight: 600
  body:
    fontFamily: "SF Pro (system .subheadline)"
  callout:
    fontFamily: "SF Pro (system .callout, medium)"
    fontWeight: 500
  caption:
    fontFamily: "SF Pro (system .caption)"
  mono:
    fontFamily: "SF Mono (system .caption, monospaced, semibold)"
    fontWeight: 600
  counter:
    fontFamily: "SF Pro Rounded (system .subheadline, semibold, tabular digits)"
    fontWeight: 600
rounded:
  sheet-panel: "18pt continuous"
  control: "16pt continuous"
  pill: "capsule"
spacing:
  page-margin: "18pt"
  chrome-margin: "12pt"
  section-gap: "16pt"
  row-padding-vertical: "9pt"
  touch-target-min: "44pt"
components:
  hud-button:
    backgroundColor: "{colors.hud-glass}"
    textColor: "{colors.neutral-bg}"
    rounded: "50%"
    size: "46pt"
  status-banner:
    backgroundColor: "{colors.signal-go}"
    textColor: "{colors.neutral-bg}"
    typography: "{typography.section}"
    rounded: "{rounded.sheet-panel}"
    padding: "14pt 16pt"
  primary-button:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.neutral-bg}"
    typography: "{typography.section}"
    rounded: "{rounded.pill}"
    height: "50pt"
  list-panel:
    backgroundColor: "{colors.neutral-panel}"
    rounded: "{rounded.sheet-panel}"
    padding: "0pt"
  lamp:
    backgroundColor: "{colors.signal-go}"
    size: "9pt"
    rounded: "50%"
---

# Design System: Phoenix CodeV · iOS

## Overview

**Creative North Star: 「一台只有两个面的仪表」**

这个 App 只有两种时刻，两种时刻要的东西完全相反：

```
配置与连接   一局一次（甚至一天一次）   →  要把话说完：状态、二维码、步骤、诊断
看雷达       整局 30 分钟一直盯着       →  什么都别挡着地图
```

v2 把它们放在同一屏（雷达 + 一条常驻状态带），结果是两边都不好：状态带吃掉 60pt，
雷达页自己也还留着一条 57pt 顶栏，而竖屏底图尺寸**由屏宽封顶** —— 省下来的高度只是更多的黑边。
v3 索性分成两个界面：**主界面（配置面）** 与 **全屏雷达（观察面）**，
雷达页只保留左上角状态点、网页控制抽屉和左下角画中画入口。

**Key Characteristics:**

- 两个界面，职责不重叠；**从雷达回主界面只需点那颗状态点**
- 雷达 WebView 常驻，切界面只改显隐 —— 永不重建（数据链的命脉）
- 状态用"形状 + 颜色"双重编码（实心圆 / 空心环 / 实心方），色觉障碍用户读形状
- 颜色分工严格：青蓝属于"App 的动作"，信号灯三色属于"连接状态"
- 拿不到的数据不显示；能拿到的真实数据（帧数）会跳动
- 排障信息还在，但收进主界面里默认折叠的诊断区
- 全部文字走系统文字样式；大字号下换布局（`ViewThatFits`）而不是截断

## 两个界面

| | 主界面 `MainConsoleView` | 全屏雷达 `RadarStageView`（在 `RadarContainerView` 里） |
|---|---|---|
| 什么时候看 | 开局前一次 | 整局 |
| 有什么 | 状态面 / 配对卡（二维码）/ 引擎健康 / 诊断 | 地图 / 状态点 / 网页控制抽屉 / 画中画 |
| 进入方式 | 应用启动即在此 | 底部通栏「雷达」按钮（56pt） |
| 离开方式 | —— | 点左上角状态点 |
| WebView | 在它下面常驻（opacity 0） | 同一个实例，只改显隐 |

## Colors

### Primary

- **accent #5CC8FF** —— 与雷达页 `--accent` 同值。**只给 App 自己的动作与信息**：主按钮填充、`.bordered` 次要按钮描边、二维码外框、加载指示、品牌标记。它**不表示连接状态**。

### Secondary

- **signal-go #34D97B** —— 有数据在流（帧数在涨）。
- **signal-wait #FFB340** —— 引擎好了但还没数据；引擎启动中也算这一档。
- **signal-fault #FF6B80** —— 引擎未运行、面板不可达、转发异常。

**一次只出现一颗灯**，它的形状跟着状态变（实心圆 / 空心环 / 实心方）。
v2 曾经用过"红—琥珀—绿三颗固定顺序的灯位"，被打回：三颗并排、两颗永远灭着，扫一眼就是三个装饰点。

### Neutral

- **neutral-bg #060812** —— 页面底。游戏环境光很暗，深色是场景决定的，不是风格偏好。
- **neutral-panel #0F1321** —— 分组容器（清单、诊断区、扫码区）。
- **neutral-panel-raised #14182B** —— 输入框等抬升面。
- **neutral-text-secondary #9199B0** —— 次要文字；对底 7.2:1，同时满足正文 4.5:1。实际渲染优先用系统 `.secondary` / `.tertiary` 以跟随"提高对比度"设置。
- **hairline rgba(255,255,255,0.10)** —— 浮动元素的 1pt 描边。

### Named Rules

**The Accent Is Not a Status Rule.** 强调色只出现在"这是 App 提供的动作"的地方。任何地方想用青蓝表达"已连接"，改用信号灯三色。

**The Position-Not-Hue Rule.** 任何状态都不能只用颜色区分：颜色必须同时有文字或位置（灯位、图标、字重）承载同一个信息。

## Typography

全部走系统文字样式（`PhoenixType`），跟随 Dynamic Type，不出现硬编码 pt 字号。

### Hierarchy

- **display**（`.largeTitle` rounded bold）—— 激活页产品名，全 App 唯一一处。
- **title**（`.title2` rounded bold）—— 预留给整屏级标题。
- **section**（`.headline` rounded）—— 按钮文字、面板小标题、状态横幅。
- **status-line**（`.subheadline` rounded semibold）—— **状态面里那一句话**：全界面唯一需要"余光可读"的文字，所以用圆体加粗。
- **body / callout**（`.subheadline` / `.callout`）—— 清单条目、说明文字。
- **caption / captionStrong** —— 细节行、次要入口、构建标识。
- **mono / monoSmall**（`.caption` / `.caption2` monospaced）—— 卡密、`IP:端口`、到期时间、房间号。只在"这是机器值"的地方用。
- **counter**（`.subheadline` rounded semibold **tabular digits**）—— 会跳动的帧数/秒数：等宽数字保证位数变化时整行不抖。

### Named Rules

**The No-Kicker Rule.** 标题上方不出现小字标签。标题自己承担重量（激活页曾有一个 `PHOENIX` kicker，已删除）。

**The Monospace Means Machine Rule.** 等宽字体只给机器产生的值。混用即失去"这是机器值"的信号。

**The Wrap Not Truncate Rule.** 状态文字只允许换行（`fixedSize(horizontal: false, vertical: true)`），不允许省略号 —— 被截断的"引擎未运…"比不认识更糟。

## Layout

- **主界面**：内容在安全区内，左右留白 18pt；顶栏（品牌 + 构建标识）不滚动，底部「雷达」按钮不滚动，
  中间的信息列可滚动。分组之间 14pt。
- **全屏雷达**：WebView 铺满并忽略安全区（服务端页面用 `viewport-fit=cover` 自行避让）。
  雷达页自己的顶栏在手机上整条退出（`absolute` + 零高），地图吃掉整个视口。
- **画中画入口**：距左 14pt / 距底 18pt，避免与网页右下角控制抽屉重叠。
- **状态点**：距左上角 6pt / 2pt；视觉 9pt，**热区 44pt**（HIG 最小可点尺寸），
  多出来的面积透明、不吃地图布局但不吃点击穿透（它是按钮，本来就要吃点击）。
- 手机上底图尺寸规则从 `min(画布宽, 画布高) − 32` 改成 `− 4` ——
  竖屏时它由**屏宽**封顶，这 28pt 是白丢的。桌面端仍为 −32。

### Named Rules

**The Radar Owns the Screen Rule.** 雷达界面上除了状态点、网页控制抽屉入口和画中画入口，不允许有其他常驻元素。
任何"想在雷达上加一条提示"的需求，先问它能不能放到主界面或控制抽屉里。

**The Console Holds the Words Rule.** 需要读第二遍才知道什么意思的内容（配对步骤、诊断、说明）
一律在主界面；雷达上只允许"一眼就懂"的东西（地图、点、钮）。

## 状态点的三个形状

| 状态 | 形状 | 颜色 | 含义 |
|---|---|---|---|
| 有数据在流 | 实心圆（外圈缓慢扩散的心跳环） | 绿 #34D97B | 坐标在动 |
| 已就绪在等 | 空心环 | 琥珀 #FFB340 | 引擎好了，等手机 B 进对局 |
| 坏了 | 实心方 | 红 #FF6B80 | 引擎未运行 / 面板不可达 |

把颜色整个去掉，三个形状仍然互相分得开 —— 这是色觉障碍用户的第二条通道。

## Elevation & Depth

深度只有两种手段，都不用投影：

1. **`.ultraThinMaterial`** —— 原生画中画入口使用材质，网页抽屉使用独立的暗色玻璃层。
2. **描边 + 底色** —— `hairline` 1pt 描边界定容器；状态横幅用整块信号灯色的低透明度底（14%）+ 32% 描边，让"状态"占满一条面而不是一个小圆点。

状态灯自身是唯一的"发光"：`shadow(color: lampGlow, radius: 5)` —— 点亮才有光晕，未点亮没有。

### Named Rules

**The No Drop Shadow Rule.** 不给浮动控件加深色投影。深色底上投影只会脏；深度由材质、描边与底色承担。

## Shapes

- 面板 / 分组容器：**18pt continuous**。
- 原生画中画入口：**正圆 46pt**；网页控制抽屉：**20pt continuous**。
- 主界面的卡：**20–22pt continuous**；按钮：capsule（系统 `.borderedProminent`）。
- 主按钮：系统 `.borderedProminent` + `.controlSize(.large)`（系统按控件尺寸给胶囊）。
- 状态灯、画中画圆钮：正圆。
- 二维码：白色圆角面（18pt）承载 —— 不是装饰，扫码需要白色静区。

### Named Rules

**The White Box Is Functional Rule.** 二维码外面那层白底是扫码必需的静区，不是卡片装饰；不要为了统一暗色而给它换成深色。

## Components

### 状态面 `ConnectionStatusBanner`（主界面顶上那块）

整块信号灯色底（14%）+ 32% 描边 + 图标 + 一句话 + 会跳的计数。
绿=正在接收坐标、琥珀=引擎启动中/等待数据、红=故障。主界面上唯一"一眼看通没通"的东西。

### 配对卡 `PairingCard`（主界面的主角）

一张吃满宽度的卡：标题 → 二维码（196pt，白色静区）→ `IP：端口` → 「复制节点链接」主按钮。
二维码是**这一页最大的一个元素**，别的东西都给它让位 —— 客户要做的事只有"让另一台手机扫它"。

### 引擎健康 `EngineHealthCard`（只显示真的观测到的）

三行：本机引擎（`panelProbe` 真发请求探的）/ 坐标流（帧计数）/ 异地观看（转发器五档）。
每行一颗 `SignalLamp`（10pt）+ 名称 + 真实读数。最后一行是进「连接详情」的入口。
**「已接入设备台数」永远不出现** —— 引擎没有等价的瞬时 gauge。

### 雷达控制层

2D / 双视 / 3D、适配、跟随、正北、选自己、阵营筛选和标记大小统一由 WKWebView
里的单一「控制」抽屉承载，避免 SwiftUI 与网页各放一套视图面板。原生层只保留
一个 46pt 画中画入口（放在左下角，不与网页控制入口重叠）。

### 状态点 `RadarStatusDot`

9pt 视觉 / 44pt 热区。点一下回主界面。有心跳（有数据在流）时外圈套一个 2 秒扩散的环。

### 连接详情 `ConnectionConsole`

从引擎健康卡点进来的 sheet：状态面 + 四步配对清单（**观测不到的步骤永不打勾**）
+ 复制异地观看链接 + 折叠诊断 + 解除授权。

### 激活页 `LicenseView`

本轮未改。
