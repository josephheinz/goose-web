// The operations suite's state. $OPS_DIR names a folder the test controls:
//   OPS_DIR/fail_init   exists when init runs: init exits 1 (the child of a handoff that cannot start)
//   OPS_DIR/shutdown    written by shutdown (a graceful stop reached the end of main)
import std;
import os;

enum Msg { Add { n: i64 }, Tick, Get }
struct Reply { count: i64 = 0, ticks: i64 = 0, token: u8[..32] = "" }

var count: i64 = 0;
var ticks: i64 = 0;
var token: u8[..32] = "";

fn marker(name: const u8[:], out: u8[>..]&) -> bool {
    var dir: u8[>..] = [];
    if !env("OPS_DIR", dir) || dir.len == 0 { return false; }
    format(out, dir, "/", name);
    return true;
}

fn init() {
    var p: u8[>..] = [];
    if marker("fail_init", p) && file_exists(p) { print("ops: init refused by the test"); exit(1); }
    var t: u8[>..] = [];
    format(t, random_seed());
    token.clear();
    token.append(t[..min(t.len, 32)]);
}

fn shutdown() {
    var p: u8[>..] = [];
    if marker("shutdown", p) { write_file(p, "done\n"); }
}

fn handle(msg: const Msg&) -> Reply {
    match msg {
        Add a => { count += a.n; },
        Tick => { ticks += 1; },
        Get => {},
    }
    Reply { count: count, ticks: ticks, token: token }
}
