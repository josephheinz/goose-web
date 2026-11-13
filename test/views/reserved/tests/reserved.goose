import std;
import gweb;
import gweb.testing;

fn test_reserved_prefixes(t: gweb::Tester&) {
    let r = gweb::reserved_prefixes();
    var all: u8[>..] = [];
    for p in r { all.append(p); all.push(' '); }
    gweb::expect(t, all == "__gweb _gw about admin api blog css favicon.ico ", "literal first segments of routes, top-level public names, __gweb and _gw, sorted once each");
    gweb::expect(t, r.len == 8, "eight names");
}
