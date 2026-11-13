import std;

// Msg carries a variable-size payload, so it is used as Msg.. (DESIGN-ADDENDUM-19, E4).
const VARIABLE_MSG = true;

enum Msg { Save { doc: u8[] }, Count }
struct Reply { n: i64, total: i64, saves: i64 }

var total: i64 = 0;
var saves: i64 = 0;

fn handle(m: const Msg..&) -> Reply {
    match m {
        Save s => {
            total += s.doc.len;
            saves += 1;
            return Reply { n: s.doc.len, total: total, saves: saves };
        },
        Count => { return Reply { n: 0, total: total, saves: saves }; },
    }
}
