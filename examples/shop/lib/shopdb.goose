// The shop's SQLite queries (DESIGN-ADDENDUM-2, question 3). Each worker
// thread has its own read-only connection; statements are cached on it.
// The database is $SHOP_DB, else data/shop.db under the working directory.
namespace shopdb;

import std;
import os;
import json;
import sqlite;

struct Product { id: i64, name: u8[..64], category: u8[..16], cents: i64, featured: bool, description: u8[..256] }

let ONE = "SELECT id, name, category, cents, featured, description FROM products WHERE id = ?";
let FEATURED = "SELECT id, name, category, cents, featured, description FROM products WHERE featured = 1 ORDER BY id";
let ALL = "SELECT id, name, category, cents, featured, description FROM products ORDER BY id";

var db_path: u8[..1024] = "";

fn conn() -> sqlite::Db {
    if db_path.len == 0 {
        var p: u8[>..] = [];
        if !env("SHOP_DB", p) || p.len == 0 || p.len > 1024 { p.clear(); p.append("data/shop.db"); }
        db_path.append(p);
    }
    return sqlite::local(db_path);
}

// Copies a text column into a fixed field, cut to fit.
fn put_text<T>(s: sqlite::Stmt, col: i64, cap: i64, field: T&) {
    var t: u8[>..] = [];
    sqlite::text(s, col, t);
    field.clear();
    field.append(t[..min(t.len, cap)]);
}

fn row(s: sqlite::Stmt) -> Product {
    var p = Product { id: sqlite::int(s, 0), name: "", category: "", cents: sqlite::int(s, 3),
                      featured: sqlite::int(s, 4) != 0, description: "" };
    put_text(s, 1, 64, p.name);
    put_text(s, 2, 16, p.category);
    put_text(s, 5, 256, p.description);
    return p;
}

// One product. False when there is no such row or the database failed.
fn product(id: i64, p: Product&) -> bool {
    let s = sqlite::prepare(conn(), ONE);
    if !sqlite::bind(s, 1, id) { return false; }
    if !sqlite::step(s) { return false; }
    p = row(s);
    sqlite::reset(s);
    return true;
}

fn rows(sql: const u8[:], out: Product[>..]&) -> bool {
    let s = sqlite::prepare(conn(), sql);
    if !sqlite::ok(s) { return false; }
    while sqlite::step(s) { out.push(row(s)); }
    return true;
}

fn featured(out: Product[>..]&) -> bool { rows(FEATURED, out) }
fn all(out: Product[>..]&) -> bool { rows(ALL, out) }

// The same JSON as shop::product_json.
fn product_json(out: u8[>..]&, p: const Product&) {
    out.push('{');
    json::format_key(out, "id"); json::format_int(out, p.id); out.push(',');
    json::format_key(out, "name"); json::format_string(out, p.name); out.push(',');
    json::format_key(out, "category"); json::format_string(out, p.category); out.push(',');
    json::format_key(out, "cents"); json::format_int(out, p.cents); out.push(',');
    json::format_key(out, "featured"); json::format_bool(out, p.featured); out.push(',');
    json::format_key(out, "description"); json::format_string(out, p.description);
    out.push('}');
}
