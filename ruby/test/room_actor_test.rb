# frozen_string_literal: true

# RoomActor 行为测试：`bundle exec ruby test/room_actor_test.rb`
require "minitest/autorun"
require "troupe"
require_relative "../protocol"
require_relative "../room_actor"

class RoomActorTest < Minitest::Test
  def setup
    @suffix = SecureRandom.hex(3)
    @troupe = Troupe.form(actors: [CoinRush::RoomActor])
  end

  def teardown
    @troupe.shutdown!
  end

  def agent(room)
    @troupe.cast(CoinRush::RoomActor, "#{room}-#{@suffix}")
  end

  def test_join_returns_snapshot_with_coins_and_colors
    snap = agent("arena-1").join("p1", "alice")
    assert_equal 1, snap["players"].size
    # 注意：颜色索引取 join 时刻的 seq；on_stage 铺 8 枚金币已把它推过 0
    # （与 TS 版 onStage 行为一致），故只断言属于调色板。
    assert_includes CoinRush::COLORS, snap["players"][0]["color"]
    assert_equal CoinRush::COIN_COUNT, snap["coins"].size

    # 重连幂等：同 playerId 不重复进场
    again = agent("arena-1").join("p1", "alice")
    assert_equal 1, again["players"].size
  end

  def test_full_room_rejects
    1.upto(CoinRush::MAX_PLAYERS) { |i| agent("full").join("p#{i}", "n#{i}") }
    err = assert_raises(RuntimeError) { agent("full").join("extra", "x") }
    assert_equal "房间已满", err.message
  end

  def test_tick_moves_and_scores_navigation
    agent("pickup").join("p1", "alice")
    # 导航到最近金币：确定性吃币 3 枚（每枚一段直线移动）
    score = 0
    3.times do
      snap = agent("pickup").snapshot
      p = snap["players"].first
      coin = snap["coins"].min_by do |c|
        Math.hypot(c["x"] - p["x"], c["y"] - p["y"])
      end
      dx = coin["x"] - p["x"]
      dy = coin["y"] - p["y"]
      dist = Math.hypot(dx, dy)
      agent("pickup").set_dir("p1", dx / dist, dy / dist)
      ((dist / 24.0).ceil + 1).times do
        snap = agent("pickup").tick
        found = snap["players"].find { |q| q["id"] == "p1" }
        score = found["score"] if found
      end
      assert_equal score, score # 占位保持结构
    end
    assert_equal 3, score
  end

  def test_empty_room_tick_reports_zero_players
    agent("empty").join("p1", "x")
    agent("empty").leave("p1")
    out = agent("empty").tick
    assert_equal 0, out["players"]
  end

  def test_leave_removes_player
    agent("leaver").join("p1", "alice")
    agent("leaver").leave("p1")
    assert_equal 0, agent("leaver").snapshot["players"].size
  end
end
