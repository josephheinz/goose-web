import std;

enum Msg { Next }
struct Reply { n: i64 }

var counter: i64 = 0;

fn handle(msg: const Msg&) -> Reply {
    counter += 1;
    return Reply { n: counter };
}
