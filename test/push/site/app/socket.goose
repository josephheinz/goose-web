import std;
import web;
import web.push;

fn message(ctx: web::Ctx&, id: u64, topic: const u8[:], data: const u8[:], binary: bool) {
    var out: u8[>..] = [];
    format(out, "echo:", data);
    web::send(ctx, id, out, binary);
}
