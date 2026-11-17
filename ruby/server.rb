# frozen_string_literal: true

# Coin Rush 服务器（Ruby / troupe.rb）：puma + faye-websocket 边缘层。
#
#   bundle install && bundle exec ruby server.rb [端口]
#
# - WS: ws://host:port/ws?room=lobby（协议见仓库根 PROTOCOL.md）
# - 静态：检测到同级 ../coin-rush-client 时同端口托管
#
# 并发模型：puma 多线程处理连接；房间状态由 troupe.rb Actor 严格串行；
# 游戏循环由边缘驱动线程（Driver）每 100ms cast :tick 并广播返回的快照。

require "puma"
require "puma/server"
require "faye/websocket"
require "json"
require "securerandom"
require "rack"
require "socket"
require "troupe"
require_relative "protocol"
require_relative "room_actor"

module CoinRush
  # 边缘：房间 → 连接集合 + 100ms 驱动线程。
  class Edge
    attr_reader :troupe

    def initialize
      @troupe = Troupe.form(actors: [CoinRush::RoomActor])
      @lock = Mutex.new
      @rooms = Hash.new { |h, k| h[k] = {} }   # room => { conn_id => ws }
      @conns = {}                              # conn_id => { ws:, room:, player_id: }
      @driver = Thread.new { drive_loop }
    end

    def call(env)
      unless Faye::WebSocket.websocket?(env)
        return serve_static(env)
      end

      ws = Faye::WebSocket.new(env)
      conn_id = SecureRandom.uuid
      room = CoinRush.sanitize(
        Rack::Utils.parse_query(env["QUERY_STRING"])["room"], "lobby", 32
      )
      conn = { ws: ws, room: room, player_id: nil, id: conn_id }
      @lock.synchronize { @conns[conn_id] = conn }

      ws.on(:message) do |event|
        handle(conn, event.data)
      rescue StandardError => e
        warn "[edge] 消息处理失败: #{e.message}"
      end

      ws.on(:close) do
        cleanup(conn)
      end

      ws.rack_response
    end

    def shutdown
      @troupe.shutdown!
      @driver.kill
    end

    private

    def handle(conn, raw)
      msg = JSON.parse(raw.to_s)
      case msg["type"]
      when "join"
        name = CoinRush.sanitize(msg["name"], "玩家", 12)
        conn[:player_id] ||= SecureRandom.uuid
        agent = @troupe.cast(CoinRush::RoomActor, conn[:room])
        snap = agent.join(conn[:player_id], name)
        @lock.synchronize { @rooms[conn[:room]][conn[:id]] = conn }
        ws_send(conn, CoinRush.hello(conn[:player_id], snap))
      when "move"
        return unless conn[:player_id]
        agent = @troupe.cast(CoinRush::RoomActor, conn[:room])
        agent.set_dir(conn[:player_id], msg["dx"].to_f, msg["dy"].to_f)
      end
    end

    def cleanup(conn)
      @lock.synchronize do
        @conns.delete(conn[:id])
        @rooms[conn[:room]]&.delete(conn[:id])
      end
      return unless conn[:player_id]
      @troupe.cast(CoinRush::RoomActor, conn[:room]).leave(conn[:player_id])
    end

    # 100ms 驱动：对有连接的房间 cast :tick，把返回的快照推给同房间连接。
    def drive_loop
      loop do
        sleep CoinRush::TICK_MS / 1000.0
        rooms = @lock.synchronize do
          @rooms.select { |_, conns| !conns.empty? }.keys.dup
        end
        rooms.each do |room|
          snap = @troupe.cast(CoinRush::RoomActor, room).tick
          next unless snap.is_a?(Hash) && snap["players"].is_a?(Array)
          frame = JSON.generate(CoinRush.state(snap))
          conns = @lock.synchronize { @rooms[room].values.dup }
          conns.each { |conn| ws_send(conn, frame, raw: true) }
        rescue StandardError => e
          warn "[driver] tick #{room} 失败: #{e.message}"
        end
      end
    end

    def ws_send(conn, payload, raw: false)
      ws = conn[:ws]
      return unless ws&.ready_state == Faye::WebSocket::OPEN
      ws.send(raw ? payload : JSON.generate(payload))
    rescue StandardError
      nil
    end

    # ---- 静态托管（../coin-rush-client 存在时） ----

    STATIC_TYPES = {
      ".html" => "text/html; charset=utf-8",
      ".js" => "text/javascript; charset=utf-8",
      ".css" => "text/css; charset=utf-8",
      ".svg" => "image/svg+xml",
    }.freeze

    def serve_static(env)
      return [404, { "content-type" => "application/json" }, [%({"service":"coin-rush-ruby"})]] unless defined?(@static_dir)
      path = env["PATH_INFO"].to_s
      file = path == "/" ? "index.html" : path.delete_prefix("/")
      return [404, { "content-type" => "application/json" }, [%({"service":"coin-rush-ruby"})]] if file.include?("..")
      full = File.join(@static_dir, file)
      return [404, { "content-type" => "application/json" }, [%({"service":"coin-rush-ruby"})]] unless File.file?(full)
      [200, { "content-type" => STATIC_TYPES[File.extname(full)] || "application/octet-stream" }, [File.read(full)]]
    end
  end
end

# 静态目录探测放最外层（Edge 实例化之前），再补一个 attr_reader。
static_dir = nil
candidate = File.expand_path("../../coin-rush-client", __dir__)
static_dir = candidate if Dir.exist?(candidate)

app = CoinRush::Edge.new
app.instance_variable_set(:@static_dir, static_dir)
at_exit do
  app.shutdown
end

puts "🪙 Coin Rush (ruby): ws://127.0.0.1:8787/ws?room=lobby"
puts "   静态: #{static_dir ? "同端口托管 #{static_dir}" : "未检测到 ../coin-rush-client，请用 ?server= 指向"}"

puma = Puma::Server.new(app)
puma.add_tcp_listener "127.0.0.1", ENV.fetch("PORT", "8787").to_i
puma.min_threads = 0
puma.max_threads = 16
puma.run.join
