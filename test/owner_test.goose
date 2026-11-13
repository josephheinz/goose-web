// The owner transport alone: 4 workers each ask the owner (main) 1000 times, then leave; owner_loop must return.
//   goose build test/owner_test.goose && test/owner_test
import gweb from "..";
import net from "../../goose-net";
import gweb.ops.owner;
import std;

struct Todo { id: i64, title: u8[..64], done: bool }
enum Msg { Add { title: u8[..64] }, Count, List }
struct Reply { ok: bool, n: i64, todos: Todo[] }
struct Done { worker: i64, ok: i64, last: i64 }

var todos: Todo[>..<];
var next_id = 1;

fn handle(m: Msg) -> Reply {
    match m {
        Add a => {
            todos.push(Todo { id: next_id, title: a.title, done: false });
            next_id += 1;
            return Reply { ok: true, n: todos.len, todos: [] };
        },
        Count => { return Reply { ok: true, n: todos.len, todos: [] }; },
        List => { return Reply { ok: true, n: todos.len, todos: todos[..] }; },
    }
}

thread_fn worker(i: i64, fd: i32, c: gweb::Channels) {
    var ok = 0;
    var last = 0;
    for k in 1000 {
        var title: u8[..64] = "";
        format(title, "w", i, "-", k);
        let r, sent = gweb::_owner_call_fd<Msg, Reply>(fd, Msg.Add { title: title });
        if sent && r.ok { ok += 1; last = r.n; }
    }
    let l, lok = gweb::_owner_call_fd<Msg, Reply>(fd, Msg.List);
    qput(Done { worker: i, ok: ok, last: if lok { l.todos.len } else { -1 } });
    gweb::_owner_leave(c);
}

thread_fn reporter(n: i64) {
    var total = 0;
    var listed = 0;
    for i in n { let d = qget<Done>(); total += d.ok; listed = max(listed, d.last); }
    print(total, " adds acknowledged, largest list ", listed);
    exit(if total == n * 1000 && listed == n * 1000 { 0 } else { 1 });
}

fn main() {
    let n = 4;
    let c = gweb::_owner_channels(n);
    
    for i in n { thread_spawn(worker, i, gweb::_worker_end(c, i), c); }
    gweb::_owner_leave(gweb::Channels { handle: 0, n: 0 });   // a no-op for a handle that was never made
    let rid = thread_spawn(reporter, n);
    gweb::_owner_loop<Msg, Reply>(c, handle);   // returns once all four workers have left
    print("owner loop returned");
    thread_wait(rid);
}
