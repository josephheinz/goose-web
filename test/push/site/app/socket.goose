import std;
import gweb;
import gweb.http.push;

fn message(ctx: gweb::Ctx&, id: u64, topic: const u8[:], data: const u8[:], binary: bool) {
    var out: u8[>..] = [];
    format(out, "echo:", data);
    gweb::socket_send(ctx, id, out, binary);
}
