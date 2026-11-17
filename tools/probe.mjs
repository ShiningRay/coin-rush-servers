#!/usr/bin/env node
/**
 * Coin Rush 服务器冒烟探针（Node ≥ 21，原生 WebSocket）。
 *
 *   node tools/probe.mjs ws://127.0.0.1:8787/ws?room=probe
 *
 * 校验：连接 → join → 收到 hello（含 playerId 与快照）→ 3s 内收到 state 广播 → PASS。
 * 全部通过 exit 0；任一超时/形状不符 exit 1。
 */
import { setTimeout as delay } from "node:timers/promises";

const url = process.argv[2];
if (!url) {
  console.error("usage: node tools/probe.mjs <ws-url>");
  process.exit(2);
}

const ws = new WebSocket(url);
let stage = "connect";
const fail = (msg) => {
  console.error(`FAIL [${stage}] ${msg}`);
  process.exit(1);
};

ws.onerror = () => fail("websocket error");
ws.onclose = () => fail("closed before hello");

const hello = new Promise((resolve) => {
  ws.onmessage = (ev) => {
    const msg = JSON.parse(String(ev.data));
    if (msg.type === "hello") {
      stage = "hello";
      if (!msg.playerId) fail("hello 缺 playerId");
      const s = msg.snapshot;
      if (!s || !Array.isArray(s.players) || !Array.isArray(s.coins) || typeof s.tick !== "number")
        fail("hello 快照形状不符");
      resolve();
    }
  };
});

ws.onopen = () => {
  stage = "join";
  ws.send(JSON.stringify({ type: "join", name: "probe" }));
};

await Promise.race([hello, delay(3000).then(() => fail("等待 hello 超时"))]);
console.log(`hello OK: players=${"见快照"}，进入广播等待`);

stage = "state";
const gotState = new Promise((resolve) => {
  ws.onmessage = (ev) => {
    const msg = JSON.parse(String(ev.data));
    if (msg.type === "state" && msg.snapshot) resolve();
  };
});
await Promise.race([gotState, delay(3000).then(() => fail("等待 state 广播超时"))]);

console.log("PASS: hello + state 广播均符合协议");
process.exit(0);
