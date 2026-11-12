import std;

enum Msg { Inc, Get }
struct Reply { n: i64 }

var count = 0;

fn handle(msg: const Msg&) -> Reply {
    match msg {
        Inc => { count += 1; },
        Get => {},
    }
    return Reply { n: count };
}
