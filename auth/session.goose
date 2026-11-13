// Part of gweb. Import with `import gweb.auth.session;`.
// Signed cookies, stateless sessions, login guards and password hashing (DESIGN-ADDENDUM-13, D3 to D5).

namespace gweb;

import std;
import net;
import net.http;
import gweb;
import auth.crypto;
import auth.csrf;
import forms.form;

const SIGNED_MAX = 700;
const SESSION_MAX_DATA = 256;
const PBKDF2_ITER = 600000;
const PBKDF2_ITER_LIMIT = 10000000;
const PASSWORD_MAX = 1024;

let HASH_PREFIX = "$pbkdf2-sha256$";
// Any fixed 16 bytes; password_verify hashes against it when there is nothing to compare with.
// The "goose-web" labels below predate the rename to gweb. Changing them would void every session and signed cookie.
let DUMMY_SALT = "goose-web-dummy!";

// Unix seconds; the internal functions below take `now` so tests can fix the clock.
fn now_s() -> i64 { return time() as i64; }

// ---------------------------------------------------------------- signed cookies

// Appends b64url(HMAC(K, name "=" encoded_value)) with K derived from master, so no MAC uses the raw secret.
fn signed_mac(out: u8[>..]&, master: const u8[:], name: const u8[:], encoded_value: const u8[:]) -> bool {
    var k: u8[..32] = [0; 32];
    if !hmac_sha256(k, master, "goose-web signed cookie v1") { return false; }
    var msg: u8[>..] = [];
    msg.append(name);
    msg.push('=');
    msg.append(encoded_value);
    var mac: u8[..32] = [0; 32];
    if !hmac_sha256(mac, k, msg) { return false; }
    b64url(out, mac);
    return true;
}

// Wire value b64url(value) "." b64url(mac). False when no key is loaded, value is over 700 bytes, or set_cookie refuses.
fn set_signed_cookie(ctx: Ctx&, name: const u8[:], value: const u8[:], opts: CookieOptions = CookieOptions { .. }) -> bool {
    if ctx.auth.keys.n == 0 || value.len > SIGNED_MAX { return false; }
    var wire: u8[>..] = [];
    b64url(wire, value);
    var mac: u8[>..] = [];
    if !signed_mac(mac, ctx.auth.keys.k[0], name, wire) { return false; }
    wire.push('.');
    wire.append(mac);
    return set_cookie(ctx, name, wire, opts);
}

// Appends the verified value to out; false, with out unchanged, when absent, malformed or signed by no loaded key.
fn signed_cookie(req: const http::Request&, ctx: const Ctx&, name: const u8[:], out: u8[>..]&) -> bool {
    let v, has = http::cookie(req, name);
    if !has { return false; }
    let enc, mac_text, dot = split_once(v, '.');
    if !dot || enc.len > 934 { return false; }
    var good = false;
    for i in ctx.auth.keys.n {
        var want: u8[>..] = [];
        // The MAC is compared as text against a fresh encoding, so a non-canonical base64 tail never verifies.
        if signed_mac(want, ctx.auth.keys.k[i], name, enc) && bytes_equal(want, mac_text) { good = true; }
    }
    if !good { return false; }
    var decoded: u8[>..] = [];
    if !b64url_decode(decoded, enc) || decoded.len > SIGNED_MAX { return false; }
    out.append(decoded);
    return true;
}

// ---------------------------------------------------------------- session cookie

// "__Host-gw_session" behind an HTTPS proxy (X-Forwarded-Proto), else "gw_session"; the same rule as csrf_cookie_name.
fn session_cookie_name(req: const http::Request&) -> const u8[:] {
    let proto, has = http::header(req, "x-forwarded-proto");
    return if has && trim(proto) == "https" { "__Host-gw_session" } else { "gw_session" };
}

// A persistent cookie lives until the absolute limit; the idle deadline is enforced from the signed exp.
fn session_cookie_opts(name: const u8[:], s: const Session&, max_s: i64, now: i64) -> CookieOptions {
    var left = s.iat + max_s - now;
    if left < 1 { left = 1; }
    return CookieOptions { max_age: if s.remember { left } else { -1 }, secure: starts_with(name, "__Host-"), .. };
}

