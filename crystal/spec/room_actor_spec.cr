require "spec"
require "../src/coin_rush/room_actor"

module CoinRush
  describe RoomActor do
    stage = Troupe::Stage.new
    stage.register(RoomActor.troupe_manifest)
    agent = RoomActor::Agent.new(stage)
    room = Troupe::ActorId.new("spec", "room", "arena-1")

    it "join 返回快照并分配颜色；同 playerId 重连幂等" do
      s1 = agent.join(room, "p1", "alice")
      s1["players"].as_a.size.should eq(1)
      s1["players"][0]["color"].as_s.should eq(COLORS[1])
      s1["coins"].as_a.size.should eq(COIN_COUNT)

      s2 = agent.join(room, "p1", "alice")
      s2["players"].as_a.size.should eq(1) # 重连不重复进场
    end

    it "满员拒绝（MAX_PLAYERS）" do
      hot = Troupe::ActorId.new("spec", "room", "full")
      1.upto(MAX_PLAYERS) { |i| agent.join(hot, "p#{i}", "n#{i}") }
      expect_raises(RoomFullError) { agent.join(hot, "extra", "x") }
    end

    it "tick 推进移动与吃币（导航到最近金币，确定性）" do
      r = Troupe::ActorId.new("spec", "room", "pickup")
      agent.join(r, "p1", "alice")
      score = 0_i64

      3.times do
        snap = agent.snapshot(r)
        p = snap["players"].as_a.first
        coin = snap["coins"].as_a.min_by do |c|
          dx = c["x"].as_f - p["x"].as_f
          dy = c["y"].as_f - p["y"].as_f
          Math.hypot(dx, dy)
        end
        dx = coin["x"].as_f - p["x"].as_f
        dy = coin["y"].as_f - p["y"].as_f
        dist = Math.hypot(dx, dy)

        agent.set_dir(r, "p1", dx / dist, dy / dist)
        steps = (dist / 24.0).ceil.to_i + 1
        steps.times do
          s = agent.tick(r).not_nil!
          found = s["players"].as_a.find { |q| q["id"].as_s == "p1" }
          score = found["score"].as_i64 if found
        end
        score.should eq(coin["id"] != 0 ? score : score) # 占位：下方循环断言累计
      end
      score.should eq(3)
    end

    it "空房间 tick 不广播（返回 players=0）" do
      empty = Troupe::ActorId.new("spec", "room", "empty")
      agent.join(empty, "p", "x")
      agent.leave(empty, "p")
      out = agent.tick(empty)
      out["players"].as_i.should eq(0)
    end

    it "leave 移除玩家" do
      r = Troupe::ActorId.new("spec", "room", "leave")
      agent.join(r, "p1", "alice")
      agent.leave(r, "p1")
      agent.snapshot(r)["players"].as_a.size.should eq(0)
    end
  end
end
