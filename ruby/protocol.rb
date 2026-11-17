# frozen_string_literal: true

# Coin Rush 协议常量与帧组装（契约见仓库根 PROTOCOL.md）。
module CoinRush
  ARENA_W = 800.0
  ARENA_H = 600.0
  TICK_MS = 100
  PLAYER_SPEED = 240.0
  PLAYER_RADIUS = 14.0
  COIN_COUNT = 8
  COIN_RADIUS = 9.0
  COIN_VALUE = 1
  PICKUP_RADIUS = PLAYER_RADIUS + COIN_RADIUS
  MAX_PLAYERS = 16
  FLUSH_TICKS = 50 # 5s

  COLORS = %w[
    #ef4444 #22c55e #3b82f6 #f97316 #a855f7 #14b8a6
    #ec4899 #84cc16 #f59e0b #06b6d4 #8b5cf6 #e11d48
  ].freeze

  def self.sanitize(value, fallback, limit)
    cleaned = value.to_s.gsub(/[^\w\u4e00-\u9fa5-]/, "")[0, limit]
    cleaned.empty? ? fallback : cleaned
  end

  def self.hello(player_id, snapshot)
    { type: "hello", playerId: player_id, snapshot: snapshot }
  end

  def self.state(snapshot)
    { type: "state", snapshot: snapshot }
  end

  def self.error(message)
    { type: "error", message: message }
  end
end
