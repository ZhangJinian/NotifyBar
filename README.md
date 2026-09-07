# mytouchbar

独立的 Codex Touch Bar 小块，198 × 30 点。左侧新版 ChatGPT 图标，右侧两行：

```text
     5h  88%   09/07 18:30
图标 7d  67%   09/12 10:00
```

百分比表示剩余量，时间为本机时区的 `MM/dd HH:mm` 重置时间。每 60 秒刷新，点击小块会打开当前任务；额度仍可从菜单栏手动刷新。缺失窗口或数值显示 `--`；请求失败保留旧数据，文字变橙色，菜单栏图标提示具体原因，下次自动重试。

## 运行

需要 macOS 12+、Xcode Command Line Tools，以及已经登录的 ChatGPT/Codex 本机应用。

```sh
./build.sh
open build/mytouchbar.app
```

菜单栏只放一个图标，提供刷新、重新显示、隐藏和退出。程序独立常驻，不要求 Codex 在前台，也不跟随 Codex 退出。不安装启动代理；需要登录自动启动时，可自行将 app 添加到系统登录项。

## 左侧布局与后台显示

小块放在 Touch Bar 左侧应用区域，固定 198 × 30 点；右侧系统 Control Strip 不再注册额度项。保持两行额度和重置时间，没有语音或电量条。

原 CodexBar 用 `presentSystemModalTouchBar:systemTrayItemIdentifier:` 绕过前台应用 responder chain，所以切换应用后仍可见。本版本复用这个后台展示方式，但把 650 点的大视图改为 198 点小块，通过 `[额度项, OpenCode项, flexibleSpace]` 左对齐。

OpenCode 进程存在时自动加入另一个 198 × 30 点小块，退出后自动移除。第一行显示 `OpenCode`，第二行横向显示所有已打开位置，例如 `● ● Terminal  ● VS Code`；同一位置的每个 OpenCode 实例各有一个灯。蓝色呼吸表示工作中，绿色表示完成，红色表示等待授权或用户操作；连续点击按实例顺序轮流激活。Terminal 通过 TTY 定位具体标签页；VS Code 通过工作目录定位窗口并聚焦集成终端，首次使用可能出现 macOS 自动化权限提示。

macOS 系统模态接口仍管理整个左侧应用区域。空余位置可添加 **mytouchbar 自己的其他块**，不能自动混入前台其他应用的按钮。右侧系统控制区由系统管理。私有接口未来可能变化；实际物理位置以设备显示为准。

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

- 有运行中任务：蓝色细边框，约 3.2 秒一个呼吸周期。系统开启“减少动态效果”时常亮。
- 等待授权或用户输入：红色常亮，优先级高于蓝框。
- 任务完成：绿色常亮。点击小块打开对应 Codex 任务。

点击时优先打开最近更新的未读任务，其次是最近更新的运行中任务。VS Code 插件记录过的任务通过 `vscode://codex/local/<id>` 打开；其他任务通过 `codex://threads/<id>` 在 Codex 桌面应用打开。点击不会把消息标为已读，是否已读仍由对应应用决定。

使用安装版 ChatGPT 自带的 `icon-chatgpt.png`；两行保留时间，但去掉末尾“重置”两字。宽度为 198 点，左右留白接近，左侧位置不变。

`TaskActivity.swift` 以只读 follower 连接本机 `.codex/ipc/ipc.sock`，订阅已知任务的 `thread-stream-state-changed` 快照和增量，仅保留 `threadRuntimeStatus`，不保存对话内容。读取 `.codex-global-state.json` 的 `electron-persisted-atom-state.unread-thread-ids-by-host-v1` 判断未读，每两秒同步。读取范围是桌面应用已知的 Codex 任务，包括应用连接并广播的远端任务，不是未连接机器上的所有任务或普通 ChatGPT 网页聊天。不会发起任务、写入已读标记或请求辅助功能权限。

断线自动重连并清除失效运行状态；增量版本不连续时重新读取快照。此集成基于当前安装版的本机内部格式（状态广播 v11），应用未来改变格式时需适配。启动时订阅已知任务，状态快照处理后即丢弃消息正文。

```sh
build/mytouchbar.app/Contents/MacOS/mytouchbar --activity-probe
build/mytouchbar.app/Contents/MacOS/mytouchbar --opencode-probe
build/mytouchbar.app/Contents/MacOS/mytouchbar --preview /tmp/mytouchbar-unread.png --unread
build/mytouchbar.app/Contents/MacOS/mytouchbar --preview /tmp/mytouchbar-running.png --running
```
