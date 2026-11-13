// The tags a gweb outside a checkout declares.

namespace pins;

import std;

let OWNER = "josephheinz";
let TAG = "v0.5.1";

fn pin(repo: const u8[:]) -> u8[>..] {
    var s: u8[>..] = [];
    format(s, OWNER, "/", repo, "@", TAG);
    return s;
}

let PIN_WEB = pin("gweb");
let PIN_NET = pin("goose-net");
let PIN_SQLITE = pin("goose-sqlite");
