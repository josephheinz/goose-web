import std;
import net.http;
import gweb;
import gweb.testing;
import fakelib;

fn test_hello(t: gweb::Tester&) {
    let res = site::get(t, "/api/hello");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "\"answer\":42");
}
