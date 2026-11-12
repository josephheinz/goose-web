import std;
import os;
import net.http;
import web;

fn GET(req: const http::Request&, ctx: web::Ctx&, res: http::Response&) {
    sleep_ms(1500);
    http::text(res, http::Status.Ok, "slow done\n");
}
