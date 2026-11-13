// Signed cookies, sessions, login guards and passwords (DESIGN-ADDENDUM-13, D3 to D5), without sockets.
//   goose build test/session_test.goose && test/session_test
import gweb from "..";
import gweb.auth.crypto;
import gweb.auth.csrf;
import gweb.auth.session;
import gweb.site.template;
import net from "../../goose-net";
import net.http;
import std;

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

let KEY1 = "0123456789abcdef0123456789abcdef";
let KEY2 = "fedcba9876543210fedcba9876543210";
let NOW = 1000000;

fn count(s: const u8[:], sub: const u8[:]) -> i64 {
    var n = 0;
    var rest = s;
    loop {
        let i = find(rest, sub);
        if i < 0 { return n; }
        n += 1;
        rest = rest[i + sub.len..];
    }
}

fn ctx_with(k1: const u8[:], k2: const u8[:]) -> gweb::Ctx {
    var ctx = gweb::new_ctx(0, -1);
    var n = 0;
    if k1.len > 0 { ctx.auth.keys.k[n].append(k1); n += 1; }
    if k2.len > 0 { ctx.auth.keys.k[n].append(k2); n += 1; }
    ctx.auth.keys.n = n;
    return ctx;
}

// The value of the first Set-Cookie line for name.
fn set_value(lines: const u8[:], name: const u8[:], out: u8[>..]&) -> bool {
    var needle: u8[>..] = [];
    needle.append("Set-Cookie: ");
    needle.append(name);
    needle.push('=');
    let at = find(lines, needle);
    if at < 0 { return false; }
    let rest = lines[at + needle.len..];
    let end = find(rest, ";");
    if end < 0 { return false; }
    out.append(rest[..end]);
    return true;
}

// A request carrying one cookie; raw must outlive req, so the caller owns it.
fn build(raw: u8[>..]&, method: const u8[:], target: const u8[:], extra: const u8[:], name: const u8[:], value: const u8[:]) {
    format(raw, method, " ", target, " HTTP/1.1\r\nHost: a\r\n", extra);
    if name.len > 0 { format(raw, "Cookie: ", name, "=", value, "\r\n"); }
    format(raw, "\r\n");
}

fn copy(v: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    o.append(v);
    return o;
}

fn flip_first(v: u8[>..]&) { v[0] = if v[0] == 'A' { 'B' } else { 'A' }; }

// Changes the last base64 character in a way that only touches the unused trailing bits of a 32-byte MAC.
fn noncanonical_tail(v: u8[>..]&) {
    let last = v.len - 1;
    let idx = gweb::b64_value(v[last]);
    v[last] = gweb::B64URL[idx ^ 1];
}

fn signed_read(ctx: const gweb::Ctx&, name: const u8[:], value: const u8[:], want_ok: bool, want: const u8[:], what: const u8[:]) {
    var raw: u8[>..] = [];
    build(raw, "GET", "/", "", name, value);
    let req, parsed = http::parse_request(raw);
    var out: u8[>..] = [];
    let ok = gweb::signed_cookie(req, ctx, name, out);
    check(ok == want_ok, what);
    if want_ok { check_eq(out, want, what); } else { check(out.len == 0, what); }
}