// Appends the cookie value: 1.sid.uid.ver.iat.exp.r.data.mac
fn encode_session(out: u8[>..]&, master: const u8[:], s: const Session&) -> bool {
    var body: u8[>..] = [];
    body.append("1.");
    body.append(s.sid);
    body.push('.'); format(body, s.uid);
    body.push('.'); format(body, s.ver);
    body.push('.'); format(body, s.iat);
    body.push('.'); format(body, s.exp);
    body.append(if s.remember { ".1." } else { ".0." });
    b64url(body, s.data);

    // The literal "gw_session=" is used for the __Host- name too: the name choice is already bound by the HTTPS rule,
    // and one fixed prefix keeps the MAC independent of the proxy header.
    var msg: u8[>..] = [];
    msg.append("gw_session=");
    msg.append(body);
    var k: u8[..32] = [0; 32];
    if !hmac_sha256(k, master, "goose-web session v1") { return false; }
    var mac: u8[..32] = [0; 32];
    if !hmac_sha256(mac, k, msg) { return false; }
    out.append(body);
    out.push('.');
    b64url(out, mac);
    return true;
}

fn all_digits(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > 18 { return false; }
    for c in s { if c < '0' || c > '9' { return false; } }
    return true;
}

// Fills out from a cookie value when the MAC verifies under a loaded key, every field parses and the session is
// inside both deadlines at `now`; false otherwise, with out unchanged.
fn parse_session_value(ctx: const Ctx&, v: const u8[:], now: i64, out: Session&) -> bool {
    var last = -1;
    for i in v.len { if v[i] == '.' { last = i; } }
    if last < 0 { return false; }
    let body = v[..last];
    let mac_text = v[last + 1..];

    var good = false;
    for i in ctx.auth.keys.n {
        var k: u8[..32] = [0; 32];
        var mac: u8[..32] = [0; 32];
        var msg: u8[>..] = [];
        msg.append("gw_session=");
        msg.append(body);
        var want: u8[>..] = [];
        if hmac_sha256(k, ctx.auth.keys.k[i], "goose-web session v1") && hmac_sha256(mac, k, msg) {
            b64url(want, mac);
            if bytes_equal(want, mac_text) { good = true; }
        }
    }
    if !good { return false; }

    let version, r1, has1 = split_once(body, '.');
    if !has1 || version != "1" { return false; }
    let sid, r2, has2 = split_once(r1, '.');
    if !has2 || sid.len != 22 { return false; }
    for c in sid { if b64_value(c) < 0 { return false; } }
    let uid_t, r3, has3 = split_once(r2, '.');
    let ver_t, r4, has4 = split_once(r3, '.');
    let iat_t, r5, has5 = split_once(r4, '.');
    let exp_t, r6, has6 = split_once(r5, '.');
    let rem_t, data_t, has7 = split_once(r6, '.');
    if !has2 || !has3 || !has4 || !has5 || !has6 || !has7 { return false; }
    if !all_digits(uid_t) || !all_digits(ver_t) || !all_digits(iat_t) || !all_digits(exp_t) { return false; }
    if rem_t != "0" && rem_t != "1" { return false; }
    let uid, ok1 = parse_int(uid_t);
    let ver, ok2 = parse_int(ver_t);
    let iat, ok3 = parse_int(iat_t);
    let exp, ok4 = parse_int(exp_t);
    if !ok1 || !ok2 || !ok3 || !ok4 { return false; }
    var data: u8[>..] = [];
    if !b64url_decode(data, data_t) || data.len > SESSION_MAX_DATA { return false; }
    if now >= exp || now >= iat + ctx.auth.max { return false; }

    var s = Session { .. };
    s.state = SessionState.Valid;
    s.sid.append(sid);
    s.uid = uid;
    s.ver = ver;
    s.iat = iat;
    s.exp = exp;
    s.remember = rem_t == "1";
    s.data.append(data);
    out = s;
    return true;
}

// Writes the session cookie for s; false when it does not fit or no key is loaded.
fn issue_session(req: const http::Request&, ctx: Ctx&, s: const Session&, now: i64) -> bool {
    if ctx.auth.keys.n == 0 { return false; }
    var value: u8[>..] = [];
    if !encode_session(value, ctx.auth.keys.k[0], s) { return false; }
    let name = session_cookie_name(req);
    return set_cookie(ctx, name, value, session_cookie_opts(name, s, ctx.auth.max, now));
}

fn session_at(req: const http::Request&, ctx: Ctx&, now: i64) -> bool {
    if ctx.session.state == SessionState.Valid { return true; }
    if ctx.session.state == SessionState.Absent { return false; }
    ctx.session.state = SessionState.Absent;
    if ctx.auth.keys.n == 0 { return false; }
    let v, has = http::cookie(req, session_cookie_name(req));
    if !has { return false; }
    var s = Session { .. };
    if !parse_session_value(ctx, v, now, s) { return false; }
    ctx.session = s;

    // Sliding refresh: past half the idle window, never beyond the absolute limit. A failed write is skipped; the old cookie stays good until exp.
    if s.exp - now < ctx.auth.idle / 2 {
        var next = s.iat + ctx.auth.max;
        if now + ctx.auth.idle < next { next = now + ctx.auth.idle; }
        if next > s.exp {
            var r = s;
            r.exp = next;
            if issue_session(req, ctx, r, now) { ctx.session.exp = next; }
        }
    }
    return true;
}

