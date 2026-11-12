import std;
import net.http;
import web;
import web.testing;

fn test_x(t: web::Tester&) {
    let res = site::get(t, "/");
    web::expect_status(t, res, 200);
    web::expect_status(t, res, 201);
}
