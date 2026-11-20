// Coin Rush 服务器（Go，无 Troupe 框架——goroutine + 互斥锁手写同等的
// "每房间一个串行实例"语义；生态内尚无 troupe-go，本实现可作为其雏形）。
//
//	go mod tidy && go run .
//
// - WS: ws://host:8787/ws?room=lobby（协议见仓库根 PROTOCOL.md）
// - 静态：检测到同级 ../coin-rush-client 时同端口托管
// - 落盘：JSON 快照（.coin-rush/<room>.json），5s 攒批 + 断线即写
package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/coder/websocket"
)

func sanitize(value, fallback string, limit int) string {
	var b strings.Builder
	for _, c := range value {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			c == '-' || c == '_' || c > 0x2E80 // 保留 CJK
		if ok {
			b.WriteRune(c)
		}
	}
	out := b.String()
	if len([]rune(out)) > limit {
		r := []rune(out)
		out = string(r[:limit])
	}
	if out == "" {
		return fallback
	}
	return out
}

func main() {
	port := "8787"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	clientDir := "../coin-rush-client"
	staticOK := false
	if st, err := os.Stat(clientDir); err == nil && st.IsDir() {
		staticOK = true
	}

	hub := newHub()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, req *http.Request) {
		room := sanitize(req.URL.Query().Get("room"), "lobby", 32)
		c, err := websocket.Accept(w, req, nil)
		if err != nil {
			return
		}
		defer c.Close(websocket.StatusNormalClosure, "")
		handleConn(hub, c, room, req)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, req *http.Request) {
		if !staticOK {
			w.Header().Set("content-type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"service":"coin-rush-go"}`)
			return
		}
		name := req.URL.Path
		if name == "/" {
			name = "/index.html"
		}
		full := filepath.Join(clientDir, filepath.Clean(name))
		if !strings.HasPrefix(filepath.Clean(full), filepath.Clean(clientDir)) {
			http.NotFound(w, req)
			return
		}
		http.ServeFile(w, req, full)
	})

	addr := "127.0.0.1:" + port
	fmt.Printf("🪙 Coin Rush (go): ws://%s/ws?room=lobby\n", addr)
	fmt.Printf("   静态: %v\n", staticOK)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