fn signed_tests() {
    var ctx = ctx_with(KEY1, "");
    check(gweb::set_signed_cookie(ctx, "pref", "hello world"), "signed set");
    var v: u8[>..] = [];
    check(set_value(ctx.set_cookies, "pref", v), "signed value present");
    signed_read(ctx, "pref", v, true, "hello world", "signed round trip");

    var bad = copy(v);
    flip_first(bad);
    signed_read(ctx, "pref", bad, false, "", "flipped value byte refused");

    let dot = find(v, ".");
    var m = copy(v);
    m[dot + 1] = if m[dot + 1] == 'A' { 'B' } else { 'A' };
    signed_read(ctx, "pref", m, false, "", "flipped MAC byte refused");

    var nc = copy(v);
    noncanonical_tail(nc);
    check(nc != v, "non-canonical copy differs");
    signed_read(ctx, "pref", nc, false, "", "non-canonical MAC refused");

    signed_read(ctx, "other", v, false, "", "same value under another cookie name refused");
    signed_read(ctx, "pref", "", false, "", "empty value refused");
    signed_read(ctx, "pref", "nodot", false, "", "no dot refused");

    var nokey = ctx_with("", "");
    check(!gweb::set_signed_cookie(nokey, "pref", "x"), "no key: set refused");
    check(nokey.set_cookies.len == 0, "no key: nothing written");
    signed_read(nokey, "pref", v, false, "", "no key: verify refused");

    var only2 = ctx_with(KEY2, "");
    check(gweb::set_signed_cookie(only2, "pref", "two"), "key 2 sets");
    var v2: u8[>..] = [];
    set_value(only2.set_cookies, "pref", v2);
    let both = ctx_with(KEY1, KEY2);
    signed_read(both, "pref", v2, true, "two", "second key verifies");
    signed_read(ctx, "pref", v2, false, "", "removed key does not verify");

    var big: u8[>..] = [];
    for i in 700 { big.push('x'); }
    var ctx2 = ctx_with(KEY1, "");
    check(gweb::set_signed_cookie(ctx2, "big", big), "700 bytes accepted");
    big.push('x');
    check(!gweb::set_signed_cookie(ctx2, "big", big), "701 bytes refused");
    var bv: u8[>..] = [];
    set_value(ctx2.set_cookies, "big", bv);
    signed_read(ctx2, "big", bv, true, big[..700], "700 bytes round trip");
}

// Parses a cookie value the way session_at would, at a fixed clock.
fn load(ctx: gweb::Ctx&, value: const u8[:], now: i64, headers: const u8[:], name: const u8[:]) -> bool {
    var raw: u8[>..] = [];
    build(raw, "GET", "/", headers, name, value);
    let req, parsed = http::parse_request(raw);
    return gweb::session_at(req, ctx, now);
}

fn logged_in_ctx(remember: bool, data: const u8[:], value: u8[>..]&) -> gweb::Ctx {
    var ctx = ctx_with(KEY1, "");
    var res = http::new_response();
    let raw = "GET / HTTP/1.1\r\nHost: a\r\n\r\n";
    let req, parsed = http::parse_request(raw);
    var opts = gweb::LoginOptions { remember: remember, .. };
    opts.data.append(data);
    check(gweb::login_at(req, ctx, res, 42, 7, opts, NOW), "login ok");
    set_value(ctx.set_cookies, "gw_session", value);
    return ctx;
}

