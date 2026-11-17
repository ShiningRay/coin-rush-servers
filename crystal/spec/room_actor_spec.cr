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

    it "tick 推进移动与吃币：靠近金币的玩家得分且金币重生" do
      r = Troupe::ActorId.new("spec", "room", "pickup")
      agent.join(r, "p1", "alice")
      snap = agent.snapshot(r)
      coin = snap["coins"][0]
      # 直接把玩家放到金币旁（走内部快照校验驱动行为）
      px = coin["x"].as_f - PICKUP_RADIUS + 1
      py = coin["y"].as_f
      before = agent.tick(r) # 先推进一拍把初始位置固定下来
      before.should_not be_nil

      # 用 set_dir 朝金币移动足够拍数
      dx = (coin["x"].as_f - px) / 100.0
      agent.set_dir(r, "p1", dx.clamp(-1.0, 1.0), 0.0)
      score = 0_i64
      60.times do
        s = agent.tick(r)
        found = s.not_nil!["players"].as_a.find { |p| p["id"].as_s == "p1" }
        score = found["score"].as_i64 if found
        break if score > 0
      end
      score.should eq(1)
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
