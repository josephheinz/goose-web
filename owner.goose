// Part of goose-web: the state owner. `main` owns app/state.goose's data;
// workers reach it over one socketpair each (src/owner.c). A message is a
// one-element array of M as a to_bytes image; the reply is one of R.
// Import with `import web.owner;`.

namespace web;

import std;

struct Channels { handle: u64, n: i64 }

extern fn c_chans_new(n: i32) -> u64 = "gweb_chans_new";
extern fn c_chans_worker_fd(h: u64, i: i32) -> i32 = "gweb_chans_worker_fd";
extern fn c_owner_fd(h: u64, i: i32) -> i32 = "gweb_owner_fd";
extern fn c_send_frame(fd: i32, payload: const u8[:]) -> i32 = "gweb_send_frame";
extern fn c_recv_frame(fd: i32, out: u8[>..]&) -> i32 = "gweb_recv_frame";
extern fn c_set_recv_timeout(fd: i32, ms: i64) = "gweb_set_recv_timeout";
extern fn c_owner_next(h: u64, out: u8[>..]&) -> i32 = "gweb_owner_next";

// Makes one channel per worker. Call before spawning the workers.
fn owner_channels(workers: i64) -> Channels {
    Channels { handle: c_chans_new(workers as i32), n: workers }
}

// Worker i's end of its channel, with a 5 second reply timeout.
fn worker_end(c: Channels, i: i64) -> i32 {
    let fd = c_chans_worker_fd(c.handle, i as i32);
    c_set_recv_timeout(fd, 5000);
    return fd;
}

// Sends msg on fd and waits for the reply. False on a timeout, a closed
// channel or a reply that does not verify.
fn owner_call_fd<M, R>(fd: i32, msg: M) -> R, bool {
    var one: M[>..] = [];
    one.push(msg);
    var bytes: u8[>..] = [];
    to_bytes(one, bytes);
    if fd < 0 || c_send_frame(fd, bytes) == 0 { return R { .. }, false; }
    var reply: u8[>..] = [];
    if c_recv_frame(fd, reply) == 0 { return R { .. }, false; }
    let rs, ok = from_bytes<R[>..]>(reply);
    if ok { for r in rs { return copy(r), true; } }
    return R { .. }, false;
}

// Serves the workers forever on the calling thread (main): decodes each
// message, calls H(msg) -> R, sends the reply back to that worker.
fn owner_loop<M, R, H>(c: Channels) {
    var buf: u8[>..] = [];
    var out: u8[>..] = [];
    loop {
        buf.clear();
        let i = c_owner_next(c.handle, buf);
        if i < 0 { print("goose-web: state channel failed"); return; }
        let ms, ok = from_bytes<M[>..]>(buf);
        if !ok { continue; }   // the worker times out
        var replies: R[>..] = [];
        for m in ms { replies.push(H(m)); }
        out.clear();
        to_bytes(replies, out);
        c_send_frame(c_owner_fd(c.handle, i), out);
    }
}
