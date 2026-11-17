# Coin Rush 线上协议 v1

所有实现（TypeScript / Crystal / Ruby / Elixir / Go）必须逐字遵守本契约；前端
[coin-rush-client](https://github.com/ShiningRay/coin-rush-client) 依赖它连接任意实现。

## 传输

- WebSocket 文本帧，单帧一条 UTF-8 JSON object；路径 **`/ws?room=<房间名>`**。
- 房间名与昵称清洗：去除 `[^\w\u4e00-\u9fa5-]`（字母数字/下划线/连字符/中文）后截断——房间 ≤32 字符、昵称 ≤12 字符，空则回退默认（`lobby` / `玩家`）。

## 常量（两端一致，硬编码在各自实现内）

| 常量 | 值 | 说明 |
|---|---|---|
| ARENA_W / ARENA_H | 800 / 600 | 竞技场尺寸 |
| TICK_MS | 100 | 游戏循环与快照广播周期 |
| PLAYER_SPEED | 240 | 逻辑单位/秒（每拍步长 = 240 × 0.1 = 24） |
| PLAYER_RADIUS | 14 | 玩家半径（出生点内缩半径） |
| COIN_COUNT | 8 | 场上金币数 |
| COIN_RADIUS / PICKUP_RADIUS | 9 / 23 | 金币半径 / 拾取半径（14+9） |
| COIN_VALUE | 1 | 每枚金币得分 |
| MAX_PLAYERS | 16 | 房间人数上限（超限 join 报错 `房间已满`） |
| FLUSH_MS | 5000 | 攒批落盘周期（丢失窗口 RPO = 5s） |

## 客户端 → 服务端

```json
{"type": "join", "name": "alice"}
{"type": "move", "dx": 1, "dy": 0}
```

- `join`：连接后的首条消息。**playerId 由服务端生成**（UUID），连接与玩家一一绑定；
  同连接重复 join 以首次为准。
- `move`：`dx`/`dy` 被钳制到 [-1, 1]；**latest-wins**，只改内存不落盘。

## 服务端 → 客户端

```json
{"type": "hello",  "playerId": "uuid", "snapshot": {…}}
{"type": "state",  "snapshot": {…}}
{"type": "error",  "message": "房间已满"}
```

`snapshot` 形状：

```json
{
  "tick": 42,
  "players": [{"id": "uuid", "name": "alice", "color": "#ef4444", "x": 120.5, "y": 88.0, "score": 3}],
  "coins":   [{"id": 1, "x": 300.0, "y": 250.0}]
}
```

- `hello`：join 成功后的全房快照（历史 = 当前在场状态）。
- `state`：每拍广播，**仅在房间有玩家时发送**；玩家/金币顺序不作保证，客户端按 id 处理。
- `error`：join 被拒（房间已满/协议错误等）；客户端收到后断开并展示 message。
- 玩家颜色：12 色调色板按房内自增 `seq` 轮转（`#ef4444 #22c55e #3b82f6 #f97316 #a855f7 #14b8a6 #ec4899 #84cc16 #f59e0b #06b6d4 #8b5cf6 #e11d48`）。

## 房间生命周期

- 一个房间名 = 一个独立状态实例（Troupe 语义下即一个 Virtual Actor），房间间互不干扰。
- 游戏循环只在**房间有玩家**期间推进；空房间不广播（框架实现中随下场/驱动跳拍停止）。
- 断线：服务端立刻从房间移除该玩家并广播后续快照。
- 落盘：每 5 秒把"脏"状态原子写一次（实现可按框架能力选择 SQLite / JSON 快照 / 内存，
  见各实现 README 的对比矩阵）。

## 实现差异备忘（不改变线上契约）

| 维度 | typescript | crystal | ruby | elixir | go |
|---|---|---|---|---|---|
| 框架 | troupejs | troupe.cr + troupe-gateway | troupe.rb | troupe-elixir | 无（goroutine 手写） |
| 游戏循环 | Actor 内 `registerCue("tick")` | 边缘 100ms 驱动 `tick` Turn | Actor 内 `register_cue` | 边缘 100ms 驱动 `tick` | 每房间 goroutine ticker |
| 广播通道 | `publishShow` + `troupe.subscribe` | Outbox → troupe-gateway | Show / 边缘驱动 | 边缘驱动（call! 返回） | 进程内直推 |
| 落盘 | SQLite（框架 `.troupe/`） | SQLite（troupe.cr PropStore） | PropStore（框架默认） | 内存 PropStore（重启丢失） | JSON 快照文件 |
| join 幂等 | 框架幂等记录（同 id 改名视为冲突） | 存在即返回快照 | 同左 | 同左 | 同左 |
