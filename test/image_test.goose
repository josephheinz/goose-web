// gweb::image_size and image_size_file (1.1): the reader @image() uses, at run time. No sockets.
//   goose build test/image_test.goose && test/image_test
// The fixture files are test/templates/site/public/img (found from the gweb folder or from test/).
import gweb from "..";
import gweb.site.image;
import net from "../../goose-net";
import std;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}

fn size_is(d: const u8[:], w: i64, h: i64, what: const u8[:]) {
    let gw, gh, ok = gweb::image_size(d);
    checks += 1;
    if !ok || gw != w || gh != h { failures += 1; print("FAIL ", what, ": got ", gw, "x", gh, " known ", ok, ", want ", w, "x", h); }
}

fn unknown(d: const u8[:], what: const u8[:]) {
    let gw, gh, ok = gweb::image_size(d);
    check(!ok, what);
}

fn be32(out: u8[>..]&, v: i64) { out.push(((v >> 24) & 255) as u8); out.push(((v >> 16) & 255) as u8); out.push(((v >> 8) & 255) as u8); out.push((v & 255) as u8); }
fn le16(out: u8[>..]&, v: i64) { out.push((v & 255) as u8); out.push(((v >> 8) & 255) as u8); }

fn png(w: i64, h: i64) -> u8[>..] {
    var d: u8[>..] = [];
    d.append("\x89PNG\r\n\x1a\n");
    be32(d, 13);
    d.append("IHDR");
    be32(d, w);
    be32(d, h);
    d.append("\x08\x02\x00\x00\x00");
    return d;
}

fn fixture(name: const u8[:], out: u8[>..]&) -> bool {
    for dir in ["test/templates/site/public/img/", "templates/site/public/img/"] {
        var p: u8[>..] = [];
        format(p, dir, name);
        if file_exists(p) { return read_file(p, out); }
    }
    return false;
}

fn main() {
    // Built by hand, so the test needs no fixture.
    size_is(png(640, 480), 640, 480, "png");
    size_is(png(1, 1), 1, 1, "png 1x1");
    unknown(png(0, 5), "a png of width 0 has no size");
    var cut = png(4, 4);
    cut.pop_n(9);
    unknown(cut, "a truncated png");

    var gif: u8[>..] = [];
    gif.append("GIF89a");
    le16(gif, 300);
    le16(gif, 200);
    gif.append("\x00\x00\x00");
    size_is(gif, 300, 200, "gif");

    var jpg: u8[>..] = [];
    jpg.append("\xFF\xD8");
    jpg.append("\xFF\xE0\x00\x06JFIF");               // an APP0 segment first
    jpg.append("\xFF\xC0\x00\x0B\x08");               // SOF0: length 11, precision 8
    jpg.push(0); jpg.push(77);                          // height 77
    jpg.push(1); jpg.push(0x2C);                        // width 300
    jpg.append("\x01\x01\x11\x00");
    size_is(jpg, 300, 77, "jpeg, after another segment");
    unknown("\xFF\xD8\xFF\xD9", "a jpeg with no frame");

    var webpx: u8[>..] = [];
    webpx.append("RIFF\x00\x00\x00\x00WEBPVP8X\x0A\x00\x00\x00\x00\x00\x00\x00");
    webpx.push(0x1F); webpx.push(0x01); webpx.push(0);   // width - 1 = 287
    webpx.push(0x63); webpx.push(0); webpx.push(0);      // height - 1 = 99
    size_is(webpx, 288, 100, "webp (VP8X)");

    size_is("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"12px\"></svg>", 24, 12, "svg width and height");
    size_is("<?xml version=\"1.0\"?>\n<svg viewBox=\"0 0 30 20\" stroke-width=\"2\"><g/></svg>", 30, 20, "svg viewBox");
    unknown("<svg width=\"50%\" height=\"10\"></svg>", "svg in percent");
    unknown("<html><body>not an image</body></html>", "html");
    unknown("", "empty");
    unknown("GIF", "a short gif header");
    unknown("RIFF", "a short webp header");

    // The files @image() reads at build time (sizes from the build: 16x8, 5x4, 7x6, 9x3, 24x12, 30x20).
    var any = false;
    let names = ["logo.png", "tiny.gif", "tiny.jpg", "tiny.webp", "lossless.webp", "tiny.svg", "viewbox.svg"];
    let ws = [16, 5, 7, 9, 9, 24, 30];
    let hs = [8, 4, 6, 3, 3, 12, 20];
    for n, i in names {
        var d: u8[>..] = [];
        if !fixture(n, d) { continue; }
        any = true;
        size_is(d, ws[i], hs[i], n);
        var p: u8[>..] = [];
        format(p, "test/templates/site/public/img/", n);
        if !file_exists(p) { p.clear(); format(p, "templates/site/public/img/", n); }
        let fw, fh, fok = gweb::image_size_file(p);
        checks += 1;
        if !fok || fw != ws[i] || fh != hs[i] { failures += 1; print("FAIL image_size_file ", n); }
    }
    if !any { print("note: the fixture files were not found from this folder; only the built-in cases ran"); }
    let nw, nh, nok = gweb::image_size_file("no/such/file.png");
    check(!nok && nw == 0 && nh == 0, "a missing file has no size");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
