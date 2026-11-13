import net.http;
import gweb;

fn after(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    http::set_header(res, "X-Outer", "1");
}
