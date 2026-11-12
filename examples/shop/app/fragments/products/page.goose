import std;
import net.http;
import web;
import lib.catalog;
import lib.shop;

struct Props { cat: u8[..16] }

// ?cat=home, office, outdoor or kitchen filters the rows; anything else lists all.
fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Products with fragments");
    var cat: u8[>..] = [];
    var p = Props { cat: "" };
    if web::query(req, "cat", cat) {
        for c in ["home", "office", "outdoor", "kitchen"] { if cat == c { p.cat.append(c); } }
    }
    return p;
}