// True when a valid session is loaded; reads the cookie once per request and caches the result in ctx.
fn session(req: const http::Request&, ctx: Ctx&) -> bool { return session_at(req, ctx, now_s()); }

struct LoginOptions { remember: bool = false, data: u8[..256] = "" }

fn fail_login(res: http::Response&, msg: const u8[:]) -> bool {
    http::json_error(res, http::Status.InternalServerError, msg);
    return false;
}

// Rotates the sid and the CSRF token. False after writing a 500.
fn login_at(req: const http::Request&, ctx: Ctx&, res: http::Response&, uid: i64, ver: i64, opts: LoginOptions, now: i64) -> bool {
    no_store(res);
    if ctx.auth.keys.n == 0 { return fail_login(res, "GWEB_SECRET is not set"); }
    // The cookie parser accepts digits only, so a negative id would make a session that never loads.
    if uid < 0 || ver < 0 { return fail_login(res, "session unavailable"); }
    var raw: u8[..16] = [0; 16];
    if !random_bytes(raw) { return fail_login(res, "session unavailable"); }

    var s = Session { .. };
    s.state = SessionState.Valid;
    var sid: u8[>..] = [];
    b64url(sid, raw);
    s.sid.append(sid);
    s.uid = uid;
    s.ver = ver;
    s.iat = now;
    s.exp = now + ctx.auth.idle;
    if now + ctx.auth.max < s.exp { s.exp = now + ctx.auth.max; }
    s.remember = opts.remember;
    s.data.append(opts.data);

    // Cleared first: a failure after this point leaves no half-logged-in state in the reply.
    let cname = csrf_cookie_name(req);
    if !clear_cookie(ctx, cname, CookieOptions { secure: starts_with(cname, "__Host-"), .. }) { return fail_login(res, "session unavailable"); }
    ctx.csrf.clear();
    if !issue_session(req, ctx, s, now) { return fail_login(res, "session unavailable"); }
    ctx.session = s;
    return true;
}

// Starts a session for uid; ver is the app's revocation counter. False after writing a 500.
fn login(req: const http::Request&, ctx: Ctx&, res: http::Response&, uid: i64, ver: i64,
         opts: LoginOptions = LoginOptions { .. }) -> bool {
    return login_at(req, ctx, res, uid, ver, opts, now_s());
}

// Clears the session and CSRF cookies. Call it from a POST, which the CSRF check covers.
fn logout(req: const http::Request&, ctx: Ctx&) {
    let sname = session_cookie_name(req);
    clear_cookie(ctx, sname, CookieOptions { secure: starts_with(sname, "__Host-"), .. });
    let cname = csrf_cookie_name(req);
    clear_cookie(ctx, cname, CookieOptions { secure: starts_with(cname, "__Host-"), .. });
    ctx.csrf.clear();
    ctx.session = Session { state: SessionState.Absent, .. };
}

fn session_set_data_at(req: const http::Request&, ctx: Ctx&, data: const u8[:], now: i64) -> bool {
    if !session_at(req, ctx, now) || data.len > SESSION_MAX_DATA { return false; }
    var s = ctx.session;
    s.data.clear();
    s.data.append(data);
    if !issue_session(req, ctx, s, now) { return false; }
    ctx.session = s;
    return true;
}

// Re-signs the cookie with new data; false when there is no session or the cookie does not fit.
fn session_set_data(req: const http::Request&, ctx: Ctx&, data: const u8[:]) -> bool {
    return session_set_data_at(req, ctx, data, now_s());
}

// Appends s percent-encoded; only unreserved bytes stay as they are.
fn pct_encode(out: u8[>..]&, s: const u8[:]) {
    for c in s {
        if COOKIE_PLAIN_BYTES.members[c] { out.push(c); }
        else { out.push('%'); out.push(HEX_UPPER[c >> 4]); out.push(HEX_UPPER[c & 15]); }
    }
}

fn require_login_at(req: const http::Request&, ctx: Ctx&, res: http::Response&, login_path: const u8[:], now: i64) -> bool {
    no_store(res);
    if session_at(req, ctx, now) { return true; }
    var to: u8[>..] = [];
    to.append(login_path);
    if req.method == http::Method.Get || req.method == http::Method.Head {
        var full: u8[>..] = [];
        full.append(req.path);
        if req.query.len > 0 { full.push('?'); full.append(req.query); }
        to.append("?next=");
        pct_encode(to, full);
        // redirect cuts at 1024 bytes, which could split a %XX; a too-long target goes without next instead.
        if to.len > 1024 { to.clear(); to.append(login_path); }
    }
    redirect(ctx, to, 303);
    return false;
}

