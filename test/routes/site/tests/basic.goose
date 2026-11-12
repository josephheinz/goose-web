import std;
import net.http;
import web;
import web.testing;

fn test_page(t: web::Tester&) {
    let res = site::get(t, "/");
    web::expect_status(t, res, 200);
    web::expect_contains(t, res.body, "<h1>Counter</h1>");
    web::expect_contains(t, res.body, "count: 0");
}

fn test_route_json(t: web::Tester&) {
    let res = site::get(t, "/api/hello");
    web::expect_status(t, res, 200);
    web::expect_header(t, res, "content-type", "application/json");
    web::expect_contains(t, res.body, "\"hello\":\"world\"");
}

fn test_static_file(t: web::Tester&) {
    let res = site::get(t, "/hello.txt");
    web::expect_status(t, res, 200);
    web::expect_contains(t, res.body, "static file");
}

// The CSRF cookie and token come from the jar; no token handling here.
fn test_post_form(t: web::Tester&) {
    site::get(t, "/");
    let res = site::post_form(t, "/", "x=1");
    web::expect_status(t, res, 200);
    web::expect_contains(t, res.body, "count: 1");
}

// The state is shared, so each POST sees the earlier ones.
fn test_counter_second(t: web::Tester&) {
    let res = site::post_form(t, "/", "x=1");
    web::expect_contains(t, res.body, "count: 2");
}

fn test_counter_third(t: web::Tester&) {
    let res = site::post_form(t, "/", "x=1");
    web::expect_contains(t, res.body, "count: 3");
    web::expect_contains(t, site::get(t, "/").body, "count: 3");
}
