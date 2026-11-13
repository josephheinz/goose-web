// The fixture CMS store: SQLite, one writer on the state owner, readers on the workers (README: SQLite, Writes).
namespace cms;

import std;
import os;
import sqlite;
import gweb;

let DB = "data/cms.db";
let MEDIA = "data/media";

struct Channel { id: i64 = 0, host: u8[..128] = "", code: u8[..32] = "", name: u8[..64] = "", layout: u8[..32] = "" }
struct Widget { id: i64 = 0, parent: i64 = 0, zone: u8[..16] = "", section: bool = false, view: u8[..32] = "", props: u8[..1000] = "" }
struct Doc {
    channel: Channel = Channel { .. },
    id: i64 = 0,
    path: u8[..200] = "",
    type_name: u8[..32] = "",
    props: u8[..1000] = "",
    rev: i64 = 0,
    widgets: Widget[..8] = [],
}
struct Row { id: i64 = 0, host: u8[..128] = "", path: u8[..200] = "", title: u8[..80] = "", rev: i64 = 0 }

// One statement per step (a string literal is one line); migrate runs them in order, once.
let STEPS = [
    "CREATE TABLE channel (id INTEGER PRIMARY KEY, host TEXT UNIQUE NOT NULL, code TEXT NOT NULL, name TEXT NOT NULL, layout TEXT NOT NULL)",
    "CREATE TABLE node (id INTEGER PRIMARY KEY, channel_id INTEGER NOT NULL, path TEXT NOT NULL, type TEXT NOT NULL, props TEXT NOT NULL, rev INTEGER NOT NULL DEFAULT 1, UNIQUE (channel_id, path))",
    "CREATE TABLE widget (id INTEGER PRIMARY KEY, node_id INTEGER NOT NULL, parent INTEGER NOT NULL, zone TEXT NOT NULL, pos INTEGER NOT NULL, section INTEGER NOT NULL, view TEXT NOT NULL, props TEXT NOT NULL)",
    "CREATE TABLE media (id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, name TEXT NOT NULL, size INTEGER NOT NULL)",
    "INSERT INTO channel (id, host, code, name, layout) VALUES (1, 'a.test', 'a', 'Site A', 'Site'), (2, 'b.test', 'b', 'Site B', 'Plain')",
    "INSERT INTO node (id, channel_id, path, type, props) VALUES (1, 1, '/', 'Article', '{\"title\":\"Home A\",\"theme\":\"Light\",\"intro\":\"Welcome to A\"}'), (2, 1, '/about', 'Article', '{\"title\":\"About A\",\"theme\":\"Dark\",\"intro\":\"\"}'), (3, 2, '/', 'Article', '{\"title\":\"Home B\",\"theme\":\"Light\",\"intro\":\"Welcome to B\"}')",
    "INSERT INTO widget (id, node_id, parent, zone, pos, section, view, props) VALUES (1, 1, 0, 'main', 0, 1, 'TwoColumn', '{\"gap\":\"Wide\"}'), (2, 1, 1, 'left', 0, 0, 'Text', '{\"body\":\"Hello **world** from A\"}'), (3, 1, 1, 'right', 0, 0, 'Quote', '{\"text\":\"Quoted on A\",\"by\":\"Ann\"}'), (4, 2, 0, 'main', 0, 0, 'Text', '{\"body\":\"About A\"}'), (5, 3, 0, 'main', 0, 0, 'Text', '{\"body\":\"Hello **world** from B\"}'), (6, 2, 0, 'main', 1, 0, 'Image', '{\"media\":{\"key\":\"m1\",\"name\":\"up.txt\"},\"alt\":\"Uploaded\"}')",
];

// ---------------------------------------------------------------- small helpers

fn put<T>(dst: T&, s: const u8[:]) { dst.clear(); dst.append(s[..min(s.len, dst.cap)]); }

fn text_of<T>(s: sqlite::Stmt, col: i64, dst: T&) {
    var t: u8[>..] = [];
    sqlite::text(s, col, t);
    put(dst, t);
}

// ---------------------------------------------------------------- the owner: every write

var wdb: sqlite::Db = sqlite::Db { h: 0 };

// state.goose init: the one writer, the schema and the seed, before the first request.
fn init() {
    make_dir("data");
    make_dir(MEDIA);
    wdb = sqlite::writer(DB);
    if !sqlite::ok(wdb) { print("cms: ", sqlite::error(wdb)); exit(1); }
    if !sqlite::migrate(wdb, STEPS) { print("cms: migrate: ", sqlite::error(wdb)); exit(1); }
}

