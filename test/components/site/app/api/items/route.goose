import std;
import net.http;
import gweb;
import RItems;

// What the component's http::get decodes: an array of RItems::Item.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var items: RItems::Item[>..<] = [];
    items.push(RItems::Item { id: 1, title: "one" });
    items.push(RItems::Item { id: 2, title: "t\"wo" });
    gweb::json(res, http::Status.Ok);
    RItems::gw_json(res.body, items);
}

// What http::post decodes: one RItems::Reply.
fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let reply = RItems::Reply { ok: true };
    gweb::json(res, http::Status.Ok);
    RItems::gw_json(res.body, reply);
}
