import std;
import net.http;
import gweb;
import gweb.testing;

fn test_x(t: gweb::Tester&) {
    let res = site::get(t, "/");
    gweb::expect_status(t, res, 200);
    gweb::expect_status(t, res, 201);
}
