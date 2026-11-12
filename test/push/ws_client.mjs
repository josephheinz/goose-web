// A minimal WebSocket client for test/push.sh: node:net and node:crypto only.
//   node ws_client.mjs PORT PATH [--origin URL] [--version N] [--chat]
// Prints "status CODE", then (with --chat) "accept ok", "echo ...", "ready", "publish ...", "done".
import net from "node:net";
import crypto from "node:crypto";

const [port, path, ...rest] = process.argv.slice(2);
const opt = (name) => { const i = rest.indexOf(name); return i >= 0 ? rest[i + 1] : undefined; };
const origin = opt("--origin");
const version = opt("--version") ?? "13";
const chat = rest.includes("--chat");
const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const key = crypto.randomBytes(16).toString("base64");
const sock = net.connect(Number(port), "127.0.0.1");
const timer = setTimeout(() => { console.log("timeout"); process.exit(1); }, 10000);

function frame(opcode, payload) {
  const mask = crypto.randomBytes(4);
  const n = payload.length;
  const head = n < 126 ? Buffer.from([0x80 | opcode, 0x80 | n]) : Buffer.from([0x80 | opcode, 0x80 | 126, n >> 8, n & 255]);
  const body = Buffer.from(payload);
  for (let i = 0; i < n; i++) body[i] ^= mask[i % 4];
  return Buffer.concat([head, mask, body]);
}

let buf = Buffer.alloc(0);
let upgraded = false;
let step = 0;

function messages() {
  for (;;) {
    if (buf.length < 2) return;
    let len = buf[1] & 0x7f;
    let at = 2;
    if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); at = 4; }
    if (buf.length < at + len) return;
    const opcode = buf[0] & 0x0f;
    const payload = buf.subarray(at, at + len).toString();
    buf = buf.subarray(at + len);
    if (opcode === 1) onText(payload);
    else if (opcode === 8) { console.log("closed"); process.exit(0); }
  }
}

function onText(text) {
  if (step === 0) {
    console.log("echo " + text);
    console.log("ready");
    step = 1;
  } else {
    console.log("publish " + text);
    sock.write(frame(8, Buffer.from([0x03, 0xe8])));
    console.log("done");
    clearTimeout(timer);
    sock.end();
    setTimeout(() => process.exit(0), 100);
  }
}

sock.on("connect", () => {
  let req = `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
            `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: ${version}\r\n`;
  if (origin) req += `Origin: ${origin}\r\n`;
  sock.write(req + "\r\n");
});

sock.on("data", (d) => {
  buf = Buffer.concat([buf, d]);
  if (!upgraded) {
    const end = buf.indexOf("\r\n\r\n");
    if (end < 0) return;
    const head = buf.subarray(0, end).toString();
    buf = buf.subarray(end + 4);
    const code = head.split(" ")[1];
    console.log("status " + code);
    const v = /^sec-websocket-version: (.*)$/im.exec(head);
    if (v) console.log("version " + v[1].trim());
    if (!chat || code !== "101") { clearTimeout(timer); sock.destroy(); process.exit(0); }
    const accept = /^sec-websocket-accept: (.*)$/im.exec(head);
    const want = crypto.createHash("sha1").update(key + GUID).digest("base64");
    console.log(accept && accept[1].trim() === want ? "accept ok" : "accept wrong");
    upgraded = true;
    sock.write(frame(1, Buffer.from("ping1")));
  }
  messages();
});

sock.on("error", (e) => { console.log("error " + e.message); process.exit(1); });
