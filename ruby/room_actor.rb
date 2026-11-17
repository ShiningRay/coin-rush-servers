# frozen_string_literal: true

require "json"
require_relative "protocol"

module CoinRush
  # 每房间一个 Virtual Actor：tick 由边缘进程 100ms 驱动（trouperb 无内存 Cue
  # 之外的便捷驱动），广播靠 cast 返回快照给边缘。
  class RoomActor < Troupe::Actor
    role_id "room"
    intermission "10m"

    def initial_props
      { "tick" => 0, "seq" => 1, "players" => {}, "coins" => [] }
    end

    # 进房：存在即返回快照（重连安全）；满员抛错（边缘转 error 帧）。
    def join(props, player_id, name)
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
        fill_coins(props)
        return [:save, snapshot(props), props]
      end
      [:reply, snapshot(props), props]
    end

    def set_dir(props, player_id, dx, dy)
      p = props["players"][player_id]
      return [:reply, :ok, props] unless p
      p["dx"] = dx.clamp(-1.0, 1.0)
      p["dy"] = dy.clamp(-1.0, 1.0)
      [:reply, :ok, props]
    end

    def leave(props, player_id)
      return [:reply, :ok, props] unless props["players"].key?(player_id)
      props["players"].delete(player_id)
      [:save, :ok, props]
    end

    # 游戏循环（边缘 100ms 驱动）：推进 + 每拍返回快照；每 FLUSH_TICKS 拍落盘。
    def tick(props)
      props["tick"] += 1
      players = props["players"].values
      if players.empty?
        return [:reply, { "players" => 0 }, props]
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

      snap = snapshot(props)
      if props["tick"] % FLUSH_TICKS == 0
        [:save, snap, props] # 持久成功后回复快照
      else
        [:reply, snap, props]
      end
    end

    def snapshot(props)
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

    def fill_coins(props)
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
