package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Conn —— 一条玩家连接：读写各一个 goroutine，出站经有界 channel。
type Conn struct {
	id       string
	ws       *websocket.Conn
	room     string
	playerID string
	name     string
	out      chan []byte
	hub      *Hub
}

func (c *Conn) writeLoop() {
	defer func() {
		c.hub.disconnect(c)
		c.ws.Close(websocket.StatusNormalClosure, "")
	}()
	for frame := range c.out {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := c.ws.Write(ctx, websocket.MessageText, frame)
		cancel()
		if err != nil {
			return
		}
	}
}

// Hub —— 房间注册表 + 连接注册表 + 广播。
type Hub struct {
	mu      sync.Mutex
	rooms   map[string]*Room
	conns   map[string]*Conn
	wgRooms sync.WaitGroup
}

func newHub() *Hub {
	h := &Hub{rooms: map[string]*Room{}, conns: map[string]*Conn{}}
	go h.idleSweep()
	return h
}

func (h *Hub) room(name string) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	r, ok := h.rooms[name]
	if !ok {
		r = NewRoom(name)
		h.rooms[name] = r
		h.wgRooms.Add(1)
		go func() {
			defer h.wgRooms.Done()
			r.run(h)
		}()
	}
	return r
}

func (h *Hub) broadcast(room string, frame map[string]any) {
	raw, _ := json.Marshal(frame)
	h.mu.Lock()
	conns := make([]*Conn, 0, len(h.conns))
	for _, c := range h.conns {
		if c.room == room {
			conns = append(conns, c)
		}
	}
	h.mu.Unlock()
	for _, c := range conns {
		select {
		case c.out <- raw:
		default: // 慢消费者：丢帧（在线尽力）
		}
	}
}

func (h *Hub) sendTo(connID string, frame map[string]any) {
	h.mu.Lock()
	c := h.conns[connID]
	h.mu.Unlock()
	if c == nil {
		return
	}
	raw, _ := json.Marshal(frame)
	select {
	case c.out <- raw:
	default:
	}
}

func (h *Hub) disconnect(c *Conn) {
	h.mu.Lock()
	if _, ok := h.conns[c.id]; !ok {
		h.mu.Unlock()
		return
	}
	delete(h.conns, c.id)
	r := h.rooms[c.room]
	h.mu.Unlock()
	close(c.out)
	if r != nil && c.playerID != "" {
		r.mu.Lock()
		r.leave(c.playerID)
		empty := len(r.players) == 0
		r.mu.Unlock()
		_ = empty
	}
}

// idleSweep：无玩家且 10 分钟无活动的房间回收 ticker（Actor 下场语义）。
func (h *Hub) idleSweep() {
	for {
		time.Sleep(60 * time.Second)
		h.mu.Lock()
		for name, r := range h.rooms {
			r.mu.Lock()
			idle := len(r.players) == 0 && time.Since(r.lastActive) > idleEvictSecs*time.Second
			r.mu.Unlock()
			if idle {
				r.stopTicker()
				delete(h.rooms, name)
			}
		}
		h.mu.Unlock()
	}
}

// handleConn —— 单连接生命周期：join/set_dir 上行 → actor；出站由 writeLoop。
func handleConn(h *Hub, c *websocket.Conn, room string, req *http.Request) {
	conn := &Conn{
		id:   fmt.Sprintf("%x", time.Now().UnixNano()),
		ws:   c,
		room: room,
		out:  make(chan []byte, 256),
		hub:  h,
	}
	h.mu.Lock()
	h.conns[conn.id] = conn
	r := h.room(room)
	h.mu.Unlock()

	go conn.writeLoop()

	ctx := context.Background()
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return // 连接关闭 → writeLoop 的 defer 走 disconnect
		}
		var msg map[string]any
		if json.Unmarshal(data, &msg) != nil {
			continue
		}
		switch msg["type"] {
		case "join":
			name := sanitize(asString(msg["name"]), "玩家", 12)
			conn.playerID = fmt.Sprintf("%s", conn.id)
			r.mu.Lock()
			p := r.join(conn.playerID, name)
			if p == nil {
				r.mu.Unlock()
				sendErr(conn, "房间已满")
				return
			}
			snap := r.snapshot()
			r.mu.Unlock()
			push(conn, map[string]any{"type": "hello", "playerId": conn.playerID, "snapshot": snap})
		case "move":
			if conn.playerID == "" {
				continue
			}
			dx := asFloat(msg["dx"])
			dy := asFloat(msg["dy"])
			r.mu.Lock()
			r.setDir(conn.playerID, dx, dy)
			r.mu.Unlock()
		}
	}
}

func push(c *Conn, frame map[string]any) {
	raw, _ := json.Marshal(frame)
	select {
	case c.out <- raw:
	default:
	}
}

func sendErr(c *Conn, message string) {
	push(c, map[string]any{"type": "error", "message": message})
}

func asString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func asFloat(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case int:
		return float64(n)
	default:
		return 0
	}
}
