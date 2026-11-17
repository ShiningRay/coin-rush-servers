# 边缘进程：troupe-gateway（WS 会话/静态托管）+ 100ms 驱动循环（tick Turn）。
#
# 上行：join → 生成 playerId → agent.join → hello；move → agent.set_dir；
#       断线 → agent.leave + 房间成员表清理。
# 下行：on_outbox 的 snapshot 事件 → 按房间路由给同房间全部连接（state 帧）。
# 驱动：每 100ms 对"有连接的房间"调用 tick Turn，返回快照即广播。

require "http"
require "json"
require "troupe-gateway"
require "./room_actor"

module CoinRush
  class Edge
    @room_conns = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
    @mutex = Mutex.new
    @agent : RoomActor::Agent
    @gw : Troupe::Gateway::WebSocket
    @stopped = false

    def initialize(@store : Troupe::PropStore, static_dir : String?)
      @agent = RoomActor::Agent.new(@stage = Troupe::Stage.new(store: @store, ownership: @store.ownership))
      @gw = Troupe::Gateway::WebSocket.new(@store, Troupe::Gateway::Config.new(
        service_name: "coin-rush-crystal",
        static_dir: static_dir,
      ))
      @stage.register(RoomActor.troupe_manifest)

      @gw.on_message = ->(session : Troupe::Gateway::Session, raw : String) { handle_raw(session, raw) }
      @gw.on_disconnect = ->(session : Troupe::Gateway::Session) { cleanup(session) }
      @gw.on_outbox = ->(record : Troupe::OutboxRecord) { deliver_snapshot(record) }
    end

    def listen(host : String, port : Int32) : Int32
      port = @gw.listen(host, port)
      spawn(name: "coin-rush-driver") { drive_loop }
      port
    end

    def stop : Nil
      @stopped = true
      @gw.stop
    end

    # ---- 上行路由 ----

    private def handle_raw(session : Troupe::Gateway::Session, raw : String) : Nil
      msg = JSON.parse(raw)
      case msg["type"]?.try(&.as_s)
      when "join"
        room = sanitize(session.query["room"]?, "lobby", 32)
        name = sanitize(msg["name"]?.try(&.as_s?), "玩家", 12)
        player_id = session.meta["player_id"]? || Random::Secure.hex(16)
        session.meta["player_id"] = player_id
        session.meta["room"] = room
        @mutex.synchronize { @room_conns[room].add(session.id) }
        begin
          welcome = @agent.join(room_id(room), player_id, name)
        rescue ex : RoomFullError
          @gw.deliver(session, Protocol.error("房间已满"))
          return
        rescue ex
          @gw.deliver(session, Protocol.error(ex.message || "join failed"))
          return
        end
        @gw.deliver(session, Protocol.hello(player_id, welcome))
      when "move"
        room = session.meta["room"]?
        player_id = session.meta["player_id"]?
        return unless room && player_id
        dx = msg["dx"]?.try(&.as_f?) || 0.0
        dy = msg["dy"]?.try(&.as_f?) || 0.0
        @agent.set_dir(room_id(room), player_id, dx, dy)
      end
    rescue ex
      STDERR.puts "[edge] 处理消息失败: #{ex.message}"
    end

    private def cleanup(session : Troupe::Gateway::Session) : Nil
      room = session.meta["room"]?
      player_id = session.meta["player_id"]?
      return unless room && player_id
      @mutex.synchronize { @room_conns[room]?.try(&.delete(session.id)) }
      @agent.leave(room_id(room), player_id)
    rescue ex
      STDERR.puts "[edge] 断线清理失败: #{ex.message}"
    end

    # ---- Outbox 快照路由 ----

    private def deliver_snapshot(record : Troupe::OutboxRecord) : Nil
      return unless record.topic == "snapshot"
      room = record.actor_id.key
      frame = Protocol.state(record.payload)
      conns = @mutex.synchronize do
        set = @room_conns[room]?
        set ? set.to_a : ([] of String)
      end
      conns.each do |conn|
        @mutex.synchronize { @room_conns[room]?.try(&.delete(conn)) } unless @gw.deliver_id(conn, frame)
      end
    end

    # ---- 100ms 驱动循环 ----

    private def drive_loop : Nil
      until @stopped
        rooms = @mutex.synchronize do
          @room_conns.select { |_, conns| !conns.empty? }.keys
        end
        rooms.each do |room|
          snap = @agent.tick(room_id(room)) # 空房间 Turn 内自会跳过
          frame = Protocol.state(snap)
          conns = @mutex.synchronize do
            set = @room_conns[room]?
            set ? set.to_a : ([] of String)
          end
          conns.each do |conn|
            @mutex.synchronize { @room_conns[room]?.try(&.delete(conn)) } unless @gw.deliver_id(conn, frame)
          end
        rescue ex
          STDERR.puts "[driver] tick #{room} 失败: #{ex.message}"
        end
        sleep TICK_MS.milliseconds
      end
    end

    private def room_id(name : String) : Troupe::ActorId
      id = @mutex.synchronize { @rooms_map[name] ||= Troupe::ActorId.new("coinrush", "room", name) }
      @gw.track(id)
      id
    end

    @rooms_map = {} of String => Troupe::ActorId

    private def sanitize(value : String?, fallback : String, limit : Int32) : String
      cleaned = value || ""
      # PCRE2 不支持 \u 转义：CJK 用码点区间 \x{4e00}-\x{9fa5}
      cleaned = cleaned.gsub(/[^\w\x{4e00}-\x{9fa5}-]/, "")[0, limit]
      cleaned.empty? ? fallback : cleaned
    end
  end

  # 协议帧组装（形状契约见 PROTOCOL.md）。
  # 注意 JSON::Any 内嵌时必须 to_json（to_s 是调试表示，含 "=>"）。
  module Protocol
    def self.hello(player_id : String, snapshot : JSON::Any) : JSON::Any
      build(%({"type":"hello","playerId":#{player_id.inspect},"snapshot":#{snapshot.to_json}}))
    end

    def self.state(snapshot : JSON::Any) : JSON::Any
      build(%({"type":"state","snapshot":#{snapshot.to_json}}))
    end

    def self.error(message : String) : JSON::Any
      build(%({"type":"error","message":#{message.inspect}}))
    end

    private def self.build(raw : String) : JSON::Any
      JSON.parse(raw)
    end
  end
end
