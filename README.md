# NotificationIsland（最小骨架）

把系统通知包成 **SystemAperture 元素** 塞进灵动岛，并把原横幅淡出。iOS 16+ / rootless / SpringBoard 注入。
**这是学习骨架，不是成品插件**：逐条展示（带 3 条短队列）、无视觉堆叠、无点击打开 App。

## 文件

| 文件 | 说明 |
|---|---|
| `Tweak.xm` | 全部实现（约 400 行，单文件） |
| `Makefile` | rootless / arm64 + arm64e / iOS 16 SDK |
| `control` | 包信息（`com.example.notificationisland`） |
| `NotificationIsland.plist` | 只注入 `com.apple.springboard` |

## 依赖

- Theos（`$THEOS` 已设置）
- iOS 16.5 SDK（`$THEOS/sdks/iPhoneOS16.5.sdk`，没有就用 16.4/16.2 也行）
- 越狱环境：Dopamine / palera1n（rootless），iOS 16.x
- **两种机型都能用，但前提完全不同**：
  - **有灵动岛的机型（iPhone 14 Pro 及以后）**：原生 iOS 的通知横幅**并不会**进灵动岛——岛里显示的是实时活动（Live Activity）和系统状态（充电、录音、计时器等）。所以本骨架在这类机型上恰恰有用，不会"重复一份"。
  - **无岛机型**：必须**先装一个"造岛" tweak**（Insula / VisibleIsland / DynamicNotLand 等）。否则 SpringBoard 不会创建 SystemAperture 场景，`SBSystemApertureController` 抓不到，骨架只会打日志、不会显示任何内容。

## 编译 & 安装

```bash
export THEOS=/opt/theos
cd NotificationIsland

make clean
make package FINALPACKAGE=1          # rootless，产物在 packages/
# 或先看有没有语法问题
make DEBUG=1
```

安装（任选）：

```bash
# 1) SSH
scp packages/com.example.notificationisland_0.1.0_iphoneos-arm64.deb root@<device>:/var/mobile/
ssh root@<device> "dpkg -i /var/mobile/*.deb && killall -9 SpringBoard"

# 2) 或把 deb 传到手机上用 Sileo / Filza 安装，然后 respring
```

> 本骨架在 Linux 上未做实际编译验证（仓库环境无 Theos/clang）。首次 `make` 若报错，基本都是 Logos 语法或 SDK 路径问题，按报错行改；逻辑部分已按 Tellus 的真实 API 用法对齐。

## 配置

无需设置面板，用 `defaults` 改（域 `com.example.notificationisland`）：

```bash
# 总开关（默认 1）
defaults write com.example.notificationisland Enabled -bool true
# 是否淡出系统横幅（默认 1）
defaults write com.example.notificationisland HideBanner -bool true
# 岛内停留秒数（默认 4，范围 1~12）
defaults write com.example.notificationisland Duration -float 4
# 布局：0=紧凑 2=宽 3=展开（默认 3）
defaults write com.example.notificationisland LayoutMode -int 3
# 只处理第三方 App（默认 false，系统 App 也会上岛）
defaults write com.example.notificationisland OnlyThirdParty -bool true
# 同一条通知的"更新"也上岛（默认 false，避免同一条反复弹）
defaults write com.example.notificationisland IncludeModified -bool false
# 上岛引擎：false=registerElement（默认） true=借道系统告警（实验性）
defaults write com.example.notificationisland UseSystemAlert -bool false

killall -9 SpringBoard
```

## 拦截架构（双层）

| 层 | 拦截点 | 作用 |
|---|---|---|
| ① 分发层（主） | `NCNotificationDispatcher -postNotificationWithRequest:` | **全量入口**：所有 App 的新通知，与是否弹横幅、是否锁屏无关 |
| ② 横幅层（辅） | `SBNotificationBannerDestination -postNotificationRequest:` | 系统真要弹横幅时把横幅淡掉；分发层失效时也能兜底上岛 |

两层会拿到同一条 `NCNotificationRequest`，用 `uuid` / `notificationIdentifier` 做 2 秒去重，不会重复建元素。两个方法都已在 iOS 16/17 私有头文件中确认存在。

## 两种上岛引擎

| | 引擎 A：`registerElement:`（默认） | 引擎 B：系统告警 |
|---|---|---|
| 入口 | `SBSystemApertureController registerElement:` | `SBAlertItemsController activateAlertItem:` |
| 渲染 | 自建四槽位视图 | 系统渲染（标题/正文/图标/颜色/按钮） |
| 元素由谁建 | 我的 runtime 子类 | 系统 `_createSystemApertureElement` |
| 锁屏 | 靠两个开关，待验证 | 交给系统 presenter |
| 自定义程度 | 高 | 低 |

引擎 B 利用的是 SpringBoard 自带的 `systemApertureAlertItemPresenter`：把 `SBUserNotificationAlert` 的 `prefersSystemAperturePresentation` 设为 YES、填好 `systemApertureContentDefinition`，activate 后系统自己建岛元素。
设 `UseSystemAlert=YES` 启用。失败会保留系统横幅、**不自动回退引擎 A**，方便从日志分辨哪条路通。

## 覆盖范围（重要）

