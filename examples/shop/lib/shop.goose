// Helpers shared by the shop's routes and pages.
namespace shop;

import std;
import json;
import lib.catalog;

// "$12.34", for templates: {{> shop::price(p.cents)}}
fn price(out: u8[>..]&, cents: i64) {
    format(out, "$", cents / 100, ".");
    if cents % 100 < 10 { out.push('0'); }
    format(out, cents % 100);
}

fn find_product(id: i64) -> i64 { catalog::ITEMS.find_index() { it.id == id } }

fn product_json(out: u8[>..]&, p: const catalog::Product&) {
    out.push('{');
    json::format_key(out, "id"); json::format_int(out, p.id); out.push(',');
    json::format_key(out, "name"); json::format_string(out, p.name); out.push(',');
    json::format_key(out, "category"); json::format_string(out, p.category); out.push(',');
    json::format_key(out, "cents"); json::format_int(out, p.cents); out.push(',');
    json::format_key(out, "featured"); json::format_bool(out, p.featured); out.push(',');
    json::format_key(out, "description"); json::format_string(out, p.description);
    out.push('}');
}

// Reads {"title": "...", "done": true} with either field optional.
struct TodoInput { title: u8[..200], has_title: bool, done: bool, has_done: bool }

fn parse_todo(body: const u8[:]) -> TodoInput, bool {
    var input = TodoInput { title: "", has_title: false, done: false, has_done: false };
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, e = json::parse(body, doc, decoded);
    if e.len > 0 { return input, false; }
    let t, has_t = json::as_string(json::member(root, "title"));
    if has_t {
        if t.len == 0 || t.len > 200 { return input, false; }
        input.title.append(t);
        input.has_title = true;
    }
    let d, has_d = json::as_bool(json::member(root, "done"));
    if has_d { input.done = d; input.has_done = true; }
    return input, true;
}
