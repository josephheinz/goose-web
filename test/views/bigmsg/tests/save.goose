import std;
import net.http;
import gweb;
import gweb.testing;

fn test_variable_message(t: gweb::Tester&) {
    var body: u8[>..] = [];
    for i in 70000 { body.push('a'); }
    let res = site::post_form(t, "/save", body);
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "ok=true n=70000 total=70000 saves=1");
}