// Saves a node's props and the props of its first Text widget (empty: leave the widget). False on a database error.
fn save_node(id: i64, props: const u8[:], text_props: const u8[:]) -> bool {
    if !sqlite::begin(wdb) { return false; }
    defer sqlite::rollback(wdb);
    let u = sqlite::prepare(wdb, "UPDATE node SET props = ?1, rev = rev + 1 WHERE id = ?2");
    sqlite::bind(u, 1, props);
    sqlite::bind(u, 2, id);
    let n, ok = sqlite::update(u);
    if !ok || n != 1 { return false; }
    if text_props.len > 0 {
        let w = sqlite::prepare(wdb, "UPDATE widget SET props = ?1 WHERE id = (SELECT id FROM widget WHERE node_id = ?2 AND view = 'Text' ORDER BY id LIMIT 1)");
        sqlite::bind(w, 1, text_props);
        sqlite::bind(w, 2, id);
        if !sqlite::run(w) { return false; }
    }
    return sqlite::commit(wdb);
}

// A new Article node with an empty Text widget. Returns its id, or 0 (a path that exists, or a database error).
fn create_node(channel: i64, path: const u8[:], props: const u8[:], text_props: const u8[:]) -> i64 {
    if !sqlite::begin(wdb) { return 0; }
    defer sqlite::rollback(wdb);
    let s = sqlite::prepare(wdb, "INSERT INTO node (channel_id, path, type, props) VALUES (?1, ?2, 'Article', ?3)");
    sqlite::bind(s, 1, channel);
    sqlite::bind(s, 2, path);
    sqlite::bind(s, 3, props);
    let id, ok = sqlite::insert(s);
    if !ok { return 0; }
    let w = sqlite::prepare(wdb, "INSERT INTO widget (node_id, parent, zone, pos, section, view, props) VALUES (?1, 0, 'main', 0, 0, 'Text', ?2)");
    sqlite::bind(w, 1, id);
    sqlite::bind(w, 2, text_props);
    if !sqlite::run(w) { return 0; }
    if !sqlite::commit(wdb) { return 0; }
    return id;
}

// Registers an upload; its key is the row id, and the file goes to data/media/KEY/NAME. Returns the key's number, or 0.
fn media_add(name: const u8[:], size: i64) -> i64 {
    if !sqlite::begin(wdb) { return 0; }
    defer sqlite::rollback(wdb);
    let s = sqlite::prepare(wdb, "INSERT INTO media (key, name, size) VALUES ('pending', ?1, ?2)");
    sqlite::bind(s, 1, name);
    sqlite::bind(s, 2, size);
    let id, ok = sqlite::insert(s);
    if !ok { return 0; }
    let k = sqlite::prepare(wdb, "UPDATE media SET key = ?1 WHERE id = ?2");
    var key: u8[>..] = [];
    format(key, "m", id);
    sqlite::bind(k, 1, key);
    sqlite::bind(k, 2, id);
    if !sqlite::run(k) { return 0; }
    if !sqlite::commit(wdb) { return 0; }
    return id;
}

// ---------------------------------------------------------------- readers: any worker

fn reader() -> sqlite::Db { return sqlite::local(DB, sqlite::Mode.QueryOnly); }

fn channel_by_host(host: const u8[:], ch: Channel&) -> bool {
    let s = sqlite::prepare(reader(), "SELECT id, host, code, name, layout FROM channel WHERE host = ?1");
    sqlite::bind(s, 1, host);
    if !sqlite::step(s) { return false; }
    ch.id = sqlite::int(s, 0);
    text_of(s, 1, ch.host);
    text_of(s, 2, ch.code);
    text_of(s, 3, ch.name);
    text_of(s, 4, ch.layout);
    sqlite::reset(s);
    return true;
}

fn load_widgets(db: sqlite::Db, doc: Doc&) {
    let w = sqlite::prepare(db, "SELECT id, parent, zone, section, view, props FROM widget WHERE node_id = ?1 ORDER BY parent, zone, pos");
    sqlite::bind(w, 1, doc.id);
    while sqlite::step(w) {
        if doc.widgets.len >= 8 { sqlite::reset(w); break; }
        var x = Widget { .. };
        x.id = sqlite::int(w, 0);
        x.parent = sqlite::int(w, 1);
        text_of(w, 2, x.zone);
        x.section = sqlite::int(w, 3) != 0;
        text_of(w, 4, x.view);
        text_of(w, 5, x.props);
        doc.widgets.push(x);
    }
}

