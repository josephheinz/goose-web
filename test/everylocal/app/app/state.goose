import std;

enum Msg { Plain, Local, Get }
struct Reply { plain: i64 = 0, local: i64 = 0 }

var plain: i64 = 0;
var local: i64 = 0;

fn handle(msg: const Msg&) -> Reply {
    match msg {
        Plain => { plain += 1; },
        Local => { local += 1; },
        Get => {},
    }
    Reply { plain: plain, local: local }
}
