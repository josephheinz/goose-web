import std;
import net.http;
import gweb;
import gweb.testing;
import gweb.forms.valid;
import views;

fn eq(t: gweb::Tester&, got: const u8[:], want: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": got '", got, "', want '", want, "'");
    gweb::expect(t, got == want, msg);
}

fn has(t: gweb::Tester&, text: const u8[:], needle: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": '", text, "' lacks '", needle, "'");
    gweb::expect(t, find(text, needle) >= 0, msg);
}

fn lacks(t: gweb::Tester&, text: const u8[:], needle: const u8[:], what: const u8[:]) {
    var msg: u8[>..] = [];
    format(msg, what, ": '", text, "' has '", needle, "'");
    gweb::expect(t, find(text, needle) < 0, msg);
}

fn post_req(raw: u8[>..]&, body: const u8[:]) -> http::Request {
    raw.clear();
    format(raw, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ", body.len, "\r\n\r\n", body);
    let req, parsed = http::parse_request(raw);
    return req;
}

fn get_req(raw: u8[>..]&) -> http::Request {
    raw.clear();
    raw.append("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    let req, parsed = http::parse_request(raw);
    return req;
}

let JSON = "{\"title\":\"Hi\",\"count\":4,\"on\":true,\"rows\":[{\"label\":\"Milk\",\"n\":1},{\"label\":\"Eggs <b>\",\"n\":2}]}";

// The plain form keeps its 1.0 markup.
fn test_plain_form_unchanged(t: gweb::Tester&) {
    var errs = gweb::no_errors();
    gweb::add_error(errs, "title", "Required.");
    var out: u8[>..] = [];
    gweb::expect(t, views::widgets_form(out, "Card", JSON, errs, ""), "the plain form draws");
    has(t, out, " <small class=\"gw-help\">Up to 30 bytes.</small>", "help has no id");
    has(t, out, "aria-invalid=\"true\" aria-describedby=\"title-error\"", "an error is described by itself only");
    has(t, out, "<fieldset class=\"gw-item\"><legend>#1</legend>", "the item legend is a number");
    lacks(t, out, "<button", "no buttons");
    lacks(t, out, "Milk</legend>", "no item label");
}

// 3. Help text is linked to its field; 1. item buttons and labels.
fn test_rich_form(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var errs = gweb::no_errors();
    var out: u8[>..] = [];
    gweb::expect(t, views::widgets_form_req(out, req, "Card", JSON, errs, "w."), "the rich form draws");
    has(t, out, " <small class=\"gw-help\" id=\"w.title-help\">Up to 30 bytes.</small>", "help has an id");
    has(t, out, "name=\"w.title\" value=\"Hi\" maxlength=\"30\" required aria-describedby=\"w.title-help\">", "the control names the help");
    lacks(t, out, "w.count-help", "a field with no help has no help id");
    has(t, out, "<legend>#1: Milk</legend>", "the item legend has the ITEM_LABEL text");
    has(t, out, "<legend>#2: Eggs &lt;b&gt;</legend>", "escaped");
    has(t, out, "<button type=\"submit\" name=\"w.rows.act\" value=\"\" hidden tabindex=\"-1\"></button>", "a hidden default button comes first");
    has(t, out, "name=\"w.rows.act\" value=\"up:0\" disabled aria-label=\"Move up item 1\">Up</button>", "the first item cannot move up");
    has(t, out, "name=\"w.rows.act\" value=\"down:0\" aria-label=\"Move down item 1\">Down</button>", "it can move down");
    has(t, out, "name=\"w.rows.act\" value=\"del:1\" aria-label=\"Remove item 2\">Remove</button>", "every item has Remove");
    has(t, out, "name=\"w.rows.act\" value=\"down:1\" disabled", "the last item cannot move down");
    has(t, out, "<button type=\"submit\" name=\"w.rows.act\" value=\"add\" aria-label=\"Add an item\">Add</button>", "Add");
    // The limit: three rows disable Add.
    var full: u8[>..] = [];
    views::widgets_form_req(full, req, "Card", "{\"rows\":[{},{},{}]}", errs, "");
    has(t, full, "value=\"add\" disabled", "Add is off at the limit");

    var e2 = gweb::no_errors();
    gweb::add_error(e2, "w.title", "Required.");
    var out2: u8[>..] = [];
    views::widgets_form_req(out2, req, "Card", JSON, e2, "w.");
    has(t, out2, "aria-invalid=\"true\" aria-describedby=\"w.title-help w.title-error\"", "the help id and the error id");
    var none: u8[>..] = [];
    gweb::expect(t, !views::widgets_form_req(none, req, "Nope", "{}", errs, ""), "an unknown view is false");
}

// 2. The redrawn form shows what was typed.
fn test_echo_bad_input(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    var errs = gweb::no_errors();
    var json: u8[>..] = [];
    let req = post_req(raw, "title=A%3Cb%3E&count=12a&rows.n=1&rows.0.label=x&rows.0.n=9z");
    gweb::expect(t, !views::widgets_parse(req, "Card", "", json, errs), "a bad form does not parse");
    eq(t, gweb::error_for(errs, "count"), "Enter a whole number.", "the int error");
    has(t, json, "\"count\":3", "the JSON keeps the default");
    var out: u8[>..] = [];
    views::widgets_form_req(out, req, "Card", json, errs, "");
    has(t, out, "name=\"count\" value=\"12a\"", "the rich form shows 12a");
    has(t, out, "name=\"rows.0.n\" value=\"9z\"", "also inside a repeater item");
    has(t, out, "name=\"title\" value=\"A&lt;b&gt;\"", "a field without an error shows its value");
    var plain: u8[>..] = [];
    views::widgets_form(plain, "Card", json, errs, "");
    has(t, plain, "name=\"count\" value=\"3\"", "the plain form still shows the default");

    // Text over its cap: the JSON keeps the default, the form shows the text.
    var e2 = gweb::no_errors();
    var j2: u8[>..] = [];
    let req2 = post_req(raw, "title=0123456789012345678901234567890123456789");
    gweb::expect(t, !views::widgets_parse(req2, "Card", "", j2, e2), "text over the cap");
    var o2: u8[>..] = [];
    views::widgets_form_req(o2, req2, "Card", j2, e2, "");
    has(t, o2, "value=\"0123456789012345678901234567890123456789\"", "the typed text shows");

    // A required field left blank shows blank, not a default.
    var e3 = gweb::no_errors();
    var j3: u8[>..] = [];
    let req3 = post_req(raw, "title=&count=");
    views::widgets_parse(req3, "Card", "", j3, e3);
    var o3: u8[>..] = [];
    views::widgets_form_req(o3, req3, "Card", j3, e3, "");
    has(t, o3, "name=\"title\" value=\"\"", "blank stays blank");

    // A GET request never overrides.
    var g: u8[>..] = [];
    let greq = get_req(g);
    var o4: u8[>..] = [];
    views::widgets_form_req(o4, greq, "Card", "{\"count\":8}", e2, "");
    has(t, o4, "name=\"count\" value=\"8\"", "a GET shows the stored value");
}

// 1. The buttons, applied by g_parse. False with no errors: show the form again, do not save.
fn act(t: gweb::Tester&, body: const u8[:], want_json: const u8[:], what: const u8[:]) {
    var raw: u8[>..] = [];
    var errs = gweb::no_errors();
    var json: u8[>..] = [];
    let req = post_req(raw, body);
    var m: u8[>..] = [];
    format(m, what, ": parse returns false");
    gweb::expect(t, !views::widgets_parse(req, "Card", "", json, errs), m);
    m.clear();
    format(m, what, ": no errors");
    gweb::expect(t, errs.n == 0, m);
    has(t, json, want_json, what);
}

fn test_actions(t: gweb::Tester&) {
    let base = "title=T&rows.n=2&rows.0.label=A&rows.1.label=B&rows.0.n=1&rows.1.n=2";
    var b: u8[>..] = [];
    format(b, base, "&rows.act=down%3A0");
    act(t, b, "\"rows\":[{\"label\":\"B\",\"n\":2},{\"label\":\"A\",\"n\":1}]", "down:0 swaps");
    b.clear();
    format(b, base, "&rows.act=up%3A1");
    act(t, b, "\"rows\":[{\"label\":\"B\",\"n\":2},{\"label\":\"A\",\"n\":1}]", "up:1 swaps");
    b.clear();
    format(b, base, "&rows.act=del%3A0");
    act(t, b, "\"rows\":[{\"label\":\"B\",\"n\":2}]", "del:0 removes");
    b.clear();
    format(b, base, "&rows.act=add");
    act(t, b, "\"rows\":[{\"label\":\"A\",\"n\":1},{\"label\":\"B\",\"n\":2},{\"label\":\"\",\"n\":0}]", "add appends a default item");
    // A form with errors and an action: no errors are shown, the form is not saved.
    act(t, "rows.n=1&rows.0.label=A&count=zz&rows.act=add", "\"rows\":[{\"label\":\"A\",\"n\":0},{\"label\":\"\",\"n\":0}]", "an action drops the errors of the other fields");
    // Out of range or unknown actions change nothing.
    for a in ["up%3A0", "down%3A1", "del%3A9", "del%3Ax", "bogus", ""] {
        var raw: u8[>..] = [];
        var body: u8[>..] = [];
        format(body, base, "&rows.act=", a);
        var errs = gweb::no_errors();
        var json: u8[>..] = [];
        let req = post_req(raw, body);
        let ok = views::widgets_parse(req, "Card", "", json, errs);
        var m: u8[>..] = [];
        format(m, "action '", a, "'");
        if a == "up%3A0" || a == "down%3A1" || a == "del%3A9" {
            gweb::expect(t, !ok && errs.n == 0, m);
        } else {
            gweb::expect(t, ok && errs.n == 0, m);
        }
        has(t, json, "\"rows\":[{\"label\":\"A\",\"n\":1},{\"label\":\"B\",\"n\":2}]", m);
    }
    // At the limit Add says so.
    var raw: u8[>..] = [];
    var errs = gweb::no_errors();
    var json: u8[>..] = [];
    let req = post_req(raw, "title=T&rows.n=3&rows.act=add");
    gweb::expect(t, !views::widgets_parse(req, "Card", "p.", json, errs), "add at the limit");
    var errs2 = gweb::no_errors();
    let req2 = post_req(raw, "p.title=T&p.rows.n=3&p.rows.act=add");
    gweb::expect(t, !views::widgets_parse(req2, "Card", "p.", json, errs2), "add at the limit, with a prefix");
    eq(t, gweb::error_for(errs2, "p.rows.n"), "Too many items.", "is an error");
    // A prefix selects the button.
    json.clear();
    var errs3 = gweb::no_errors();
    let req3 = post_req(raw, "p.title=T&p.rows.n=1&p.rows.0.label=A&p.rows.act=add");
    gweb::expect(t, !views::widgets_parse(req3, "Card", "p.", json, errs3) && errs3.n == 0, "a prefixed add");
    has(t, json, "\"rows\":[{\"label\":\"A\",\"n\":0},{\"label\":\"\",\"n\":0}]", "adds under the prefix");
    // The redrawn form shows the new count.
    var out: u8[>..] = [];
    views::widgets_form_req(out, req3, "Card", json, errs3, "p.");
    has(t, out, "name=\"p.rows.n\" value=\"2\"", "the count follows the list");
}