// The node at path in the channel, with its widgets. False when there is none.
fn load_doc(ch: const Channel&, path: const u8[:], doc: Doc&) -> bool {
    let db = reader();
    let s = sqlite::prepare(db, "SELECT id, path, type, props, rev FROM node WHERE channel_id = ?1 AND path = ?2");
    sqlite::bind(s, 1, ch.id);
    sqlite::bind(s, 2, path);
    if !sqlite::step(s) { return false; }
    doc.channel = ch;
    doc.id = sqlite::int(s, 0);
    text_of(s, 1, doc.path);
    text_of(s, 2, doc.type_name);
    text_of(s, 3, doc.props);
    doc.rev = sqlite::int(s, 4);
    sqlite::reset(s);
    load_widgets(db, doc);
    return true;
}

// A node by id, with its channel and widgets (the admin's edit page).
fn load_by_id(id: i64, doc: Doc&) -> bool {
    let db = reader();
    let s = sqlite::prepare(db, "SELECT c.id, c.host, c.code, c.name, c.layout, n.path, n.type, n.props, n.rev FROM node n JOIN channel c ON c.id = n.channel_id WHERE n.id = ?1");
    sqlite::bind(s, 1, id);
    if !sqlite::step(s) { return false; }
    doc.id = id;
    doc.channel.id = sqlite::int(s, 0);
    text_of(s, 1, doc.channel.host);
    text_of(s, 2, doc.channel.code);
    text_of(s, 3, doc.channel.name);
    text_of(s, 4, doc.channel.layout);
    text_of(s, 5, doc.path);
    text_of(s, 6, doc.type_name);
    text_of(s, 7, doc.props);
    doc.rev = sqlite::int(s, 8);
    sqlite::reset(s);
    load_widgets(db, doc);
    return true;
}

// The props JSON of the first Text widget, "" when the node has none.
fn text_props(doc: const Doc&) -> const u8[:] {
    for i in doc.widgets.len { if doc.widgets[i].view == "Text" { return doc.widgets[i].props; } }
    return "";
}

// Puts submitted JSON in the document, so a form that failed is drawn again as the user typed it.
fn show_typed(doc: Doc&, props: const u8[:], text: const u8[:]) {
    put(doc.props, props);
    if text.len == 0 { return; }
    for i in doc.widgets.len { if doc.widgets[i].view == "Text" { put(doc.widgets[i].props, text); return; } }
}

// Every node: host, path and rev (the dashboard). host "" means all channels.
fn list_nodes(host: const u8[:], rows: Row[..32]&) {
    let s = sqlite::prepare(reader(), "SELECT n.id, c.host, n.path, n.rev, json_extract(n.props, '$.title') FROM node n JOIN channel c ON c.id = n.channel_id WHERE ?1 = '' OR c.host = ?1 ORDER BY c.id, n.path");
    sqlite::bind(s, 1, host);
    while sqlite::step(s) {
        if rows.len >= 32 { sqlite::reset(s); break; }
        var r = Row { .. };
        r.id = sqlite::int(s, 0);
        text_of(s, 1, r.host);
        text_of(s, 2, r.path);
        r.rev = sqlite::int(s, 3);
        text_of(s, 4, r.title);
        rows.push(r);
    }
}

struct MediaRow { key: u8[..32] = "", name: u8[..200] = "", size: i64 = 0 }

fn list_media(rows: MediaRow[..32]&) {
    let s = sqlite::prepare(reader(), "SELECT key, name, size FROM media ORDER BY id");
    while sqlite::step(s) {
        if rows.len >= 32 { sqlite::reset(s); break; }
        var r = MediaRow { .. };
        text_of(s, 0, r.key);
        text_of(s, 1, r.name);
        r.size = sqlite::int(s, 2);
        rows.push(r);
    }
}

// A slug the admin may create: starts with /, plain segments, and a first segment no route or public file uses.
fn slug_ok(path: const u8[:]) -> bool {
    if path.len < 1 || path.len > 200 || path[0] != '/' { return false; }
    if path == "/" { return true; }
    for c in path[1..] {
        let ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '/';
        if !ok { return false; }
    }
    if path[path.len - 1] == '/' { return false; }
    for seg in split(path[1..], '/') { if seg.len == 0 { return false; } }
    let first = split(path[1..], '/')[0];
    for r in gweb::reserved_prefixes() { if r == first { return false; } }
    return true;
}
