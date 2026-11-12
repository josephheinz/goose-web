// ctx.meta, its setters, site_url and render_meta (DESIGN-ADDENDUM-15 section 3.2), without sockets.
//   goose build test/meta_test.goose && test/meta_test
import web from "..";
import web.meta;
import web.template;
import net from "../../goose-net";
import net.http;
import std;
import os;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}
fn check_eq(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got '", got, "' want '", want, "'"); }
}

fn main() {
    let raw = "GET / HTTP/1.1\r\nHost: ex.test\r\nX-Forwarded-Proto: https\r\n\r\n";
    let req, parsed = http::parse_request(raw);
    check(parsed == http::Read.Ready, "request parses");

    var ctx = web::new_ctx(0, -1);
    var out: u8[>..] = [];
    web::render_meta(out, req, ctx);
    check_eq(out, "", "nothing set, nothing written");

    // Cuts land on a UTF-8 boundary: the two-byte e-acute starting at byte 319 does not fit in 320.
    var long: u8[>..] = [];
    for i in 319 { long.push('a'); }
    long.append("\xc3\xa9");
    web::meta_description(ctx, long);
    check(ctx.meta.description.len == 319, "description cut before a split character");
    long.clear();
    for i in 320 { long.push('b'); }
    web::meta_description(ctx, long);
    check(ctx.meta.description.len == 320, "description of exactly 320 bytes kept");
    web::meta_description(ctx, "short");
    check_eq(ctx.meta.description, "short", "a setter replaces the old value");
    long.clear();
    for i in 600 { long.push('c'); }
    web::meta_canonical(ctx, long);
    web::meta_image(ctx, long);
    check(ctx.meta.canonical.len == 512 && ctx.meta.image.len == 512, "urls cut to 512");
    long.clear();
    for i in 100 { long.push('d'); }
    web::meta_robots(ctx, long);
    check(ctx.meta.robots.len == 64, "robots cut to 64");

    var e: u8[>..] = [];
    if !env("SITE_URL", e) {
        var base: u8[>..] = [];
        web::site_url(req, base);
        check_eq(base, "https://ex.test", "site_url from Host and X-Forwarded-Proto");
        let plain, ok2 = http::parse_request("GET / HTTP/1.1\r\nHost: ex.test:8080\r\n\r\n");
        base.clear();
        web::site_url(plain, base);
        check_eq(base, "http://ex.test:8080", "site_url without a forwarded proto");

        var c2 = web::new_ctx(0, -1);
        c2.title.append("Home & Co");
        web::meta_description(c2, "Fresh \"bread\"");
        web::meta_canonical(c2, "/about?x=1&y=2");
        web::meta_robots(c2, "noindex");
        web::meta_image(c2, "https://cdn.test/a.png");
        out.clear();
        web::render_meta(out, req, c2);
        let want = "<meta name=\"description\" content=\"Fresh &quot;bread&quot;\">\n<link rel=\"canonical\" href=\"https://ex.test/about?x=1&amp;y=2\">\n<meta name=\"robots\" content=\"noindex\">\n<meta property=\"og:title\" content=\"Home &amp; Co\">\n<meta property=\"og:description\" content=\"Fresh &quot;bread&quot;\">\n<meta property=\"og:url\" content=\"https://ex.test/about?x=1&amp;y=2\">\n<meta property=\"og:image\" content=\"https://cdn.test/a.png\">\n<meta name=\"twitter:card\" content=\"summary_large_image\">";
        check_eq(out, want, "every tag, absolute urls, escaping");
    }

    var c3 = web::new_ctx(0, -1);
    web::meta_robots(c3, "noindex");
    out.clear();
    web::render_meta(out, req, c3);
    check_eq(out, "<meta name=\"robots\" content=\"noindex\">", "only the tags that are set");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
