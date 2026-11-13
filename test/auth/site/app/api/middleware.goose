import std;
import net.http;
import gweb;
import gweb.auth.cors;

fn before(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) -> bool {
    return gweb::cors(req, ctx, res, gweb::CorsOptions { origins: "https://ok.example", .. });
}
