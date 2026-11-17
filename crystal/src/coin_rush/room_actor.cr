# RoomActor —— 每个游戏房间一个 Virtual Actor（role=room, key=房间名）。
#
# 与 troupejs 版的差异（契约不变，见 PROTOCOL.md）：
# - 游戏循环由边缘进程 100ms 驱动 `tick` Turn（troupe.cr 无内存 Cue）；
# - 广播：tick Turn 内 emit_event("snapshot") 进 Outbox，由 troupe-gateway
#   的派发循环投递到边缘 on_outbox，再路由给同房间连接；
# - 落盘：tick Turn 内每 FLUSH_TICKS 拍把脏状态 save 一次（SQLite，RPO≈5s）。

require "json"
require "troupe"

module CoinRush
  ARENA_W       = 800.0
  ARENA_H       = 600.0
  TICK_MS       = 100
  PLAYER_SPEED  = 240.0
  PLAYER_RADIUS = 14.0
  COIN_COUNT    = 8
  COIN_RADIUS   = 9.0
  COIN_VALUE    = 1
  PICKUP_RADIUS = PLAYER_RADIUS + COIN_RADIUS
  MAX_PLAYERS   = 16
  FLUSH_TICKS   = 50 # TICK_MS × 50 = 5s

  COLORS = ["#ef4444", "#22c55e", "#3b82f6", "#f97316", "#a855f7", "#14b8a6",
            "#ec4899", "#84cc16", "#f59e0b", "#06b6d4", "#8b5cf6", "#e11d48"]

  class RoomFullError < ::Exception; end

  # 注意必须是 class（引用语义）：tick 内原地改 x/y/score，record（值类型）会丢改动。
  class Coin
    include JSON::Serializable

    property id : Int64
    property x : Float64
    property y : Float64

    def initialize(@id : Int64, @x : Float64, @y : Float64)
    end
  end

  class Player
    include JSON::Serializable

    property id : String
    property name : String
    property color : String
    property x : Float64
    property y : Float64
    property dx : Float64
    property dy : Float64
    property score : Int64

    def initialize(@id : String, @name : String, @color : String,
                   @x : Float64, @y : Float64, @dx : Float64 = 0.0, @dy : Float64 = 0.0,
                   @score : Int64 = 0)
    end
  end

  class RoomProps
    include JSON::Serializable
    property role : String = "room"
    property tick : Int64 = 0
    property seq : Int64 = 1
    property players : Hash(String, Player) = {} of String => Player
    property coins : Array(Coin) = [] of Coin

    def initialize
    end
  end

  class RoomActor < Troupe::Actor(RoomProps)
    troupe_manifest "room", schema_version: 1 do
      turn join, {player_id: String, name: String}, returns: JSON::Any
      turn set_dir, {player_id: String, dx: Float64, dy: Float64}, returns: JSON::Any
      turn leave, {player_id: String}, returns: JSON::Any
      turn tick, {} of String => String, returns: JSON::Any
      turn snapshot, {} of String => String, returns: JSON::Any
    end

    # 进房：存在即返回快照（重连安全）；满员拒绝。
    def join(player_id : String, name : String) : JSON::Any
      unless props.players[player_id]?
        raise RoomFullError.new("房间已满") if props.players.size >= MAX_PLAYERS
        color = COLORS[(props.seq % COLORS.size).to_i]
        x = PLAYER_RADIUS + rand * (ARENA_W - PLAYER_RADIUS * 2)
        y = PLAYER_RADIUS + rand * (ARENA_H - PLAYER_RADIUS * 2)
        props.players[player_id] = Player.new(player_id, name, color, x, y)
        props.seq += 1
        fill_coins
        save
      end
      snapshot_payload
    end

    def set_dir(player_id : String, dx : Float64, dy : Float64) : JSON::Any
      p = props.players[player_id]?
      if p
        p.dx = dx.clamp(-1.0, 1.0)
        p.dy = dy.clamp(-1.0, 1.0)
      end
      JSON.parse(%({"ok":true}))
    end

    def leave(player_id : String) : JSON::Any
      if props.players.delete(player_id)
        save
      end
      JSON.parse(%({"ok":true}))
    end

    # 游戏循环：有玩家时推进 + 广播（emit_event → troupe-gateway）；无玩家不广播。
    # 每 FLUSH_TICKS 拍落盘一次脏状态。
    def tick : JSON::Any
      props.tick += 1
      players = props.players.values
      return JSON.parse(%({"players":0})) if players.empty?

      step = PLAYER_SPEED * TICK_MS / 1000.0
      players.each do |p|
        next if p.dx == 0.0 && p.dy == 0.0
        len = Math.hypot(p.dx, p.dy)
        p.x = (p.x + (p.dx / len) * step).clamp(PLAYER_RADIUS, ARENA_W - PLAYER_RADIUS)
        p.y = (p.y + (p.dy / len) * step).clamp(PLAYER_RADIUS, ARENA_H - PLAYER_RADIUS)
      end
      props.coins.each do |coin|
        eater = players.find { |p| Math.hypot(p.x - coin.x, p.y - coin.y) < PICKUP_RADIUS }
        if eater
          eater.score += COIN_VALUE
          fresh = spawn_coin
          coin.id = fresh.id
          coin.x = fresh.x
          coin.y = fresh.y
        end
      end

      # emit_event 缓冲随 save 原子提交——广播要即时，落盘即每拍一次
      #（SQLite WAL 单行写；与 TS 版"攒批 5s"的差异已记录在 PROTOCOL.md）。
      emit_event("snapshot", snapshot_payload)
      save
      snapshot_payload
    end

    def snapshot : JSON::Any
      snapshot_payload
    end

    private def fill_coins : Nil
      while props.coins.size < COIN_COUNT
        props.coins << spawn_coin
      end
    end

    private def spawn_coin : Coin
      c = Coin.new(props.seq, PLAYER_RADIUS + rand * (ARENA_W - PLAYER_RADIUS * 2),
        PLAYER_RADIUS + rand * (ARENA_H - PLAYER_RADIUS * 2))
      props.seq += 1
      c
    end

    private def snapshot_payload : JSON::Any
      Troupe::Json.any({
        "tick"    => props.tick,
        "players" => props.players.values.map do |p|
          {"id" => p.id, "name" => p.name, "color" => p.color,
           "x" => p.x, "y" => p.y, "score" => p.score}
        end,
        "coins" => props.coins.map { |c| {"id" => c.id, "x" => c.x, "y" => c.y} },
      })
    end
  end
end
