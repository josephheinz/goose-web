// Validation helpers (DESIGN-ADDENDUM-14, step 2), without sockets.
//   goose build test/valid_test.goose && test/valid_test
import gweb from "..";
import gweb.forms.valid;
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

// The request holds slices into raw, so the caller owns the buffer.
fn post(raw: u8[>..]&, body: const u8[:]) -> http::Request {
    raw.clear();
    format(raw, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ", body.len, "\r\n\r\n", body);
    let req, parsed = http::parse_request(raw);
    return req;
}

fn main() {
    // form_text
    var raw_r1: u8[>..] = [];
    let r1 = post(raw_r1, "name=Ann+Lee&city=%C3%A9t%C3%A9&blank=+%20&long=abcdefgh&pad=+x+");
    var errs = gweb::no_errors();
    var name: u8[..10] = "";
    check(gweb::form_text(r1, "name", name, errs, true), "text present");
    check_eq(name, "Ann Lee", "+ decodes to space");
    var city: u8[..10] = "";
    check(gweb::form_text(r1, "city", city, errs, true), "text with %XX");
    check_eq(city, "\xC3\xA9t\xC3\xA9", "%XX decoded");
    var padv: u8[..10] = "";
    check(gweb::form_text(r1, "pad", padv, errs, true), "padded text ok");
    check_eq(padv, " x ", "not trimmed");
    check(!gweb::has_errors(errs), "no errors so far");

    var absent: u8[..10] = "";
    check(!gweb::form_text(r1, "nope", absent, errs, true), "absent required fails");
    check_eq(gweb::error_for(errs, "nope"), "Required.", "absent required message");
    var blank: u8[..10] = "";
    check(!gweb::form_text(r1, "blank", blank, errs, true), "blank required fails");
    check_eq(gweb::error_for(errs, "blank"), "Required.", "blank required message");

    var opt: u8[..10] = "dflt";
    check(gweb::form_text(r1, "nope", opt, errs, false), "absent optional ok");
    check_eq(opt, "dflt", "absent optional keeps default");
    check(gweb::form_text(r1, "blank", opt, errs, false), "blank optional ok");
    check_eq(opt, "dflt", "blank optional keeps default");
    check(!gweb::has_error(errs, "opt"), "optional adds no error");

    var small: u8[..5] = "keep";
    check(!gweb::form_text(r1, "long", small, errs, true), "over capacity fails");
    check_eq(small, "keep", "over capacity leaves out unchanged");
    check_eq(gweb::error_for(errs, "long"), "Use at most 5 characters.", "over capacity message");
    var exact: u8[..8] = "";
    check(gweb::form_text(r1, "long", exact, errs, true), "exactly capacity ok");
    check_eq(exact, "abcdefgh", "exactly capacity stored");

    // form_i64
    var raw_r2: u8[>..] = [];
    let r2 = post(raw_r2, "a=+42+&b=4x&c=&d=-7&e=%2042");
    var e2 = gweb::no_errors();
    var n: i64 = 0;
    check(gweb::form_i64(r2, "a", n, e2, true) && n == 42, "int with spaces");
    n = 5;
    check(!gweb::form_i64(r2, "b", n, e2, true), "int 4x fails");
    check_eq(gweb::error_for(e2, "b"), "Enter a whole number.", "int message");
    check(n == 5, "bad int leaves out");
    check(!gweb::form_i64(r2, "c", n, e2, true), "empty required int fails");
    check_eq(gweb::error_for(e2, "c"), "Required.", "empty required int message");
    check(gweb::form_i64(r2, "c", n, e2, false) && n == 5, "empty optional int keeps");
    check(gweb::form_i64(r2, "zz", n, e2, false) && n == 5, "absent optional int keeps");
    check(!gweb::form_i64(r2, "zz", n, e2, true), "absent required int fails");
    check(gweb::form_i64(r2, "d", n, e2, true) && n == -7, "negative int");
    check(gweb::form_i64(r2, "e", n, e2, true) && n == 42, "encoded space trimmed");

    // form_bool
    var raw_r3: u8[>..] = [];
    let r3 = post(raw_r3, "on=on&off=off&zero=0&empty=&one=1&f=false&yes=yes");
    var bo = true;
    check(gweb::form_bool(r3, "nope", bo) && !bo, "bool absent is false");
    check(gweb::form_bool(r3, "on", bo) && bo, "bool on");
    check(gweb::form_bool(r3, "off", bo) && !bo, "bool off");
    check(gweb::form_bool(r3, "zero", bo) && !bo, "bool 0");
    check(gweb::form_bool(r3, "empty", bo) && !bo, "bool empty");
    check(gweb::form_bool(r3, "one", bo) && bo, "bool 1");
    check(gweb::form_bool(r3, "f", bo) && !bo, "bool false");
    check(gweb::form_bool(r3, "yes", bo) && bo, "bool yes");

    // add_error, error_for, has_errors
    var e = gweb::no_errors();
    check(!gweb::has_errors(e), "fresh has none");
    check_eq(gweb::error_for(e, "x"), "", "error_for none");
    check(gweb::add_error(e, "x", "first"), "add first");
    check(!gweb::add_error(e, "x", "second"), "second for the same field refused");
    check_eq(gweb::error_for(e, "x"), "first", "first kept");
    check(gweb::has_errors(e) && e.n == 1, "has one");
    check(gweb::add_error(e, "", "form level"), "add form-level");
    check_eq(gweb::error_for(e, ""), "form level", "form-level lookup");
    check_eq(gweb::error_for(e, "y"), "", "other field none");
    var full = gweb::no_errors();
    var fname: u8[..8] = "";
    for i in 63 {
        fname.clear();
        format(fname, "f", i);
        check(gweb::add_error(full, fname, "m"), "fill to 63");
    }
    check(!full.dropped && full.n == 63, "not dropped at 63");
    check(!gweb::add_error(full, "f99", "m"), "64th field error refused");
    check(full.dropped && full.n == 64, "64th sets dropped and adds the form-level slot");
    check_eq(gweb::error_for(full, "f99"), "", "64th not stored");
    check(find(gweb::error_for(full, ""), "Too many errors") == 0, "dropped shows as a form-level error");
    check(!gweb::add_error(full, "f100", "m") && full.n == 64, "no second notice");
    check(!gweb::add_error(full, "f0", "again"), "duplicate on a full list refused");
    var full_json = http::new_response();
    gweb::errors_json(full_json, full);
    check(find(full_json.body, "\"\":\"Too many errors") > 0, "errors_json carries the form-level notice");
    // an app's own form-level error is kept, and no second one is added
    var own = gweb::no_errors();
    gweb::add_error(own, "", "mine");
    for i in 62 {
        fname.clear();
        format(fname, "g", i);
        gweb::add_error(own, fname, "m");
    }
    check(own.n == 63 && !own.dropped, "63 with an app form-level error");
    check(!gweb::add_error(own, "g99", "m") && own.dropped && own.n == 63, "dropped, and the app's own message stays");
    check_eq(gweb::error_for(own, ""), "mine", "own form-level message kept");

    // check_length
    var c = gweb::no_errors();
    check(gweb::check_length(c, "a", "abc", 2, 5), "length ok");
    check(!gweb::check_length(c, "a", "a", 2, 5), "too short");
    check_eq(gweb::error_for(c, "a"), "Use at least 2 characters.", "short message");
    check(!gweb::check_length(c, "a", "abc", 2, 5), "skipped after error");
    check_eq(gweb::error_for(c, "a"), "Use at least 2 characters.", "skip keeps message");
    check(!gweb::check_length(c, "b", "abcdef", 2, 5), "too long");
    check_eq(gweb::error_for(c, "b"), "Use at most 5 characters.", "long message");

    // check_range
    var g = gweb::no_errors();
    check(gweb::check_range(g, "n", 5, 1, 10), "range ok");
    check(gweb::check_range(g, "n", 1, 1, 10) && gweb::check_range(g, "n", 10, 1, 10), "range edges");
    check(!gweb::check_range(g, "n", 11, 1, 10), "range high");
    check_eq(gweb::error_for(g, "n"), "Enter a number from 1 to 10.", "range message");
    check(!gweb::check_range(g, "n", 5, 1, 10), "range skipped after error");
    check(!gweb::check_range(g, "m", 0, 1, 10), "range low");

    // check_email
    var m = gweb::no_errors();
    check(gweb::check_email(m, "e", "a@b.co"), "email ok");
    check(!gweb::check_email(m, "e1", "a@b"), "a@b refused");
    check(!gweb::check_email(m, "e2", "@b.co"), "@b.co refused");
    check(!gweb::check_email(m, "e3", "a b@c.d"), "space refused");
    check(!gweb::check_email(m, "e4", "a@@b.c"), "double @ refused");
    check(!gweb::check_email(m, "e5", "a@b."), "trailing dot refused");
    check(!gweb::check_email(m, "e6", "a@.b"), "leading dot refused");
    check(!gweb::check_email(m, "e7", "a@"), "nothing after @");
    check(!gweb::check_email(m, "e8", ""), "empty refused");
    check(!gweb::check_email(m, "e9", "a.b@c"), "dot before @ does not count");
    check(gweb::check_email(m, "e10", "a.b@c.d.e"), "dots ok");
    check_eq(gweb::error_for(m, "e1"), "Enter a valid email address.", "email message");
    check(!gweb::check_email(m, "e1", "a@b.co"), "email skipped after error");
    check_eq(gweb::error_for(m, "e1"), "Enter a valid email address.", "email skip keeps message");

    // check_one_of
    var o = gweb::no_errors();
    let opts: const u8[:][3] = ["red", "green", "blue"];
    check(gweb::check_one_of(o, "c", "green", opts), "one_of ok");
    check(!gweb::check_one_of(o, "c", "pink", opts), "one_of refused");
    check_eq(gweb::error_for(o, "c"), "Choose one of the options.", "one_of message");
    check(!gweb::check_one_of(o, "c", "red", opts), "one_of skipped after error");

    // a Required. is not followed by a format error
    var s = gweb::no_errors();
    gweb::add_error(s, "e", "Required.");
    check(!gweb::check_email(s, "e", "x"), "email skipped after Required");
    check_eq(gweb::error_for(s, "e"), "Required.", "Required kept");

    // template partials
    var te = gweb::no_errors();
    gweb::add_error(te, "email", "Use <b> & \"q\"");
    var out: u8[>..] = [];
    gweb::field_error(out, te, "email");
    check_eq(out, "<span class=\"gw-error\" id=\"email-error\">Use &lt;b&gt; &amp; &quot;q&quot;</span>", "field_error");
    out.clear();
    gweb::field_error(out, te, "other");
    check_eq(out, "", "field_error none");
    gweb::invalid(out, te, "email");
    check_eq(out, " aria-invalid=\"true\" aria-describedby=\"email-error\"", "invalid");
    out.clear();
    gweb::invalid(out, te, "other");
    check_eq(out, "", "invalid none");

    var raw_pr: u8[>..] = [];
    let pr = post(raw_pr, "name=%3Cb%3E+%26+%22x%22&empty=");
    out.clear();
    gweb::field_value(out, pr, "name", "fallback");
    check_eq(out, "&lt;b&gt; &amp; &quot;x&quot;", "field_value posted, escaped");
    out.clear();
    gweb::field_value(out, pr, "empty", "fallback");
    check_eq(out, "", "field_value posted empty stays empty");
    out.clear();
    gweb::field_value(out, pr, "missing", "<fb>");
    check_eq(out, "&lt;fb&gt;", "field_value absent uses escaped fallback");
    let gr, gp = http::parse_request("GET /f?name=zzz HTTP/1.1\r\nHost: a\r\n\r\n");
    out.clear();
    gweb::field_value(out, gr, "name", "a&b");
    check_eq(out, "a&amp;b", "field_value on GET uses fallback");

    // errors_json
    var je = gweb::no_errors();
    gweb::add_error(je, "email", "Required.");
    gweb::add_error(je, "name", "Say \"hi\"");
    var res = http::new_response();
    gweb::errors_json(res, je);
    check(res.status == http::Status.UnprocessableEntity, "errors_json status");
    check_eq(res.body, "{\"errors\":{\"email\":\"Required.\",\"name\":\"Say \\\"hi\\\"\"}}", "errors_json body");
    var res2 = http::new_response();
    let none = gweb::no_errors();
    gweb::errors_json(res2, none);
    check_eq(res2.body, "{\"errors\":{}}", "errors_json empty");

    // Ctx.status
    var ctx = gweb::_new_ctx(0, -1);
    check(ctx.status == 0, "status defaults to 0");
    gweb::set_status(ctx, 409);
    check(ctx.status == 409, "set_status");
    gweb::unprocessable(ctx);
    check(ctx.status == 422, "unprocessable");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