// True when logged in; else a 303 to login_path (with ?next= for GET and HEAD) and false.
fn require_login(req: const http::Request&, ctx: Ctx&, res: http::Response&, login_path: const u8[:]) -> bool {
    return require_login_at(req, ctx, res, login_path, now_s());
}

fn require_login_api_at(req: const http::Request&, ctx: Ctx&, res: http::Response&, now: i64) -> bool {
    no_store(res);
    if session_at(req, ctx, now) { return true; }
    http::json_error(res, http::Status.Unauthorized, "login required");
    return false;
}

// True when logged in; else a 401 JSON error and false.
fn require_login_api(req: const http::Request&, ctx: Ctx&, res: http::Response&) -> bool {
    return require_login_api_at(req, ctx, res, now_s());
}

// next when it is a same-site path ("/x", not "//x" or "/\x", no control bytes or spaces, at most 512 bytes); else fallback.
fn safe_next(next: const u8[:], fallback: const u8[:]) -> const u8[:] {
    if next.len == 0 || next.len > 512 || next[0] != '/' { return fallback; }
    if next.len > 1 && (next[1] == '/' || next[1] == '\\') { return fallback; }
    for c in next { if c < 0x21 || c == 0x7F { return fallback; } }
    return next;
}

// ---------------------------------------------------------------- passwords

// Appends $pbkdf2-sha256$<iter>$<salt>$<hash>; false for a password over 1024 bytes, iter outside 1..10,000,000, or no entropy.
fn password_hash_iter(out: u8[>..]&, password: const u8[:], iter: i64) -> bool {
    if password.len > PASSWORD_MAX || iter < 1 || iter > PBKDF2_ITER_LIMIT { return false; }
    var salt: u8[..16] = [0; 16];
    if !random_bytes(salt) { return false; }
    var dk: u8[..32] = [0; 32];
    if !pbkdf2_sha256(dk, password, salt, iter) { return false; }
    out.append(HASH_PREFIX);
    format(out, iter);
    out.push('$');
    b64url(out, salt);
    out.push('$');
    b64url(out, dk);
    return true;
}

fn password_hash(out: u8[>..]&, password: const u8[:]) -> bool {
    return password_hash_iter(out, password, PBKDF2_ITER);
}

// Splits a stored hash; false unless it is well formed with a 16-byte salt and a 32-byte hash.
fn parse_password_hash(stored: const u8[:], iter: i64&, salt: u8[>..]&, hash: u8[>..]&) -> bool {
    if !starts_with(stored, HASH_PREFIX) { return false; }
    let iter_t, r1, has1 = split_once(stored[HASH_PREFIX.len..], '$');
    let salt_t, hash_t, has2 = split_once(r1, '$');
    if !has1 || !has2 || !all_digits(iter_t) || find(hash_t, "$") >= 0 { return false; }
    let n, ok = parse_int(iter_t);
    if !ok || n < 1 || n > PBKDF2_ITER_LIMIT { return false; }
    var s: u8[>..] = [];
    var h: u8[>..] = [];
    if !b64url_decode(s, salt_t) || s.len != 16 || !b64url_decode(h, hash_t) || h.len != 32 { return false; }
    iter = n;
    salt.append(s);
    hash.append(h);
    return true;
}

// stored "" (no such user), a malformed hash and an oversized password all cost one full hash, then return false.
fn password_verify(stored: const u8[:], password: const u8[:]) -> bool {
    var iter = 0;
    var salt: u8[>..] = [];
    var want: u8[>..] = [];
    var dk: u8[..32] = [0; 32];
    let pw = password[..min(password.len, PASSWORD_MAX)];
    if password.len > PASSWORD_MAX || !parse_password_hash(stored, iter, salt, want) {
        pbkdf2_sha256(dk, pw, DUMMY_SALT, PBKDF2_ITER);
        return false;
    }
    if !pbkdf2_sha256(dk, pw, salt, iter) { return false; }
    return bytes_equal(dk, want);
}

// True when the stored hash parses with fewer than PBKDF2_ITER iterations; nothing is computed.
fn password_needs_rehash(stored: const u8[:]) -> bool {
    var iter = 0;
    var salt: u8[>..] = [];
    var hash: u8[>..] = [];
    return parse_password_hash(stored, iter, salt, hash) && iter < PBKDF2_ITER;
}
