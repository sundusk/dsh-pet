# DSH Pet 命令协议

本文档描述 `@sundusk/dsh-pet` 与 DSH Pet.app 之间的本地协议。它是用户当前 macOS 账户下的 Unix Socket，插件拥有服务端，App 只连接和观察；协议不启动、停止或重启 DeepSeek Harness，也不提供未鉴权的 HTTP 写接口。

## Socket

- 路径：`~/Library/Application Support/DSH Pet/dsh-pet-command.sock`
- 传输：Unix stream socket，UTF-8，NDJSON（一行一个 JSON 对象）
- 权限：服务端创建后设为 `0600`
- 状态接口：`GET /api/dsh-pet/status`，同时保留旧的 `GET /api/moodball/status`

## 请求与响应

请求都携带客户端生成的 `id`。成功响应形状为 `{ "id": "...", "ok": true, ... }`；失败响应形状为 `{ "id": "...", "ok": false, "error": { "code": "...", "message": "..." } }`。

### `capabilities`

```json
{"id":"r1","action":"capabilities"}
```

返回协议版本、能力名、状态订阅支持情况，以及当前 Harness 部署的
`attachmentLimits`。支持图片的插件会在 `supports` 中包含 `imageAttachments`；限制包含
`maxImageBytes`、`maxImagesPerMessage`、`maxMessageImageBytes`、像素/边长上限和允许的
`mediaTypes`。`maxCommandBytes` 是命令 Socket 单行的传输上限，已包含部署允许的聚合图片
Base64 膨胀和协议元数据余量。App 只有在命令 Socket 能力可用时显示发送能力；只有旧状态
Socket/HTTP 时继续显示宠物状态并禁用发送。

### `workspaces`

```json
{"id":"r2","action":"workspaces"}
```

返回已由 Harness 注册的工作区投影：`id`、`title`、规范路径、`status`（`ok` / `missing-dir`）和已归属的 Session ID。插件直接读取官方 `ctx.workspaceRegistry`，不会把任意本地目录伪装成工作区。

### `createSession`

```json
{
  "id":"r3",
  "action":"createSession",
  "workspaceId":"...",
  "sessionId":"dsh-pet-session-..."
}
```

插件验证工作区后调用官方 `ctx.sessionController.create({ workspaceId, sessionId })`。App 会持久化这个固定 Session ID，因此同一次重试会被 Harness 幂等接纳，不会因为超时重复创建会话。

### `prompt`

```json
{
  "id":"r4",
  "action":"prompt",
  "workspaceId":"...",
  "sessionId":"...",
  "requestId":"dsh-pet-...",
  "text":"请继续处理……",
  "images":[
    {"mediaType":"image/png","data":"<canonical-base64>","name":"capture.png"}
  ]
}
```

插件验证 Session 属于目标工作区后，调用官方：

```ts
ctx.sessionController.prompt({
  requestId,
  sessionId,
  mode: 'queue',
  content: [
    ...(text.trim() === '' ? [] : [{ type: 'text', text }]),
    ...images.map(image => ({ type: 'image', ...image })),
  ],
}, signal)
```

`text` 可以省略或为空，`images` 可以省略；但二者不能同时为空。图片保持客户端顺序，`data`
是图片字节的规范 Base64，不是临时文件路径或 Data URL。命令桥先按 `attachmentLimits` 检查
数量、单图估算字节和聚合估算字节，再把原始 `PromptContentPart` 交给官方
`sessionController.prompt`。官方服务负责媒体类型、真实图片内容、尺寸、当前模型图像能力和
持久化校验；失败时 Socket 响应保留官方错误码和消息，App 不应静默移除草稿或图片。

同一 Session 的创建和提交按顺序串行化；Harness 自身也按 `requestId` 去重。收到
`accepted: true` 只代表消息进入 Agent inbox，不代表执行完成。超时由 App
显示“提交结果未确认”，保留草稿与图片并沿用同一 `requestId` 重试。发送确认后，Harness
持久化的附件由 Harness 管理；App 只能清理自己的私有草稿副本。

### `tasks`

```json
{"id":"r5","action":"tasks"}
```

返回当前所有已注册工作区中的普通 Session 摘要。标题优先使用 Harness 的
`sessionTitle` 服务；服务不可用时使用工作目录和会话 ID 后缀作为稳定回退。子 Agent（带
`parentSessionId` 或 `origin: "subagent"`）会在插件侧排除。每项包含标题、工作区、更新时间、运行状态和可用于图标/排序的 `mood`、`waitingForUser`、`failed`、`completed` 字段：

```json
{
  "sessionId":"...",
  "workspaceId":"...",
  "title":"修复构建问题",
  "updatedAt": 1760000000000,
  "running": false,
  "blank": false,
  "state":"completed",
  "mood":"done",
  "taskRunning": false,
  "waitingForUser": false,
  "failed": false,
  "completed": true
}
```

`subscribeTasks` 返回同样的 `tasks` 数组，并在会话摘要或状态变化后推送：

```json
{"event":"tasks","tasks":[...]}
```

App 只展示当前选定工作区。未读位置由 App 本地保存：首次基线不会把历史会话全部标为未读，之后的新任务或状态变化才会触发提醒；点击任务详情会标记该项已读。

### `subscribe` / `unsubscribe`

```json
{"id":"r6","action":"subscribe","sessionId":"..."}
```

订阅成功时返回当前 Session 快照；之后服务端向同一连接推送：

```json
{
  "event":"status",
  "sessionId":"...",
  "snapshot": {
    "state":"thinking",
    "mood":"waiting",
    "taskRunning":true,
    "waitingForUser":false,
    "failed":false,
    "completed":false,
    "updatedAt": 0
  }
}
```

状态按 Session 独立折叠。`waiting`、`jumping`、`authorizing`、`questioning` 表示任务仍在进行；`done`、`failed`、`stopped` 是结果/终止状态，不能与“已提交”混同。

## 降级边界

- 命令 Socket 不存在、旧插件或 Harness 未提供官方服务时：App 保留原有本地状态 Socket/HTTP 展示，输入框不可发送并给出原因。
- 工作区失效、Session 不存在或跨工作区发送被拒绝时：草稿保留，不切换到其他 Session。
- `新建会话` 只清除 DSH Pet 的本地绑定；不删除、不取消旧 Harness Session。
- 打开 Harness 只打开设置中的 Harness 首页；会话 ID可复制，不依赖未经官方验证的深链接。
