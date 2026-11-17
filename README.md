# Coin Rush Servers 🪙

Coin Rush 多人竞技场的**服务器端多语言实现集**——同一个[线上协议](PROTOCOL.md)，
五种语言各写一份，配合 [coin-rush-client](https://github.com/ShiningRay/coin-rush-client)
浏览器前端即可互玩。"每房间一个 Virtual Actor"的核心语义在五种运行时上各自成立。

## 实现矩阵

| 实现 | 目录 | 框架 | 游戏循环 | 广播 | 落盘 | 状态 |
|---|---|---|---|---|---|---|
| TypeScript | [`typescript/`](typescript/) | [troupejs](https://github.com/ShiningRay/troupe-js)（私有，`file:` 依赖） | Actor 内 `registerCue("tick")` | `publishShow` + `troupe.subscribe` | SQLite（`.troupe/`） | ✅ 本机验证 |
| Crystal | [`crystal/`](crystal/) | [troupe.cr](https://github.com/ShiningRay/troupe-cr) + [troupe-gateway](https://github.com/ShiningRay/troupe-gateway) | 边缘 100ms 驱动 `tick` Turn | Outbox → gateway | SQLite（每拍原子） | ✅ 本机验证 |
| Ruby | [`ruby/`](ruby/) | [troupe.rb](https://github.com/ShiningRay/troupe-rb) | 边缘 100ms 驱动 `tick` | `cast :tick` 返回快照 | PropStore（每 50 拍 `:save`） | ✅ 本机验证 |
| Elixir | [`elixir/`](elixir/) | [troupe-elixir](https://github.com/ShiningRay/troupe-elixir) | 边缘 100ms 驱动 `tick` | `call!` 返回快照 | 内存 PropStore（重启丢失） | ✅ 本机验证 |
| Go | [`go/`](go/) | 无（goroutine + 互斥锁手写同语义） | 每房间 goroutine ticker | 进程内直推 | JSON 快照文件 | ⚠️ 代码就绪，本机无 Go 工具链未运行 |

> 差异属"实现自由度"而非协议分歧：线上帧契约完全一致（[PROTOCOL.md](PROTOCOL.md)）。

## 玩法（以 Crystal 为例）

```sh
# 1) 同级 clone 前端（各服务器检测到 ../coin-rush-client 会同端口托管静态文件）
git clone https://github.com/ShiningRay/coin-rush-client ../coin-rush-client

# 2) 起服务器
cd crystal && shards install && crystal run src/server.cr

# 3) 开玩
open http://localhost:8787/?room=lobby
# 多开标签页/浏览器即多人联机；换房间改 ?room=
```

其他实现：`typescript`（`npm install && npm run dev`）、`ruby`（`bundle install && bundle exec ruby server.rb`）、
`elixir`（`mix deps.get && mix run --no-halt`）、`go`（`go mod tidy && go run .`）。默认端口均 8787。

## 冒烟测试

任一服务器启动后：

```sh
node tools/probe.mjs "ws://127.0.0.1:8787/ws?room=probe"
# PASS: hello + state 广播均符合协议
```

## 契约与分层

- [PROTOCOL.md](PROTOCOL.md)：线上协议 v1（帧、常量、房间生命周期、实现差异备忘）
- 分层依据：[ADR-0007 外部端点分层](https://github.com/ShiningRay/troupe/blob/main/docs/adr/0007-external-endpoint-layering.md)
  ——各实现都是 L3 gateway（协议路由）+ L1/L2 actor 语义的组合，web 框架职责明确不在内。

## License

MIT，见 [LICENSE](LICENSE)。