fn session_tests() {
    // login
    var ctx = ctx_with(KEY1, "");
    ctx.csrf.append("0123456789abcdef0123456789abcdef");
    var res = http::new_response();
    let raw = "GET / HTTP/1.1\r\nHost: a\r\nCookie: gw_csrf=0123456789abcdef0123456789abcdef\r\n\r\n";
    let req, parsed = http::parse_request(raw);
    var opts = gweb::LoginOptions { .. };
    opts.data.append("hi");
    check(gweb::login_at(req, ctx, res, 42, 7, opts, NOW), "login ok");
    check(ctx.session.state == gweb::SessionState.Valid, "login leaves ctx Valid");
    check(ctx.session.uid == 42 && ctx.session.ver == 7, "ctx uid and ver");
    check(ctx.session.sid.len == 22, "sid is 22 bytes");
    check(count(ctx.set_cookies, "Set-Cookie: gw_session=") == 1, "exactly one session line");
    check(count(ctx.set_cookies, "Set-Cookie: gw_csrf=; Path=/; Max-Age=0; Expires=") == 1, "csrf cookie cleared");
    check(ctx.csrf.len == 0, "ctx.csrf cleared");
    check(find(res.headers, "Cache-Control: no-store") >= 0, "login sets no-store");
    check(gweb::logged_in(ctx) && gweb::user_id(ctx) == 42, "template helpers when Valid");
    check(find(ctx.set_cookies, "; Path=/; HttpOnly; SameSite=Lax\r\n") > 0, "D4 attributes");
    check(count(ctx.set_cookies, "Max-Age=") == 1, "no Max-Age on the session line (only the csrf clear has one)");
    check(count(ctx.set_cookies, "gw_session=") == 1 && find(ctx.set_cookies, "Secure") < 0, "plain name, no Secure on HTTP");

    var v: u8[>..] = [];
    check(set_value(ctx.set_cookies, "gw_session", v), "session value present");
    check(v.len < 600, "value under 600 bytes");

    // parse back
    var c2 = ctx_with(KEY1, "");
    check(load(c2, v, NOW + 10, "", "gw_session"), "parses back");
    check(c2.session.uid == 42 && c2.session.ver == 7, "uid and ver round trip");
    check_eq(c2.session.data, "hi", "data round trip");
    check_eq(c2.session.sid, ctx.session.sid, "sid round trip");
    check(c2.session.iat == NOW && c2.session.exp == NOW + 86400 && !c2.session.remember, "iat, exp, remember");
    check(c2.set_cookies.len == 0, "no refresh early in the window");
    check(load(c2, v, NOW + 99999999, "", "gw_session"), "second call is cached");
    check(gweb::user_id(c2) == 42, "user_id Valid");

    // absent and expired
    var c3 = ctx_with(KEY1, "");
    check(!load(c3, "", NOW, "", ""), "no cookie: Absent");
    check(c3.session.state == gweb::SessionState.Absent, "state Absent");
    check(gweb::user_id(c3) == 0 && !gweb::logged_in(c3), "template helpers when Absent");
    var c4 = ctx_with(KEY1, "");
    check(!load(c4, v, NOW + 86400, "", "gw_session"), "expired at exp");
    var c5 = ctx_with(KEY1, "");
    check(load(c5, v, NOW + 86399, "", "gw_session"), "valid just before exp");

    // the absolute limit
    var c6 = ctx_with(KEY1, "");
    c6.auth.max = 1000;
    check(!load(c6, v, NOW + 1000, "", "gw_session"), "expired by iat + max");
    var c7 = ctx_with(KEY1, "");
    c7.auth.max = 1000;
    check(load(c7, v, NOW + 999, "", "gw_session"), "valid before iat + max");

    // tampering
    var t1 = copy(v);
    t1[2] = if t1[2] == 'A' { 'B' } else { 'A' };
    var c8 = ctx_with(KEY1, "");
    check(!load(c8, t1, NOW, "", "gw_session"), "tampered sid refused");
    var t2 = copy(v);
    t2[t2.len - 2] = if t2[t2.len - 2] == 'A' { 'B' } else { 'A' };
    var c9 = ctx_with(KEY1, "");
    check(!load(c9, t2, NOW, "", "gw_session"), "tampered MAC refused");
    var t3 = copy(v);
    t3[0] = '2';
    var c10 = ctx_with(KEY1, "");
    check(!load(c10, t3, NOW, "", "gw_session"), "wrong version digit refused");
    var c11 = ctx_with(KEY2, "");
    check(!load(c11, v, NOW, "", "gw_session"), "another key refused");
    var c12 = ctx_with("", "");
    check(!load(c12, v, NOW, "", "gw_session"), "no key refused");
    var c13 = ctx_with(KEY2, KEY1);
    check(load(c13, v, NOW, "", "gw_session"), "old key still verifies");

    // a validly signed but edited field: forge uid by re-signing with the wrong key is what a tamper looks like
    var forged = copy(v);
    let uid_at = find(forged, ".42.");
    check(uid_at > 0, "uid field found");
    forged[uid_at + 1] = '9';
    var c14 = ctx_with(KEY1, "");
    check(!load(c14, forged, NOW, "", "gw_session"), "tampered uid refused");

    // HTTPS: only the __Host- name counts
    var c15 = ctx_with(KEY1, "");
    check(!load(c15, v, NOW, "X-Forwarded-Proto: https\r\n", "gw_session"), "plain name refused under HTTPS");
    var c16 = ctx_with(KEY1, "");
    var raw16: u8[>..] = [];
    format(raw16, "GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-Proto: https\r\n\r\n");
    let req16, p16 = http::parse_request(raw16);
    var res16 = http::new_response();
    check(gweb::login_at(req16, c16, res16, 5, 1, gweb::LoginOptions { .. }, NOW), "https login ok");
    check(count(c16.set_cookies, "Set-Cookie: __Host-gw_session=") == 1, "__Host- session line");
    check(count(c16.set_cookies, "Set-Cookie: __Host-gw_csrf=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure;") == 1, "__Host- csrf cleared with Secure");
    var hv: u8[>..] = [];
    set_value(c16.set_cookies, "__Host-gw_session", hv);
    var c17 = ctx_with(KEY1, "");
    check(load(c17, hv, NOW, "X-Forwarded-Proto: https\r\n", "__Host-gw_session"), "__Host- cookie loads under HTTPS");
    check(c17.session.uid == 5, "__Host- uid");
    var c18 = ctx_with(KEY1, "");
    check(!load(c18, hv, NOW, "", "__Host-gw_session"), "__Host- cookie ignored without HTTPS");

    // refresh
    var r1 = ctx_with(KEY1, "");
    check(load(r1, v, NOW + 43199, "", "gw_session"), "just inside the first half");
    check(r1.set_cookies.len == 0, "no refresh before half the idle window");
    var r2 = ctx_with(KEY1, "");
    check(load(r2, v, NOW + 43201, "", "gw_session"), "past half");
    check(count(r2.set_cookies, "Set-Cookie: gw_session=") == 1, "refresh writes one line");
    check(r2.session.exp == NOW + 43201 + 86400, "ctx exp slides");
    var rv: u8[>..] = [];
    set_value(r2.set_cookies, "gw_session", rv);
    var r3 = ctx_with(KEY1, "");
    check(load(r3, rv, NOW + 43202, "", "gw_session"), "refreshed cookie verifies");
    check(r3.session.exp == NOW + 43201 + 86400 && r3.session.iat == NOW && r3.session.uid == 42, "refresh keeps iat and uid");
    check_eq(r3.session.sid, ctx.session.sid, "refresh keeps sid");
    check_eq(r3.session.data, "hi", "refresh keeps data");
    var r4 = ctx_with(KEY1, "");
    r4.auth.max = 100000;
    check(load(r4, v, NOW + 43201, "", "gw_session"), "refresh under a short max");
    check(r4.session.exp == NOW + 100000, "refresh capped at iat + max");
    var r5 = ctx_with(KEY1, "");
    r5.auth.max = 100000;
    var rv5: u8[>..] = [];
    set_value(r4.set_cookies, "gw_session", rv5);
    check(load(r5, rv5, NOW + 99999, "", "gw_session"), "capped cookie valid until the limit");
    check(r5.set_cookies.len == 0, "no refresh when exp is already iat + max");
    var r6 = ctx_with(KEY1, "");
    var fill: u8[>..] = [];
    for i in 2047 { fill.push('y'); }
    r6.set_cookies.append(fill);
    check(load(r6, v, NOW + 43201, "", "gw_session"), "full cookie buffer: session still loads");
    check(r6.session.exp == NOW + 86400, "full cookie buffer: refresh skipped, exp unchanged");

    // remember
    var rem: u8[>..] = [];
    let rc = logged_in_ctx(true, "", rem);
    check(count(rc.set_cookies, "; Max-Age=2592000;") == 1, "remember writes Max-Age");
    var rem2 = ctx_with(KEY1, "");
    check(load(rem2, rem, NOW + 1, "", "gw_session") && rem2.session.remember, "remember round trips");
    var rem3 = ctx_with(KEY1, "");
    check(load(rem3, rem, NOW + 43201, "", "gw_session"), "remember refreshes");
    check(find(rem3.set_cookies, "; Max-Age=") > 0, "refreshed remember cookie keeps Max-Age");

    // login fails without a key
    var nk = ctx_with("", "");
    var nres = http::new_response();
    check(!gweb::login_at(req, nk, nres, 1, 1, gweb::LoginOptions { .. }, NOW), "login without a key");
    check_eq(nres.body, "{\"error\":\"WEB_SECRET is not set\"}", "login 500 body");
    check(nk.set_cookies.len == 0, "no cookie without a key");

    // two logins never share a sid
    var l1 = ctx_with(KEY1, "");
    var l2 = ctx_with(KEY1, "");
    var res_a = http::new_response();
    var res_b = http::new_response();
    gweb::login_at(req, l1, res_a, 1, 1, gweb::LoginOptions { .. }, NOW);
    gweb::login_at(req, l2, res_b, 1, 1, gweb::LoginOptions { .. }, NOW);
    check(l1.session.sid != l2.session.sid, "fresh sid per login");

    // set data
    var sd = ctx_with(KEY1, "");
    check(!gweb::session_set_data_at(req, sd, "x", NOW), "set_data without a session");
    var req_sd_raw: u8[>..] = [];
    build(req_sd_raw, "GET", "/", "", "gw_session", v);
    let req_sd, p_sd = http::parse_request(req_sd_raw);
    var sd1 = ctx_with(KEY1, "");  // the failed call above cached Absent in sd
    check(gweb::session_set_data_at(req_sd, sd1, "new", NOW + 5), "set_data with a session");
    var dv: u8[>..] = [];
    set_value(sd1.set_cookies, "gw_session", dv);
    var sd2 = ctx_with(KEY1, "");
    check(load(sd2, dv, NOW + 6, "", "gw_session"), "re-signed cookie loads");
    check_eq(sd2.session.data, "new", "data replaced");
    check(sd2.session.uid == 42 && sd2.session.iat == NOW, "set_data keeps uid and iat");

    // logout
    var lo = ctx_with(KEY1, "");
    check(load(lo, v, NOW, "", "gw_session"), "loaded before logout");
    lo.csrf.append("abc");
    gweb::logout(req_sd, lo);
    check(lo.session.state == gweb::SessionState.Absent && lo.csrf.len == 0, "logout: Absent, csrf cleared");
    check(count(lo.set_cookies, "Set-Cookie: gw_session=; Path=/; Max-Age=0;") == 1, "logout clears the session cookie");
    check(count(lo.set_cookies, "Set-Cookie: gw_csrf=; Path=/; Max-Age=0;") == 1, "logout clears the csrf cookie");
}

