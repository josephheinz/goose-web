// Part of gweb. Import with `import gweb.site.image;`.
//
// Pixel sizes from the bytes of an image, at run time and at build time: `gweb::image_size(data)` is what `@image()`
// uses. cli/image.goose is a symlink to this file, so the CLI and the runtime read the same way. Only std is used here.

namespace gweb;

import std;

fn _img_byte(d: const u8[:], i: i64) -> i64 { if i < 0 || i >= d.len { return 0; } return d[i]; }
fn _img_be(d: const u8[:], at: i64, n: i64) -> i64 {
    var v = 0;
    for k in n { v = v * 256 + _img_byte(d, at + k); }
    return v;
}
fn _img_le(d: const u8[:], at: i64, n: i64) -> i64 {
    var v = 0;
    for k in n { v = v * 256 + _img_byte(d, at + n - 1 - k); }
    return v;
}
fn _img_space(c: u8) -> bool { c == ' ' || c == '\t' || c == '\n' || c == '\r' }

// A length of digits, an optional fraction and an optional px unit; rounded to whole pixels. Any other unit is not a pixel size.
fn _svg_dim(v: const u8[:]) -> i64, bool {
    let t = trim(v);
    var i = 0;
    var whole = 0;
    while i < t.len && t[i] >= '0' && t[i] <= '9' { whole = whole * 10 + (t[i] - '0'); i += 1; }
    var digits = i;
    if i < t.len && t[i] == '.' {
        i += 1;
        if i < t.len && t[i] >= '0' && t[i] <= '9' { if t[i] >= '5' { whole += 1; } digits += 1; }
        while i < t.len && t[i] >= '0' && t[i] <= '9' { i += 1; digits += 1; }
    }
    if digits == 0 { return 0, false; }
    if i < t.len && !(t[i..] == "px") { return 0, false; }
    return whole, whole > 0;
}

// The value of attribute name in an <svg ...> tag, or "". A name inside another (stroke-width) is skipped by requiring space before it.
fn _svg_attr(tag: const u8[:], name: const u8[:]) -> const u8[:] {
    var pos = 0;
    while pos < tag.len {
        let k = find(tag[pos..], name);
        if k < 0 { return ""; }
        let at = pos + k;
        pos = at + name.len;
        if at == 0 || !_img_space(tag[at - 1]) { continue; }
        var j = pos;
        while j < tag.len && _img_space(tag[j]) { j += 1; }
        if j >= tag.len || tag[j] != '=' { continue; }
        j += 1;
        while j < tag.len && _img_space(tag[j]) { j += 1; }
        if j >= tag.len || (tag[j] != '"' && tag[j] != '\'') { continue; }
        let q = tag[j];
        var e = j + 1;
        while e < tag.len && tag[e] != q { e += 1; }
        if e >= tag.len { return ""; }
        return tag[j + 1..e];
    }
    return "";
}

fn _svg_size(d: const u8[:]) -> i64, i64, bool {
    let at = find(d, "<svg");
    if at < 0 { return 0, 0, false; }
    var end = at;
    var quote: u8 = 0;
    while end < d.len {
        let c = d[end];
        if quote != 0 { if c == quote { quote = 0; } }
        else if c == '"' || c == '\'' { quote = c; }
        else if c == '>' { break; }
        end += 1;
    }
    let tag = d[at..end];
    let w, wok = _svg_dim(_svg_attr(tag, "width"));
    let h, hok = _svg_dim(_svg_attr(tag, "height"));
    if wok && hok { return w, h, true; }
    // viewBox is "min-x min-y width height", separated by spaces or commas.
    let vb = _svg_attr(tag, "viewBox");
    var n = 0;
    var vw = 0;
    var vh = 0;
    var vok = true;
    var i = 0;
    while i < vb.len {
        while i < vb.len && (_img_space(vb[i]) || vb[i] == ',') { i += 1; }
        var j = i;
        while j < vb.len && !_img_space(vb[j]) && vb[j] != ',' { j += 1; }
        if j > i {
            if n == 2 { let x, ok = _svg_dim(vb[i..j]); vw = x; vok = vok && ok; }
            if n == 3 { let x, ok = _svg_dim(vb[i..j]); vh = x; vok = vok && ok; }
            n += 1;
        }
        i = j;
    }
    if n == 4 && vok { return vw, vh, true; }
    return 0, 0, false;
}

// Reads the pixel size from the file's header; false for an unknown format or a truncated file.
fn image_size(d: const u8[:]) -> i64, i64, bool {
    if d.len >= 24 && _img_be(d, 0, 4) == 2303741511 && _img_be(d, 4, 4) == 218765834 && d[12..16] == "IHDR" {
        let w = _img_be(d, 16, 4);
        let h = _img_be(d, 20, 4);
        return w, h, w > 0 && h > 0;
    }
    if d.len >= 10 && (starts_with(d, "GIF87a") || starts_with(d, "GIF89a")) {
        let w = _img_le(d, 6, 2);
        let h = _img_le(d, 8, 2);
        return w, h, w > 0 && h > 0;
    }
    if d.len >= 4 && _img_byte(d, 0) == 255 && _img_byte(d, 1) == 216 {
        var i = 2;
        while i + 4 <= d.len {
            if d[i] != 255 { i += 1; continue; }
            let m = _img_byte(d, i + 1);
            if m == 255 { i += 1; continue; }
            // Markers with no length: TEM, RSTn, SOI, and a stuffed zero.
            if m == 0 || m == 1 || m == 216 || (m >= 208 && m <= 215) { i += 2; continue; }
            if m == 217 { break; }
            let seg = _img_be(d, i + 2, 2);
            if seg < 2 { break; }
            if m >= 192 && m <= 207 && m != 196 && m != 200 && m != 204 {
                if i + 9 > d.len { break; }
                let h = _img_be(d, i + 5, 2);
                let w = _img_be(d, i + 7, 2);
                return w, h, w > 0 && h > 0;
            }
            i += 2 + seg;
        }
        return 0, 0, false;
    }
    if d.len >= 30 && starts_with(d, "RIFF") && d[8..12] == "WEBP" {
        let kind = d[12..16];
        if kind == "VP8 " && _img_byte(d, 23) == 157 && _img_byte(d, 24) == 1 && _img_byte(d, 25) == 42 {
            let w = _img_le(d, 26, 2) & 16383;
            let h = _img_le(d, 28, 2) & 16383;
            return w, h, w > 0 && h > 0;
        }
        if kind == "VP8L" && _img_byte(d, 20) == 47 {
            let b = _img_le(d, 21, 4);
            return (b & 16383) + 1, ((b >> 14) & 16383) + 1, true;
        }
        if kind == "VP8X" {
            return _img_le(d, 24, 3) + 1, _img_le(d, 27, 3) + 1, true;
        }
        return 0, 0, false;
    }
    return _svg_size(d);
}

// The same for a file; false when it cannot be read or is over 64 MiB, or is not an image of a known kind.
fn image_size_file(path: const u8[:]) -> i64, i64, bool {
    var data: u8[>..] = [];
    if !read_file(path, data) || data.len > 67108864 { return 0, 0, false; }
    return image_size(data);
}
