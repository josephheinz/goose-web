import std;
import net.http;
import gweb;
import gweb.testing;
import gweb.forms.valid;
import views;
import lib.page;
import v_widgets_Hero;
import v_types_Landing;

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

// The request holds slices into raw, so the caller owns the buffer.
fn get_req(raw: u8[>..]&) -> http::Request {
    raw.clear();
    raw.append("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    let req, parsed = http::parse_request(raw);
    return req;
}

fn post_req(raw: u8[>..]&, body: const u8[:]) -> http::Request {
    raw.clear();
    format(raw, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ", body.len, "\r\n\r\n", body);
    let req, parsed = http::parse_request(raw);
    return req;
}

fn test_registry(t: gweb::Tester&) {
    gweb::expect(t, views::widgets_count() == 2, "two widgets");
    eq(t, views::widgets_name(0), "Hero", "widgets are sorted: Hero first");
    eq(t, views::widgets_name(1), "Text", "then Text");
    gweb::expect(t, views::widgets_index("Text") == 1, "index of Text");
    gweb::expect(t, views::widgets_index("Nope") == -1, "an unknown name is -1");
    gweb::expect(t, views::widgets_index("") == -1, "an empty name is -1");
    gweb::expect(t, views::sections_count() == 1 && views::types_count() == 1 && views::layouts_count() == 1, "one view in each other group");
}

fn test_meta(t: gweb::Tester&) {
    let m = views::widgets_meta(views::widgets_index("Hero"));
    eq(t, m.name, "Hero", "meta name");
    eq(t, m.group, "widgets", "meta group");
    eq(t, m.label, "Hero banner", "LABEL");
    eq(t, m.icon, "image", "ICON");
    gweb::expect(t, m.fields.len == 6, "Hero has six fields");
    eq(t, m.fields[0].name, "title", "field 0");
    eq(t, m.fields[0].label, "Headline", "UI label");
    eq(t, m.fields[0].help, "Up to 60 characters.", "UI help");
    gweb::expect(t, m.fields[0].required && m.fields[0].cap == 60 && m.fields[0].kind == gweb::FieldKind.Text, "title: required text of 60");
    eq(t, m.fields[1].label, "Count", "a label comes from the field name");
    gweb::expect(t, !m.fields[1].required && m.fields[1].kind == gweb::FieldKind.Int, "count: optional int");
    gweb::expect(t, m.fields[2].kind == gweb::FieldKind.Bool, "shout: bool");
    gweb::expect(t, m.fields[3].kind == gweb::FieldKind.Group && m.fields[3].ty == "Badge", "badge: group of Badge");
    gweb::expect(t, m.fields[4].kind == gweb::FieldKind.Foreign && m.fields[4].ty == "link::Link", "more: foreign link::Link");
    eq(t, m.fields[4].label, "More link", "UI label of a foreign field");
    gweb::expect(t, m.fields[5].kind == gweb::FieldKind.List && m.fields[5].ty == "Cta" && m.fields[5].cap == 64, "ctas: repeater of Cta");
    eq(t, m.fields[5].label, "Ctas", "repeater label");
    gweb::expect(t, m.slots.len == 0, "a widget has no slots");

    let tc = views::sections_meta(0);
    eq(t, tc.label, "Two column", "a missing LABEL comes from the name");
    gweb::expect(t, tc.slots.len == 2, "TwoColumn has two zones");
    eq(t, tc.slots[0].name, "left", "zone left");
    eq(t, tc.slots[0].allow, "Hero Text", "its allow list");
    gweb::expect(t, gweb::_slot_allows(tc.slots[0], "Hero") && !gweb::_slot_allows(tc.slots[0], "Other"), "slot_allows");
    eq(t, tc.slots[1].allow, "Text", "zone right");
    gweb::expect(t, tc.fields.len == 2 && tc.fields[0].kind == gweb::FieldKind.Enum && tc.fields[0].ty == "Gap", "TwoColumn: gap enum");

    let ty = views::types_meta(0);
    gweb::expect(t, ty.slots.len == 1 && ty.slots[0].name == "main" && ty.slots[0].allow == "TwoColumn", "the type's area");
    let lay = views::layouts_meta(0);
    gweb::expect(t, lay.slots.len == 1 && lay.slots[0].name == "body" && lay.slots[0].allow == "", "the layout's body slot allows all");
    let none = views::widgets_meta(99);
    gweb::expect(t, none.name.len == 0, "meta of an unknown index is empty");
}

fn test_render_tree(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var ctx = gweb::_new_ctx(0, -1);
    var doc = pg::Doc { type_name: "", type_props: "", nodes: [], missing: 0 };
    doc.type_name.append("Landing");
    doc.type_props.append("{\"theme\":\"Dark\",\"intro\":\"Hi <b>\"}");
    let sec = pg::node(doc, -1, "main", true, "TwoColumn", "{\"reverse\":true}");
    pg::node(doc, sec, "left", false, "Hero", "{\"title\":\"Hello\",\"badge\":{\"text\":\"new\",\"level\":2},\"ctas\":[{\"label\":\"Go\",\"url\":\"/go\",\"primary\":true},{\"label\":\"Two\"}]}");
    pg::node(doc, sec, "right", false, "Text", "{\"body\":\"Some *words* and <i>raw</i>\"}");
    pg::node(doc, sec, "right", false, "Gone", "{}");
    var out: u8[>..] = [];
    pg::render(out, req, ctx, doc);
    has(t, out, "<title>Demo</title>", "the layout renders with its props");
    has(t, out, "<!--page--><main class=\"landing dark\"><p class=\"intro\">Hi &lt;b&gt;</p>", "the type renders inside the layout's slot");
    has(t, out, "<section class=\"two-col gap-true\"><div><div class=\"hero\"><h2>Hello</h2><span class=\"badge\">new:2</span>", "the section fills its left zone with a Hero");
    has(t, out, "<a class=\"cta primary\" href=\"/go\">Go</a><a class=\"cta\" href=\"/\">Two</a></div></div>", "the repeater renders, with defaults");
    has(t, out, "<div><div class=\"text\"><p>Some <em>words</em> and &lt;i&gt;raw&lt;/i&gt;</p>\n</div>[no such view]</div></section>", "markdown renders in a widget; a view missing from code is reported by the glue");
    has(t, out, "</main><!--/page--></body></html>", "the layout closes");
}

fn test_render_unknown_and_bad_json(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    let req = get_req(raw);
    var ctx = gweb::_new_ctx(0, -1);
    var doc = pg::Doc { type_name: "", type_props: "", nodes: [], missing: 0 };
    var out: u8[>..] = [];
    gweb::expect(t, !views::widgets_render(out, req, ctx, "Nope", "{}", doc, 0, pg::fill), "an unknown name renders nothing and returns false");
    gweb::expect(t, out.len == 0, "and writes nothing");
    gweb::expect(t, views::widgets_render(out, req, ctx, "Text", "not json at all", doc, 0, pg::fill), "bad JSON still renders (defaults)");
    has(t, out, "<div class=\"text\"></div>", "with the defaults");
    out.clear();
    gweb::expect(t, views::widgets_render(out, req, ctx, "Text", "", doc, 0, pg::fill), "empty JSON renders the defaults");
}

fn test_read_lenient(t: gweb::Tester&) {
    var p = v_widgets_Hero::Props { .. };
    var w = v_widgets_Hero::read("{\"title\":\"A\",\"count\":7,\"shout\":true,\"badge\":{\"text\":\"b\",\"level\":-4},\"more\":{\"href\":\"/m\",\"text\":\"t\"},\"ctas\":[{\"label\":\"x\",\"align\":\"Right\"}]}", p);
    gweb::expect(t, w == 0, "a clean document has no warnings");
    gweb::expect(t, p.title == "A" && p.count == 7 && p.shout && p.badge.text == "b" && p.badge.level == -4, "fields read");
    gweb::expect(t, p.more.href == "/m" && p.more.text == "t", "the foreign type reads through link::gw_read");
    gweb::expect(t, p.ctas.len == 1 && p.ctas[0].label == "x" && p.ctas[0].align == v_widgets_Hero::Align.Right && p.ctas[0].url == "/", "a repeater item reads, with its defaults");

    var q = v_widgets_Hero::Props { .. };
    w = v_widgets_Hero::read("{\"unknown\":[1,{\"a\":2}],\"title\":5,\"count\":\"x\",\"shout\":1,\"badge\":3,\"ctas\":{},\"more\":[]}", q);
    gweb::expect(t, w == 5 || w == 6, "wrong types are counted");
    gweb::expect(t, q.title == "" && q.count == 3 && !q.shout && q.badge.text == "" && q.ctas.len == 0, "a wrong type keeps the default");

    var r = v_widgets_Hero::Props { .. };
    w = v_widgets_Hero::read("{\"count\":1.5,\"title\":\"0123456789012345678901234567890123456789012345678901234567\xC3\xA9\xC3\xA9\"}", r);
    gweb::expect(t, w == 2, "a fraction in an int, and text over its cap, are warnings");
    gweb::expect(t, r.count == 3, "the int keeps its default");
    gweb::expect(t, r.title.len == 60 && r.title[59] == 0xA9, "long text is cut at the cap, on a character boundary");

    var s = v_widgets_Hero::Props { .. };
    w = v_widgets_Hero::read("{\"heading\":\"Old\"}", s);
    gweb::expect(t, w == 0 && s.title == "Old", "RENAMED: a stored heading reads as title");
    w = v_widgets_Hero::read("{\"head\":\"Older\",\"title\":\"New\"}", s);
    gweb::expect(t, s.title == "New", "both renamed keys read; the last wins");

    var u = v_widgets_Hero::Props { .. };
    w = v_widgets_Hero::read("{\"title\":\"x\"", u);
    gweb::expect(t, w >= 1 && u.title == "x", "truncated JSON keeps what was read and warns");
    var items = v_widgets_Hero::Props { .. };
    var many: u8[>..] = [];
    many.append("{\"ctas\":[");
    for i in 70 { if i > 0 { many.push(','); } many.append("{}"); }
    many.append("]}");
    w = v_widgets_Hero::read(many, items);
    gweb::expect(t, items.ctas.len == 64 && w == 6, "a repeater keeps 64 items and counts the rest");
    var en = v_widgets_Hero::Props { .. };
    w = v_widgets_Hero::read("{\"ctas\":[{\"align\":\"Up\"},{\"align\":\"Center\"}]}", en);
    gweb::expect(t, w == 1 && en.ctas[0].align == v_widgets_Hero::Align.Left && en.ctas[1].align == v_widgets_Hero::Align.Center, "an unknown enum name keeps the default");
}

fn test_write_canonical(t: gweb::Tester&) {
    var d: u8[>..] = [];
    gweb::expect(t, views::widgets_defaults("Hero", d), "defaults of a known view");
    eq(t, d, "{\"title\":\"\",\"count\":3,\"shout\":false,\"badge\":{\"text\":\"\",\"level\":0},\"more\":{\"href\":\"\",\"text\":\"\"},\"ctas\":[]}", "defaults, canonical order");
    var d2: u8[>..] = [];
    gweb::expect(t, !views::widgets_defaults("Nope", d2) && d2.len == 0, "defaults of an unknown view");
    var p = v_widgets_Hero::Props { .. };
    v_widgets_Hero::read("{\"z\":1,\"count\":9,\"title\":\"q\\\"uote\\n\",\"ctas\":[{\"label\":\"a\",\"align\":\"Right\"}]}", p);
    var out: u8[>..] = [];
    v_widgets_Hero::write(out, p);
    eq(t, out, "{\"title\":\"q\\\"uote\\n\",\"count\":9,\"shout\":false,\"badge\":{\"text\":\"\",\"level\":0},\"more\":{\"href\":\"\",\"text\":\"\"},\"ctas\":[{\"label\":\"a\",\"url\":\"/\",\"primary\":false,\"align\":\"Right\"}]}",
       "write is canonical: declaration order, defaults written, unknown keys dropped");
    var again = v_widgets_Hero::Props { .. };
    v_widgets_Hero::read(out, again);
    var out2: u8[>..] = [];
    v_widgets_Hero::write(out2, again);
    gweb::expect(t, out == out2, "read then write is stable");
}

fn test_form(t: gweb::Tester&) {
    var errs = gweb::no_errors();
    var out: u8[>..] = [];
    gweb::expect(t, views::widgets_form(out, "Hero", "{\"title\":\"A<b>\",\"badge\":{\"text\":\"t\"},\"ctas\":[{\"label\":\"x\"}]}", errs, "p."), "form of a known view");
    has(t, out, "<label for=\"p.title\">Headline</label> <input type=\"text\" id=\"p.title\" name=\"p.title\" value=\"A&lt;b&gt;\" maxlength=\"60\" required>", "a required text field");
    has(t, out, "<small class=\"gw-help\">Up to 60 characters.</small>", "the help text");
    has(t, out, "<label for=\"p.count\">Count</label> <input type=\"number\" id=\"p.count\" name=\"p.count\" value=\"3\">", "an int field");
    has(t, out, "<input type=\"checkbox\" id=\"p.shout\" name=\"p.shout\">", "a bool field");
    has(t, out, "<fieldset class=\"gw-group\"><legend>Badge</legend>", "a group is a fieldset");
    has(t, out, "name=\"p.badge.text\" value=\"t\"", "a group field's name is dotted");
    has(t, out, "<label for=\"p.badge.text\">Badge text</label>", "a dotted UI label");
    has(t, out, "<div class=\"link-picker\" data-name=\"p.more\">More link: </div>", "a foreign field is drawn by link::gw_field");
    has(t, out, "<input type=\"hidden\" name=\"p.ctas.n\" value=\"1\">", "a repeater posts its count");
    has(t, out, "name=\"p.ctas.0.label\" value=\"x\"", "a repeater item's fields are indexed");
    has(t, out, "<select id=\"p.ctas.0.align\" name=\"p.ctas.0.align\"><option selected>Left</option><option>Center</option><option>Right</option></select>", "an enum is a select");

    var tx: u8[>..] = [];
    gweb::expect(t, views::widgets_form(tx, "Text", "{\"body\":\"a < b\"}", errs, ""), "form of Text");
    has(t, tx, "<textarea id=\"body\" name=\"body\" maxlength=\"2000\" data-editor=\"markdown\">a &lt; b</textarea>", "editor markdown is a textarea");
    var bad: u8[>..] = [];
    gweb::expect(t, !views::widgets_form(bad, "Nope", "{}", errs, ""), "form of an unknown view is false");

    gweb::add_error(errs, "title", "Too short.");
    var e: u8[>..] = [];
    views::widgets_form(e, "Hero", "{}", errs, "");
    has(t, e, "aria-invalid=\"true\"", "an error marks the field");
    has(t, e, "<span class=\"gw-error\" id=\"title-error\">Too short.</span>", "and shows its message");
}

fn test_parse(t: gweb::Tester&) {
    var raw: u8[>..] = [];
    var errs = gweb::no_errors();
    var out: u8[>..] = [];
    let req = post_req(raw, "title=Hello&count=5&shout=on&badge.text=new&badge.level=2&more.href=%2Fm&more.text=More&ctas.n=2&ctas.0.label=A&ctas.0.url=%2Fa&ctas.0.primary=on&ctas.0.align=Right&ctas.1.label=B");
    gweb::expect(t, views::widgets_parse(req, "Hero", "", out, errs), "a good form parses");
    gweb::expect(t, !gweb::has_errors(errs), "with no errors");
    eq(t, out, "{\"title\":\"Hello\",\"count\":5,\"shout\":true,\"badge\":{\"text\":\"new\",\"level\":2},\"more\":{\"href\":\"/m\",\"text\":\"More\"},\"ctas\":[{\"label\":\"A\",\"url\":\"/a\",\"primary\":true,\"align\":\"Right\"},{\"label\":\"B\",\"url\":\"/\",\"primary\":false,\"align\":\"Left\"}]}", "the canonical JSON");

    var errs2 = gweb::no_errors();
    var out2: u8[>..] = [];
    let req2 = post_req(raw, "count=x&badge.level=y&ctas.n=1&ctas.0.align=Up");
    gweb::expect(t, !views::widgets_parse(req2, "Hero", "", out2, errs2), "a bad form does not parse");
    eq(t, gweb::error_for(errs2, "title"), "Required.", "a field without a default is required");
    eq(t, gweb::error_for(errs2, "count"), "Enter a whole number.", "a bad int");
    eq(t, gweb::error_for(errs2, "badge.level"), "Enter a whole number.", "a bad int in a group");
    eq(t, gweb::error_for(errs2, "ctas.0.align"), "Choose one of the options.", "a bad enum in a repeater item");
    has(t, out2, "\"count\":3", "the JSON is still written after an error: a field that did not parse keeps its default");
    has(t, out2, "\"badge\":{\"text\":\"\",\"level\":0}", "and the rest is what was read");

    var errs3 = gweb::no_errors();
    var out3: u8[>..] = [];
    let req3 = post_req(raw, "title=x");
    gweb::expect(t, !views::widgets_parse(req3, "Hero", "", out3, errs3), "the user's validate runs");
    eq(t, gweb::error_for(errs3, "title"), "Use at least 2 characters.", "its message");

    var errsp = gweb::no_errors();
    var outp: u8[>..] = [];
    let reqp = post_req(raw, "w.title=x&w.count=9");
    gweb::expect(t, !views::widgets_parse(reqp, "Hero", "w.", outp, errsp), "validate runs with a prefix");
    eq(t, gweb::error_for(errsp, "w.title"), "Use at least 2 characters.", "and its error is under the control's name, prefix included");
    eq(t, gweb::error_for(errsp, "title"), "", "not under the bare field name");
    has(t, outp, "\"title\":\"x\",\"count\":9", "the JSON of the failed form holds what was typed");
    var shown: u8[>..] = [];
    views::widgets_form(shown, "Hero", outp, errsp, "w.");
    has(t, shown, "<span class=\"gw-error\" id=\"w.title-error\">Use at least 2 characters.</span>", "the form drawn from it shows the typed value and the message");
    has(t, shown, "name=\"w.title\" value=\"x\"", "with the typed value");

    var errs4 = gweb::no_errors();
    var out4: u8[>..] = [];
    let req4 = post_req(raw, "w.title=Prefixed&w.ctas.n=999");
    gweb::expect(t, !views::widgets_parse(req4, "Hero", "w.", out4, errs4), "a repeater count above its limit");
    eq(t, gweb::error_for(errs4, "w.ctas.n"), "Too many items.", "is refused");

    var errs5 = gweb::no_errors();
    var out5: u8[>..] = [];
    let req5 = post_req(raw, "w.title=Prefixed");
    gweb::expect(t, views::widgets_parse(req5, "Hero", "w.", out5, errs5), "a prefix selects the fields");
    has(t, out5, "\"title\":\"Prefixed\"", "and reads them");

    var errs6 = gweb::no_errors();
    var out6: u8[>..] = [];
    let req6 = post_req(raw, "x=1");
    gweb::expect(t, !views::widgets_parse(req6, "Nope", "", out6, errs6), "an unknown view does not parse");
    eq(t, gweb::error_for(errs6, ""), "Unknown view.", "and says so");

    var errs7 = gweb::no_errors();
    var out7: u8[>..] = [];
    let req7 = post_req(raw, "theme=Dark&intro=Hello");
    gweb::expect(t, views::types_parse(req7, "Landing", "", out7, errs7), "a view with no required field parses");
    eq(t, out7, "{\"theme\":\"Dark\",\"intro\":\"Hello\"}", "an enum field");
    var errs8 = gweb::no_errors();
    var out8: u8[>..] = [];
    let req8 = post_req(raw, "intro=Hello");
    views::types_parse(req8, "Landing", "", out8, errs8);
    eq(t, out8, "{\"theme\":\"Light\",\"intro\":\"Hello\"}", "an absent optional enum keeps its default");
}
