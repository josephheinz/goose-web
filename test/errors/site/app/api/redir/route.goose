import std;
import net.http;
import gweb;

// A presigned-style URL of ?n= bytes (gweb 1.2: redirects up to 8 KiB; longer ones are refused, never cut).
// ?crlf=1 puts a line break in it. ?cookie=1 also sets a cookie, which shares the reply's headers.
fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    var n: u8[>..] = [];
    gweb::query(req, "n", n);
    let want, ok = parse_int(n);
    var url: u8[>..] = [];
    url.append("https://bucket.s3.eu-west-1.amazonaws.com/m/ab/abcdef/photo.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Expires=300&X-Amz-Security-Token=");
    var i = 0;
    while ok && url.len < want - 1 { url.push("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"[i % 62]); i += 1; }
    url.push('Z');
    var c: u8[>..] = [];
    if gweb::query(req, "crlf", c) { url.append("\r\nX-Evil: 1"); }
    if gweb::query(req, "cookie", c) { gweb::set_cookie(ctx, "seen", "1"); }
    gweb::redirect(ctx, url, 302);
}
