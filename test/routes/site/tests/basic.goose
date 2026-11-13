import std;
import net.http;
import gweb;
import gweb.testing;

fn test_page(t: gweb::Tester&) {
    let res = site::get(t, "/");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "<h1>Counter</h1>");
    gweb::expect_contains(t, res.body, "count: 0");
}

fn test_route_json(t: gweb::Tester&) {
    let res = site::get(t, "/api/hello");
    gweb::expect_status(t, res, 200);
    gweb::expect_header(t, res, "content-type", "application/json");
    gweb::expect_contains(t, res.body, "\"hello\":\"world\"");
}

fn test_static_file(t: gweb::Tester&) {
    let res = site::get(t, "/hello.txt");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "static file");
}

// The CSRF cookie and token come from the jar; no token handling here.
fn test_post_form(t: gweb::Tester&) {
    site::get(t, "/");
    let res = site::post_form(t, "/", "x=1");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "count: 1");
}

// The state is shared, so each POST sees the earlier ones.
fn test_counter_second(t: gweb::Tester&) {
    let res = site::post_form(t, "/", "x=1");
    gweb::expect_contains(t, res.body, "count: 2");
}

fn test_counter_third(t: gweb::Tester&) {
    let res = site::post_form(t, "/", "x=1");
    gweb::expect_contains(t, res.body, "count: 3");
    gweb::expect_contains(t, site::get(t, "/").body, "count: 3");
}