fn guard_tests() {
    var ctx = ctx_with(KEY1, "");
    var res = http::new_response();
    var raw1: u8[>..] = [];
    build(raw1, "GET", "/admin/posts?page=2&q=a%20b", "", "", "");
    let req1, p1 = http::parse_request(raw1);
    check(!gweb::require_login_at(req1, ctx, res, "/login", NOW), "guard refuses");
    check(ctx.outcome == gweb::Outcome.Redirect && ctx.redirect_status == 303, "303 redirect");
    check_eq(ctx.location, "/login?next=%2Fadmin%2Fposts%3Fpage%3D2%26q%3Da%2520b", "next with path and query");
    check(find(res.headers, "Cache-Control: no-store") >= 0, "guard sets no-store");

    var ctx2 = ctx_with(KEY1, "");
    var res2 = http::new_response();
    var raw2: u8[>..] = [];
    build(raw2, "GET", "/admin", "", "", "");
    let req2, p2 = http::parse_request(raw2);
    check(!gweb::require_login_at(req2, ctx2, res2, "/login", NOW), "guard refuses, no query");
    check_eq(ctx2.location, "/login?next=%2Fadmin", "next without a query");

    var ctx3 = ctx_with(KEY1, "");
    var res3 = http::new_response();
    var raw3: u8[>..] = [];
    build(raw3, "POST", "/admin/posts?x=1", "Content-Length: 0\r\n", "", "");
    let req3, p3 = http::parse_request(raw3);
    check(!gweb::require_login_at(req3, ctx3, res3, "/login", NOW), "guard refuses a POST");
    check_eq(ctx3.location, "/login", "POST gets a bare login path");

    var vctx = ctx_with(KEY1, "");
    var v: u8[>..] = [];
    let lc = logged_in_ctx(false, "", v);
    var raw4: u8[>..] = [];
    build(raw4, "GET", "/admin", "", "gw_session", v);
    let req4, p4 = http::parse_request(raw4);
    var res4 = http::new_response();
    check(gweb::require_login_at(req4, vctx, res4, "/login", NOW + 1), "guard passes");
    check(vctx.outcome == gweb::Outcome.Continue, "no redirect on success");
    check(find(res4.headers, "Cache-Control: no-store") >= 0, "guard sets no-store on success");

    var actx = ctx_with(KEY1, "");
    var ares = http::new_response();
    check(!gweb::require_login_api_at(req1, actx, ares, NOW), "api guard refuses");
    check(ares.status == http::Status.Unauthorized, "401 status");
    check_eq(ares.body, "{\"error\":\"login required\"}", "401 body");
    var actx2 = ctx_with(KEY1, "");
    var ares2 = http::new_response();
    check(gweb::require_login_api_at(req4, actx2, ares2, NOW + 1), "api guard passes");

    // safe_next
    check_eq(gweb::safe_next("/a", "/"), "/a", "safe_next /a");
    check_eq(gweb::safe_next("/", "/home"), "/", "safe_next /");
    check_eq(gweb::safe_next("/a?b=1#c", "/"), "/a?b=1#c", "safe_next query");
    check_eq(gweb::safe_next("//evil", "/"), "/", "safe_next //evil");
    check_eq(gweb::safe_next("/\\evil", "/"), "/", "safe_next /\\evil");
    check_eq(gweb::safe_next("https://x", "/"), "/", "safe_next absolute url");
    check_eq(gweb::safe_next("/a\nb", "/"), "/", "safe_next control byte");
    check_eq(gweb::safe_next("/a b", "/"), "/", "safe_next space");
    check_eq(gweb::safe_next("/a\x7fb", "/"), "/", "safe_next DEL");
    check_eq(gweb::safe_next("", "/f"), "/f", "safe_next empty");
    var long: u8[>..] = [];
    long.push('/');
    for i in 511 { long.push('a'); }
    check_eq(gweb::safe_next(long, "/"), long, "safe_next 512 bytes");
    long.push('a');
    check_eq(gweb::safe_next(long, "/"), "/", "safe_next 513 bytes");
}

