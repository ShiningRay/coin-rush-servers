// Room —— Coin Rush 的"每房间一个 Actor"语义：一把互斥锁串行化全部状态变更，
// 独立 goroutine 的 100ms ticker 扮演游戏循环（有玩家才推进），5s 攒批落盘。
package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	arenaW        = 800.0
	arenaH        = 600.0
	tickMs        = 100
	playerSpeed   = 240.0
	playerRadius  = 14.0
	coinCount     = 8
	coinRadius    = 9.0
	coinValue     = 1
	pickupRadius  = playerRadius + coinRadius
	maxPlayers    = 16
	flushTicks    = 50 // 5s
	idleEvictSecs = 600
)

var colors = []string{
	"#ef4444", "#22c55e", "#3b82f6", "#f97316", "#a855f7", "#14b8a6",
	"#ec4899", "#84cc16", "#f59e0b", "#06b6d4", "#8b5cf6", "#e11d48",
}

type Player struct {
	ID    string  `json:"id"`
	Name  string  `json:"name"`
	Color string  `json:"color"`
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
	DX    float64 `json:"dx"`
	DY    float64 `json:"dy"`
	Score int64   `json:"score"`
}

type Coin struct {
	ID int64   `json:"id"`
	X  float64 `json:"x"`
	Y  float64 `json:"y"`
}

type Room struct {
	mu      sync.Mutex
	name    string
	tick    int64
	seq     int64
	players map[string]*Player
	coins   []*Coin
	dirty   bool

	tickerStop chan struct{}
	once       sync.Once
	lastActive time.Time
}

func NewRoom(name string) *Room {
	r := &Room{
		name:       name,
		players:    map[string]*Player{},
		tickerStop: make(chan struct{}),
		lastActive: time.Now(),
	}
	r.load()
	return r
}

// ---- 状态操作（全部要求持有 r.mu，由 Hub/驱动统一加锁） ----

func (r *Room) join(playerID, name string) *Player {
	if p, ok := r.players[playerID]; ok {
		return p // 重连幂等：存在即返回
	}
	if len(r.players) >= maxPlayers {
		return nil // 满员：由 Hub 转成 error 帧
	}
	r.seq++
	p := &Player{
		ID:    playerID,
		Name:  name,
		Color: colors[int(r.seq)%len(colors)],
		X:     playerRadius + rand01()*(arenaW-playerRadius*2),
		Y:     playerRadius + rand01()*(arenaH-playerRadius*2),
	}
	r.players[playerID] = p
	for len(r.coins) < coinCount {
		r.coins = append(r.coins, r.spawnCoin())
	}
	r.dirty = true
	return p
}

func (r *Room) setDir(playerID string, dx, dy float64) {
	p, ok := r.players[playerID]
	if !ok {
		return
	}
	p.DX = clamp(dx, -1, 1)
	p.DY = clamp(dy, -1, 1)
}

func (r *Room) leave(playerID string) {
	if _, ok := r.players[playerID]; !ok {
		return
	}
	delete(r.players, playerID)
	r.dirty = true
	r.save() // 断线即刻落盘（与 TS 版 leave 一致）
}

// advance 推进一拍：移动 + 吃币判定 + 广播回调。返回快照（无玩家返回 nil）。
func (r *Room) advance() map[string]any {
	r.tick++
	if len(r.players) == 0 {
		return nil
	}
	step := playerSpeed * float64(tickMs) / 1000.0
	for _, p := range r.players {
		if p.DX == 0 && p.DY == 0 {
			continue
		}
		l := math.Hypot(p.DX, p.DY)
		p.X = clamp(p.X+(p.DX/l)*step, playerRadius, arenaW-playerRadius)
		p.Y = clamp(p.Y+(p.DY/l)*step, playerRadius, arenaH-playerRadius)
	}
	for _, c := range r.coins {
		for _, p := range r.players {
			if math.Hypot(p.X-c.X, p.Y-c.Y) < pickupRadius {
				p.Score += coinValue
				nc := r.spawnCoin()
				c.ID, c.X, c.Y = nc.ID, nc.X, nc.Y // 原地重生
				break
			}
		}
	}
	r.dirty = true
	if r.tick%flushTicks == 0 {
		r.save()
	}
	return r.snapshot()
}

func (r *Room) snapshot() map[string]any {
	players := make([]map[string]any, 0, len(r.players))
	for _, p := range r.players {
		players = append(players, map[string]any{
			"id": p.ID, "name": p.Name, "color": p.Color,
			"x": p.X, "y": p.Y, "score": p.Score,
		})
	}
	coins := make([]map[string]any, 0, len(r.coins))
	for _, c := range r.coins {
		coins = append(coins, map[string]any{"id": c.ID, "x": c.X, "y": c.Y})
	}
	return map[string]any{"tick": r.tick, "players": players, "coins": coins}
}

func (r *Room) spawnCoin() *Coin {
	r.seq++
	return &Coin{ID: r.seq,
		X: playerRadius + rand01()*(arenaW-playerRadius*2),
		Y: playerRadius + rand01()*(arenaH-playerRadius*2)}
}

// ---- 落盘：JSON 快照（.coin-rush/<room>.json），5s 攒批 + 退出/断线即写 ----

func (r *Room) save() {
	if !r.dirty {
		return
	}
	data, err := json.Marshal(r.snapshot())
	if err != nil {
		return
	}
	dir := ".coin-rush"
	_ = os.MkdirAll(dir, 0o755)
	path := filepath.Join(dir, sanitizeFilename(r.name)+".json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp, path)
	r.dirty = false
}

func (r *Room) load() {
	path := filepath.Join(".coin-rush", sanitizeFilename(r.name)+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var snap struct {
		Tick    int64            `json:"tick"`
		Players []*Player        `json:"players"`
		Coins   []*Coin          `json:"coins"`
	}
	if json.Unmarshal(data, &snap) != nil {
		return
	}
	r.tick = snap.Tick
	for _, p := range snap.Players {
		p.DX, p.DY = 0, 0
		r.players[p.ID] = p
	}
	for _, c := range snap.Coins {
		r.coins = append(r.coins, c)
	}
	// 恢复后补齐金币（老快照可能少于 COIN_COUNT）
	for len(r.coins) < coinCount {
		r.coins = append(r.coins, r.spawnCoin())
	}
}

// ---- 游戏循环 goroutine：有玩家才推进；空转 10 分钟由 Hub 决定回收 ----

func (r *Room) run(hub *Hub) {
	t := time.NewTicker(time.Duration(tickMs) * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-r.tickerStop:
			return
		case <-t.C:
			r.mu.Lock()
			r.lastActive = time.Now()
			snap := r.advance()
			r.mu.Unlock()
			if snap != nil {
				hub.broadcast(r.name, map[string]any{"type": "state", "snapshot": snap})
			}
		}
	}
}

func (r *Room) stopTicker() {
	r.once.Do(func() { close(r.tickerStop) })
}

func clamp(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func sanitizeFilename(name string) string {
	out := make([]byte, 0, len(name))
	for _, c := range name {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' {
			out = append(out, byte(c))
		}
	}
	if len(out) == 0 {
		return "lobby"
	}
	return string(out)
}
