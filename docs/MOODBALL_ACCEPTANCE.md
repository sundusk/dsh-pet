# MoodBall 验收记录

日期：2026-09-12

## 已验证

- 官方 Harness checkout 为 `c291e7961a515f6d7af9304e7fd1d257929aef26`，版本 `0.1.5-rc.2`；官方源码保持只读。
- 插件 TypeScript `pnpm typecheck` 通过。
- 插件 `pnpm build` 通过，生成 `lib/index.js` 和 `lib/types/`。
- 命令协议测试通过：能力查询、工作区查询、固定会话响应、同一 Session 串行提交、状态订阅推送、`0600` 权限、畸形 JSON 后连接继续可用。
- Swift Debug 构建通过：`swift build -c debug --disable-sandbox`。
- `dist/MoodBall.app` Release 构建通过，Bundle ID `com.sundusk.moodball`，资源图集齐全，`codesign --verify --deep --strict` 通过。
- 交互面板已采用独立附属窗口，输入框使用原生 `NSTextView`，Enter/Shift+Enter 和中文 IME 选字分支有对应代码路径。
- 实际启动构建产物并通过菜单栏检查“输入消息 / 新建会话 / 选择工作区 / 打开 Harness”；输入框截图可见，空工作区时发送按钮禁用，草稿经 Esc 收起再打开后仍保留。

## 尚未验证

- 尚未在真实运行的 Harness `pnpm dsh web` 上加载本版本插件并执行真实文字提交、连续对话和两个会话隔离验收。
- 尚未完成完整真实桌面截图验收：悬停路径、屏幕边缘、多屏、点击穿透、焦点切换和拖动期间附属面板跟随仍需要逐项检查。
- 尚未替换已安装 MoodBall.app、重启官方 Harness、推送 GitHub 或发布 Release；这些操作不属于本次默认交付。

## 第三阶段：截图附件（2026-09-16）

### 实现边界

- 支持输入框粘贴图片和回形针菜单启动 macOS 框选截图；框选期间隐藏 MoodBall 两个浮层，完成、取消或启动失败后恢复。
- 附件草稿落在 MoodBall 私有目录，支持缩略图、移除、失败状态和重试。请求只有获得 Harness `accepted` 确认后才清理对应私有图片；超时、断线和服务端拒绝均保留草稿。
- 图片通过官方 `sessionController.prompt` 的 image content block 提交，由 Harness 校验模型图像能力、附件限制并持久化，消息中不发送 MoodBall 私有文件路径。

### 仍需真实环境验收

- 在当前用户 Harness profile 中重载插件，分别验证纯图片、图片加文字、模型不支持图像、数量/大小超限和断线重试。
- 在实际桌面验证粘贴、框选完成、Esc 取消、屏幕录制权限拒绝、多屏框选，以及框选前后宠物和输入控件显隐恢复。
- 检查 Harness 会话中真实收到并可查看图片；本地构建与协议测试不能替代该项。

### 安装替换

- 已将旧版 `/Applications/MoodBall.app` 移入废纸篓，并原子替换为第三阶段本地构建后启动。
- 安装版 Bundle ID 为 `com.sundusk.moodball`，版本 `0.6.0`、build `10`；严格签名校验通过，运行进程来自目标路径。
- 安装版主程序 SHA-256 为 `ef69ca47b171171050f2aff2529d868f5180923ec39feda9ae104299d09ca4f2`，与替换前已核验的构建产物一致；当前只保留 `/Applications/MoodBall.app` 一个 App Bundle。

## 运行验收顺序

1. 在官方源码根目录执行 `pnpm dsh web`，确认 `workspaceRegistry` 和 `sessionController` 可用。
2. 构建并安装本仓库插件后，重新加载对应 Harness profile；不修改官方源码。
3. 构建 `dist/MoodBall.app` 并启动 App。
4. 不经过桌宠输入框，直接在 Harness 桌面版或网页版中运行一个任务，确认它出现在桌宠的当前任务/最近任务中；任务属于其他工作区或桌宠尚未选择工作区时同样应出现。
5. 同时运行两个任务（一个等待授权或回答，一个运行中），确认出现总览气泡和每个任务一张气泡、右上角页码，点击气泡可循环；等待操作时自动回总览并显示等待动作，任务面板同时显示两张卡片。完成/失败动画只保留约 3 秒，之后不再循环。
6. 选择工作区，发送第一条文字；确认 Harness 新建并执行 MoodBall 专用 Session。
7. 在执行中确认发送按钮禁用；完成后发送第二条文字，确认上下文仍在同一 Session。
8. 通过菜单“新建会话”后选择同一或另一工作区，确认得到不同 Session ID，旧任务不被取消。
9. 粘贴一张图片并单独发送，再发送一条“文字＋图片”，确认两条消息在目标 Session 中均包含 Harness 持久化后的图片。
10. 启动框选截图后分别完成和取消，确认浮层恢复，取消时文字与已有附件不变。
