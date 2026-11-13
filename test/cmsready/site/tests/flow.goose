import std;
import net.http;
import gweb;
import gweb.testing;

fn host(t: gweb::Tester&, h: const u8[:]) {
    t.host.clear();
    t.host.append(h);
}

// Two hosts, two channels: t.host is the Host header of each request.
fn test_public_pages_by_host(t: gweb::Tester&) {
    host(t, "a.test");
    let a = site::get(t, "/");
    gweb::expect_status(t, a, 200);
    gweb::expect_contains(t, a.body, "Home A");
    gweb::expect(t, find(a.body, "Home B") < 0, "channel A does not show B");
    host(t, "b.test");
    let b = site::get(t, "/");
    gweb::expect_status(t, b, 200);
    gweb::expect_contains(t, b.body, "Home B");
    let nope = site::get(t, "/about");
    gweb::expect_status(t, nope, 404);
    host(t, "c.test");
    let unknown = site::get(t, "/");
    gweb::expect_status(t, unknown, 404);
}

// Log in through the mounted package, save a node through its generated form, and see the cached page change.
fn test_login_save_and_cache_epoch(t: gweb::Tester&) {
    host(t, "admin.test");
    let denied = site::get(t, "/admin/shop/orders");
    gweb::expect_status(t, denied, 303);
    gweb::expect_header(t, denied, "location", "/admin/login?next=%2Fadmin%2Fshop%2Forders");
    site::get(t, "/admin/login");
    let login = site::post_form(t, "/admin/login/submit", "username=admin&password=correct+horse&next=%2Fadmin");
    gweb::expect_status(t, login, 303);
    let home = site::get(t, "/admin");
    gweb::expect_status(t, home, 200);
    gweb::expect_contains(t, home.body, "admin-home");
    let orders = site::get(t, "/admin/shop/orders");
    gweb::expect_contains(t, orders.body, "orders=42");

    host(t, "b.test");
    let before = site::get(t, "/");                                    // now in this worker's cache
    gweb::expect_contains(t, before.body, "Home B");
    host(t, "admin.test");
    let bad = site::post_form(t, "/admin/nodes/3", "t.title=x&t.theme=Light&w.body=hi");
    gweb::expect_status(t, bad, 422);
    gweb::expect_contains(t, bad.body, "Use at least 2 characters.");
    let ok = site::post_form(t, "/admin/nodes/3", "t.title=B+tested&t.theme=Dark&w.body=Saved+**now**");
    gweb::expect_status(t, ok, 303);
    host(t, "b.test");
    let after = site::get(t, "/");
    gweb::expect_contains(t, after.body, "B tested");
    gweb::expect_contains(t, after.body, "<strong>now</strong>");
}
