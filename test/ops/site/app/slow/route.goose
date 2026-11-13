import std;
import os;
import net.http;
import gweb;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    sleep_ms(1500);
    http::text(res, http::Status.Ok, "slow done\n");
}