| 场景 | 是否进岛 |
|---|---|
| 解锁状态下第三方 App 横幅通知 | ✅ |
| **锁屏状态下的第三方 App 通知** | ✅ 已走分发层，并给元素加 `_canShowWhileLocked = YES`、`shouldSuppressElementWhileOnCoversheet = NO`（系统另有抑制断言的可能性仍需真机确认） |
| App 通知样式设为"无横幅 / 仅通知中心" | ✅ 分发层不依赖横幅设置 |
| 通知中心里的历史通知（非新到） | ❌ 只处理新到达的通知 |
| 来电、Siri、系统紧急告警 | ❌ 不走 NCNotificationRequest 通道 |
| 同一条通知的"更新"（modify） | 默认忽略，`IncludeModified=YES` 可打开 |

默认系统 App 也会上岛；只要第三方 App 时设 `OnlyThirdParty=YES`（按 `com.apple.` 前缀过滤）。

**多条通知**：岛上已有一条时新通知进入最多 3 条的队列，当前这条结束后自动播下一条，不会互相顶掉。队列满丢最旧的。

## 验证

```bash
# 实时日志（mac 侧）
log stream --device --predicate 'eventMessage CONTAINS "NotificationIsland"'
```

正常启动应看到：

```
[NotificationIsland] prefs: enabled=1 hideBanner=1 duration=4.0s layout=3
[NotificationIsland] 已捕获 SBSystemApertureController
[NotificationIsland] 已创建元素类 NIINotificationElement（基类 SBAlertProvidedContentElement）
[NotificationIsland] 横幅钩子已装在 -[SBNotificationBannerDestination postNotificationRequest:]（1 个参数）
[NotificationIsland] promotion guard 已安装在 -[SAUISystemApertureManager _reevaluatePromotedElements]
```

触发一条通知后：

```
[NotificationIsland] 分发层收到通知：com.tencent.xin | 张三 | 在吗
[NotificationIsland] 准备上岛：com.tencent.xin | 张三 | 在吗
[NotificationIsland] 布局预设 preferred=3 min=1 max=3
[NotificationIsland] 已注册：registration=SAUIElementAssertion
[NotificationIsland] 元素已移除（timeout，方式=registration）
[NotificationIsland] 横幅窗口已恢复（1.4s, sawBanner=1 probe=1）
```

岛上应出现：左侧 App 图标 + 右侧短标题 + 展开后的标题/正文；4 秒后收回；顶部横幅不出现（或一闪即淡）。

## 排错表

| 日志 | 原因 | 处理 |
|---|---|---|
| `没找到 postNotificationRequest*` | iOS 版本选择器改名 | 看紧随其后的 `候选 ... -xxx [编码]`，把前缀加入 `NIIFindBannerMethod` 的判断 |
| `缺件：... registrar=0` | controller 还没被创建 | 解锁一次 / 打开一次 App 触发岛，或等下一次通知；确认 hook 了 `initWithWindowScene:` |
| `元素创建失败` | provider 槽位或 element 初始化返回 nil | 检查 4 个 view 是否都非 nil、`SBUISystemApertureContentProvider` 是否支持对应 setter |
| 岛上不显示但日志显示已注册 | layout mode 不匹配 / 元素被系统立即回收 | 改 `LayoutMode` 试 2；检查 `preferredAlertingDuration:` 编码是否为 `d24@0:8d16` |
| SpringBoard 崩溃重启 | 元素注册触发 promotion 异常 | 本骨架已有面包屑保护（`/tmp/notificationisland.element`），60s 内不会再次上岛；抓 `CrashReporter` 里 `SAUISystemApertureManager _reevaluatePromotedElements` |
| 横幅永久消失 | 恢复轮询被中断 | 重启 SpringBoard；`presentedBanner` 探针失败时会走 7s 固定兜底，正常不会永久透明 |

## 安全机制

- **面包屑**：注册元素前写 `/tmp/notificationisland.element`，销毁时删除。上次异常退出会在启动时被检测到 → 60 秒内跳过所有上岛操作，只用系统横幅，避免 boot loop。
- **全链路 @try**：建视图 / 注册 / 失效都有异常捕获，失败时原横幅保留，不会吞通知。
- **编码校验**：只在类型编码精确匹配 `v24@0:8@16` / `v32@0:8@16@24` 时才换 IMP，避免参数错位崩溃。
- **promotion guard**：hook `SAUISystemApertureManager -_reevaluatePromotedElements`，只在自家元素活着时吞异常，连续 5 次后本次 respring 内停用建元素；清理路径带重入保护。
- **不吞通知**：`registerElement:` 返回 nil、建元素抛异常、guard 停用、恢复窗口内，都直接走系统横幅，绝不淡横幅。

## 接下来可以加什么

1. **堆叠**：把 `sNIICurrent` 换成数组，旧项 `hasActivityBehavior=YES`、layout 1，最多 4 条（参考 Tellus `OITINoticeStackCards.xm`）。
2. **点击打开 App**：给 `SAUIElementView` 挂 tap，用 `SBSLaunchApplicationWithIdentifier`。
3. **上滑关闭**：`UISwipeGestureRecognizer` + `NIIRemoveCurrent(@"swipe")`。
4. **锁屏抑制的兜底**：如果真机上锁屏仍不显示，说明还有别的抑制断言，需要再看 `SBSystemApertureController` 的 `suppressSystemApertureCompletelyWithReason:` / `systemApertureRepresentationSuppressionAssertionForCoversheetVisibility`。
5. **设置面板**：PreferenceLoader + `CFPreferences` 热加载。