fn password_tests() {
    var h: u8[>..] = [];
    check(gweb::password_hash_iter(h, "correct horse", 1000), "hash at 1000");
    check(starts_with(h, "$pbkdf2-sha256$1000$"), "hash format prefix");
    check(h.len == 15 + 5 + 22 + 1 + 43, "hash length");
    check(gweb::password_verify(h, "correct horse"), "verify right password");
    check(!gweb::password_verify(h, "correct horsf"), "verify wrong password");
    check(!gweb::password_verify(h, ""), "verify empty password");
    check(!gweb::password_verify("", "correct horse"), "stored empty is false");
    check(!gweb::password_verify("garbage", "x"), "malformed: no prefix");
    check(!gweb::password_verify("$pbkdf2-sha256$1000$AAAA$BBBB", "x"), "malformed: short salt and hash");
    check(!gweb::password_verify("$pbkdf2-sha256$abc$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "x"), "malformed: iterations not a number");
    check(!gweb::password_verify("$pbkdf2-sha256$10000001$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "x"), "iterations above the limit");
    check(!gweb::password_verify("$pbkdf2-sha256$0$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "x"), "zero iterations");
    var cut: u8[>..] = [];
    cut.append(h[..h.len - 1]);
    check(!gweb::password_verify(cut, "correct horse"), "truncated hash");

    var h2: u8[>..] = [];
    gweb::password_hash_iter(h2, "correct horse", 1000);
    check(h != h2, "salted: two hashes differ");
    check(gweb::password_verify(h2, "correct horse"), "second hash verifies");

    var long: u8[>..] = [];
    for i in 1025 { long.push('p'); }
    var hl: u8[>..] = [];
    check(!gweb::password_hash_iter(hl, long, 1000), "hash refuses over 1024 bytes");
    check(hl.len == 0, "refused hash leaves out unchanged");
    var edge: u8[>..] = [];
    edge.append(long[..1024]);
    var he: u8[>..] = [];
    check(gweb::password_hash_iter(he, edge, 1000) && gweb::password_verify(he, edge), "1024 bytes round trip");
    check(!gweb::password_verify(he, long), "verify refuses over 1024 bytes");
    var hz: u8[>..] = [];
    check(!gweb::password_hash_iter(hz, "x", 0), "iter 0 refused");
    check(!gweb::password_hash_iter(hz, "x", 10000001), "iter above the limit refused");

    check(gweb::password_needs_rehash(h), "needs_rehash at 1000");
    check(!gweb::password_needs_rehash("$pbkdf2-sha256$600000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), "no rehash at 600000");
    check(!gweb::password_needs_rehash("$pbkdf2-sha256$900000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), "no rehash above");
    check(!gweb::password_needs_rehash(""), "no rehash for empty");

    // the real cost
    var full: u8[>..] = [];
    let t0 = time();
    check(gweb::password_hash(full, "correct horse"), "hash at 600000");
    let t1 = time();
    check(gweb::password_verify(full, "correct horse"), "verify at 600000");
    let t2 = time();
    check(starts_with(full, "$pbkdf2-sha256$600000$") && !gweb::password_needs_rehash(full), "default cost");
    print("password_hash at 600000 iterations: ", (t1 - t0) as i64, " s; verify: ", (t2 - t1) as i64, " s (time() resolution)");
}

fn main() {
    signed_tests();
    session_tests();
    guard_tests();
    password_tests();
    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
