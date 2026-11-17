# frozen_string_literal: true

# RoomActor 行为测试：`bundle exec ruby test/room_actor_test.rb`
require "minitest/autorun"
require "troupe"
require_relative "../protocol"
require_relative "../room_actor"

class RoomActorTest < Minitest::Test
  def setup
    @troupe = Troupe.form(actors: [CoinRush::RoomActor])
  end

  def teardown
    @troupe.shutdown!
  end

  def agent(room)
    @troupe.cast(CoinRush::RoomActor, room)
  end

  def test_join_returns_snapshot_with_coins_and_colors
    snap = agent("arena-1").join("p1", "alice")
    assert_equal 1, snap["players"].size
    assert_equal CoinRush::COLORS[1], snap["players"][0]["color"]
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

  def test_tick_moves_toward_coin_and_scores
    agent("pickup").join("p1", "alice")
    # 朝任意方向移动，60 拍内必然路过至少一枚金币（竞技场 800×600、步长 24/拍）
    agent("pickup").set_dir("p1", 1.0, 0.5)
    score = 0
    60.times do
      snap = agent("pickup").tick
      p = snap["players"].find { |q| q["id"] == "p1" }
      score = p["score"] if p
      break if score > 0
    end
    assert_equal 1, score
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
