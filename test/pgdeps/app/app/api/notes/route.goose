// GET /api/notes lists the notes; POST /api/notes?text=... adds one. Each worker thread has its own connection.
// A copy of goose-postgres's examples/notes. gweb.packages declares pg, so `import pg;` needs no hand-patched root.
import std;
import net.http;
import gweb;
import gweb.http.cache;
import pg;

// The conninfo comes from PG_EXAMPLE_CONN, or, when unset, from the PG* environment variables.
fn connect() -> pg::Db {
    var info: u8[>..] = [];
    env("PG_EXAMPLE_CONN", info);
    let db = pg::local(info);
    if pg::ok(db) { pg::migrate(db, ["CREATE TABLE IF NOT EXISTS notes (id bigserial PRIMARY KEY, text text NOT NULL UNIQUE, at timestamptz NOT NULL DEFAULT now())"]); }
    return db;
}

fn fail(res: http::Response&, db: pg::Db, status: http::Status) {
    gweb::json(res, status);
    format(res.body, "{\"error\":\"", pg::code(db), "\"}");
}

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let db = connect();
    if !pg::ok(db) { gweb::json(res, http::Status.ServiceUnavailable); format(res.body, "{\"error\":\"database\",\"why\":\"", pg::error(db), "\"}"); return; }
    let s = pg::prepare(db, "SELECT id, text, at FROM notes ORDER BY id");
    gweb::json(res, http::Status.Ok);
    res.body.append("[");
    var first = true;
    while pg::step(s) {
        if !first { res.body.append(","); }
        first = false;
        // text is user input: a real app escapes it as JSON; here the POST below only accepts plain words
        format(res.body, "{\"id\":", pg::int(s, 0), ",\"text\":\"", pg::text(s, 1), "\",\"at\":", pg::timestamp(s, 2) / 1000000, "}");
    }
    res.body.append("]");
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let db = connect();
    if !pg::ok(db) { gweb::json(res, http::Status.ServiceUnavailable); format(res.body, "{\"error\":\"database\",\"why\":\"", pg::error(db), "\"}"); return; }
    var text: u8[>..] = [];
    gweb::query(req, "text", text);
    for c in text { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ') { text.clear(); break; } }
    if text.len == 0 { gweb::json(res, http::Status.BadRequest); res.body.append("{\"error\":\"text\"}"); return; }
    let ins = pg::prepare(db, "INSERT INTO notes (text) VALUES ($1) RETURNING id");
    pg::bind(ins, 1, text);
    let id, ok = pg::insert(ins);
    if ok { gweb::json(res, http::Status.Created); format(res.body, "{\"id\":", id, "}"); return; }
    // the app's own status mapping, as with SQLite: busy 503, constraint 409, else 500
    if pg::constraint(db) { fail(res, db, http::Status.Conflict); }
    else if pg::busy(db) { fail(res, db, http::Status.ServiceUnavailable); }
    else { fail(res, db, http::Status.InternalServerError); }
}
