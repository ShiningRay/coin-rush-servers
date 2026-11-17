# frozen_string_literal: true

require "json"
require_relative "protocol"

module CoinRush
  # 每房间一个 Virtual Actor。落盘用 flush Cue（5s 攒批， trouperb 原生内存 Cue）；
  # 游戏循环由边缘进程 100ms 驱动 `tick`（返回快照给边缘广播）。
  class RoomActor < Troupe::Actor
    role_id "room"
    intermission "10m"

    initial_props { { "tick" => 0, "seq" => 1, "players" => {}, "coins" => [] } }

    def on_stage
      fill_coins
      # 攒批冲刷 Cue：仅在场运行，下场自动停
      register_cue("flush", "5s") do
        save_props if @dirty
        @dirty = false
      end
    end

    def off_stage
      save_props if @dirty # 下场前兜底落盘
      @dirty = false
    end

    # 进房：存在即返回快照（重连安全）；满员抛错（边缘转 error 帧）。
    def join(player_id, name)
      unless props["players"].key?(player_id)
        raise "房间已满" if props["players"].size >= MAX_PLAYERS
        props["players"][player_id] = {
          "id" => player_id,
          "name" => name,
          "color" => COLORS[props["seq"] % COLORS.size],
          "x" => PLAYER_RADIUS + rand * (ARENA_W - PLAYER_RADIUS * 2),
          "y" => PLAYER_RADIUS + rand * (ARENA_H - PLAYER_RADIUS * 2),
          "dx" => 0.0, "dy" => 0.0, "score" => 0,
        }
        props["seq"] += 1
        fill_coins
        save_props
      end
      snapshot
    end

    # 移动方向（latest-wins，热路径只改内存）
    def set_dir(player_id, dx, dy)
      p = props["players"][player_id]
      return nil unless p
      p["dx"] = dx.clamp(-1.0, 1.0)
      p["dy"] = dy.clamp(-1.0, 1.0)
      nil
    end

    def leave(player_id)
      return nil unless props["players"].delete(player_id)
      @dirty = true
      save_props
      nil
    end

    # 游戏循环（边缘 100ms 驱动）：推进 + 返回全房快照；空房间返回占位。
    def tick
      props["tick"] += 1
      players = props["players"].values
      if players.empty?
        return { "players" => 0 }
      end

      step = PLAYER_SPEED * TICK_MS / 1000.0
      players.each do |p|
        next if p["dx"].zero? && p["dy"].zero?
        len = Math.hypot(p["dx"], p["dy"])
        p["x"] = (p["x"] + (p["dx"] / len) * step).clamp(PLAYER_RADIUS, ARENA_W - PLAYER_RADIUS)
        p["y"] = (p["y"] + (p["dy"] / len) * step).clamp(PLAYER_RADIUS, ARENA_H - PLAYER_RADIUS)
      end
      props["coins"].each do |coin|
        eater = players.find do |p|
          Math.hypot(p["x"] - coin["x"], p["y"] - coin["y"]) < PICKUP_RADIUS
        end
        next unless eater
        eater["score"] += COIN_VALUE
        coin["id"] = props["seq"]
        coin["x"] = PLAYER_RADIUS + rand * (ARENA_W - PLAYER_RADIUS * 2)
        coin["y"] = PLAYER_RADIUS + rand * (ARENA_H - PLAYER_RADIUS * 2)
        props["seq"] += 1
      end
      @dirty = true
      snapshot
    end

    def snapshot
      {
        "tick" => props["tick"],
        "players" => props["players"].values.map do |p|
          { "id" => p["id"], "name" => p["name"], "color" => p["color"],
            "x" => p["x"], "y" => p["y"], "score" => p["score"] }
        end,
        "coins" => props["coins"].map { |c| { "id" => c["id"], "x" => c["x"], "y" => c["y"] } },
      }
    end

    private

    def fill_coins
      while props["coins"].size < COIN_COUNT
        props["coins"] << {
          "id" => props["seq"],
          "x" => PLAYER_RADIUS + rand * (ARENA_W - PLAYER_RADIUS * 2),
          "y" => PLAYER_RADIUS + rand * (ARENA_H - PLAYER_RADIUS * 2),
        }
        props["seq"] += 1
      end
    end
  end
end
