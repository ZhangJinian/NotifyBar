# mytouchbar

独立的 Codex Touch Bar 小块，198 × 30 点。左侧新版 ChatGPT 图标，右侧两行：

```text
     5h  88%   09/07 18:30
图标 7d  67%   09/12 10:00
```

百分比表示剩余量，时间为本机时区的 `MM/dd HH:mm` 重置时间。每 60 秒刷新，点击小块也可刷新。缺失窗口或数值显示 `--`；请求失败保留旧数据，文字变橙色，菜单栏图标提示具体原因，下次自动重试。

## 运行

需要 macOS 12+、Xcode Command Line Tools，以及已经登录的 ChatGPT/Codex 本机应用。

```sh
./build.sh
open build/mytouchbar.app
```

菜单栏只放一个图标，提供刷新、重新显示、隐藏和退出。程序独立常驻，不要求 Codex 在前台，也不跟随 Codex 退出。不安装启动代理；需要登录自动启动时，可自行将 app 添加到系统登录项。

## 左侧布局与后台显示

小块放在 Touch Bar 左侧应用区域，固定 198 × 30 点；右侧系统 Control Strip 不再注册额度项。保持两行额度和重置时间，没有语音或电量条。

原 CodexBar 用 `presentSystemModalTouchBar:systemTrayItemIdentifier:` 绕过前台应用 responder chain，所以切换应用后仍可见。本版本复用这个后台展示方式，但把 650 点的大视图改为 228 点小块，通过 `[额度项, flexibleSpace]` 左对齐。后续新块加在 `flexibleSpace` 前即可，不需要扩大额度块。

注意：小块仅占 228 点，但 macOS 系统模态接口仍管理整个左侧应用区域。空余位置可添加 **mytouchbar 自己的其他块**，不能自动混入前台其他应用的按钮。右侧系统控制区由系统管理。私有接口未来可能变化；实际物理位置以设备显示为准。

更新后退出旧 mytouchbar，再启动新版本。旧 CodexBar 若仍显示，可从其菜单隐藏 Touch Bar，随后在 mytouchbar 菜单点“重新显示小块”。

额度客户端精简复用 CodexBar：启动已安装应用内的 `codex app-server --listen stdio://`，完成 initialize/initialized，再请求 `account/rateLimits/read`。优先使用 `rateLimitsByLimitId.codex`，按 300/10080 分钟识别两个窗口；只有旧接口同时缺失两个窗口时长时才使用 primary/secondary 顺序。带超时、重连和后台刷新；不读取或保存凭据，不使用 API key，不创建会话或发送模型请求。

没有语音、麦克风、辅助功能权限请求，也没有桌面浮窗、token 扫描、自动启动脚本或第三方依赖。5 个 Swift 源文件，原生 AppKit + Foundation。

## 检查

```sh
./build.sh
build/mytouchbar.app/Contents/MacOS/mytouchbar --self-test
build/mytouchbar.app/Contents/MacOS/mytouchbar --probe
build/mytouchbar.app/Contents/MacOS/mytouchbar --preview /tmp/mytouchbar-preview.png
```

`--self-test` 验证窗口缺失/顺序、旧格式、未知时长、百分比边界与时间戳单位；`--probe` 只输出额度及重置时间，验证真实 app-server 读取；`--preview` 生成示例数据的原尺寸布局图，不表示真实额度。

派生自 CodexBar，保留其 MIT LICENSE 中 Jack Chen 与 wjx8 的版权声明。

## 任务与未读边框

- 有运行中任务：淡蓝色细边框，约 3.2 秒一个呼吸周期。系统开启“减少动态效果”时常亮。
- 有未读任务消息：红色常亮，优先级高于蓝框。在 ChatGPT/Codex 查看相应消息后，边框随应用已读状态恢复。
- 没有运行中或未读任务：无彩色边框。点击小块仍为刷新额度，不会擅自将消息标为已读。

使用安装版 ChatGPT 自带的 `icon-chatgpt.png`；两行保留时间，但去掉末尾“重置”两字。宽度为 198 点，左右留白接近，左侧位置不变。

`TaskActivity.swift` 以只读 follower 连接本机 `.codex/ipc/ipc.sock`，订阅已知任务的 `thread-stream-state-changed` 快照和增量，仅保留 `threadRuntimeStatus`，不保存对话内容。读取 `.codex-global-state.json` 的 `electron-persisted-atom-state.unread-thread-ids-by-host-v1` 判断未读，每两秒同步。读取范围是桌面应用已知的 Codex 任务，包括应用连接并广播的远端任务，不是未连接机器上的所有任务或普通 ChatGPT 网页聊天。不会发起任务、写入已读标记或请求辅助功能权限。

断线自动重连并清除失效运行状态；增量版本不连续时重新读取快照。此集成基于当前安装版的本机内部格式（状态广播 v11），应用未来改变格式时需适配。启动时订阅已知任务，状态快照处理后即丢弃消息正文。

```sh
build/mytouchbar.app/Contents/MacOS/mytouchbar --activity-probe
build/mytouchbar.app/Contents/MacOS/mytouchbar --preview /tmp/mytouchbar-unread.png --unread
build/mytouchbar.app/Contents/MacOS/mytouchbar --preview /tmp/mytouchbar-running.png --running
```
