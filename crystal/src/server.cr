# Coin Rush 服务器入口（Crystal / troupe.cr + troupe-gateway）。
#
#   crystal run src/server.cr -- -p 8787
#
# - WS: ws://host:port/ws?room=lobby（协议见仓库根 PROTOCOL.md）
# - 静态：检测到同级 ../coin-rush-client 时同端口托管

require "option_parser"
require "./coin_rush/edge"

module CoinRush
  def self.run(argv : Array(String)) : {Troupe::Stage, Edge}
    host = "127.0.0.1"
    port = 8787
    db = ".coin-rush/rooms.db"
    client_dir = File.expand_path("../../coin-rush-client", __DIR__)

    OptionParser.parse(argv) do |p|
      p.banner = "Coin Rush server (Crystal)"
      p.on("-H HOST", "--host=HOST", "监听地址") { |v| host = v }
      p.on("-p PORT", "--port=PORT", "端口") { |v| port = v.to_i }
      p.on("-d PATH", "--db=PATH", "SQLite 路径或 :memory:") { |v| db = v }
      p.on("--no-client", "不托管同级 coin-rush-client 静态目录") { client_dir = "" }
      p.on("-h", "--help") do
        puts p
        exit 0
      end
    end

    store = db == ":memory:" ? Troupe::MemoryPropStore.new(Troupe::MemoryOwnershipStore.new) : begin
      Dir.mkdir_p(File.dirname(db))
      Troupe::SQLitePropStore.open(db)
    end
    static_dir = !client_dir.empty? && Dir.exists?(client_dir) ? client_dir : nil

    edge = Edge.new(store, static_dir)
    actual = edge.listen(host, port)
    puts "🪙 Coin Rush (crystal): ws://#{host}:#{actual}/ws?room=lobby"
    puts "   静态: #{static_dir ? "同端口托管 #{static_dir}" : "未检测到 ../coin-rush-client，请用 ?server= 指向"}"
    {store, edge}
  end
end

CoinRush.run(ARGV)
sleep
