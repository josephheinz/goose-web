// Part of gweb. Import with `import gweb.site.markdown;`.
//
// gweb::markdown(out, src) renders a small, safe Markdown subset as HTML (DESIGN-ADDENDUM-19).
// Blocks: ATX headings, paragraphs, block quotes, bullet and ordered lists (nested by indent, always tight),
// fenced code, `---`. Inline: *em*, **strong**, `code`, links, images, <autolinks>, hard breaks, backslash escapes.
// Raw HTML is escaped. A link or image URL must be relative, or start with http:, https: or mailto:;
// any other construct stays plain text. Absolute links get rel="noopener".
// Limits: input is cut at 64 KiB (a third argument, max_input, changes that), containers nest 8 deep (deeper markers are text), URLs are at most 2000 bytes.

namespace gweb;

import std;
import gweb;
import site.template;

let MD_MAX_INPUT = 65536;   // the default of max_input
let MD_MAX_DEPTH = 8;
let MD_MAX_URL = 2000;

struct MdBox { quote: bool = false, ordered: bool = false, ch: u8 = 0, indent: i64 = 0, bare: bool = false, nl: bool = false }
struct MdMarker { kind: i64, ch: u8, width: i64, num: i64 }   // kind: 0 none, 1 bullet, 2 ordered

// ---------------------------------------------------------------- small helpers

fn _md_space(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 12 || c == 11; }
fn _md_punct(c: u8) -> bool {
    return (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126);
}
fn _md_alnum(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 128; }

// Columns and bytes of the leading spaces and tabs; a tab is 4 columns.
fn _md_lead(s: const u8[:]) -> i64, i64 {
    var cols = 0;
    var n = 0;
    while n < s.len && (s[n] == ' ' || s[n] == '\t') { cols += if s[n] == '\t' { 4 } else { 1 }; n += 1; }
    return cols, n;
}

// The bytes that remove up to cols columns of leading white space.
fn _md_skip_cols(s: const u8[:], cols: i64) -> i64 {
    var c = 0;
    var n = 0;
    while n < s.len && c < cols && (s[n] == ' ' || s[n] == '\t') { c += if s[n] == '\t' { 4 } else { 1 }; n += 1; }
    return n;
}

fn _md_blank(s: const u8[:]) -> bool {
    for c in s { if !_md_space(c) { return false; } }
    return true;
}

// The text cut at max bytes on a UTF-8 boundary.
fn _md_cut(s: const u8[:], max: i64) -> const u8[:] {
    if s.len <= max { return s; }
    var n = max;
    while n > 0 && (s[n] & 0xC0) == 0x80 { n -= 1; }
    return s[..n];
}

fn _md_marker(r: const u8[:]) -> MdMarker {
    let none = MdMarker { kind: 0, ch: 0, width: 0, num: 0 };
    if r.len == 0 { return none; }
    let c = r[0];
    if c == '-' || c == '*' || c == '+' {
        if r.len == 1 || r[1] == ' ' || r[1] == '\t' { return MdMarker { kind: 1, ch: c, width: 1, num: 0 }; }
        return none;
    }
    var n = 0;
    var v = 0;
    while n < r.len && n < 10 && r[n] >= '0' && r[n] <= '9' { v = v * 10 + (r[n] - '0'); n += 1; }
    if n == 0 || n > 9 || n >= r.len { return none; }
    if r[n] != '.' && r[n] != ')' { return none; }
    if n + 1 < r.len && r[n + 1] != ' ' && r[n + 1] != '\t' { return none; }
    return MdMarker { kind: 2, ch: r[n], width: n + 1, num: v };
}

// ---, *** or ___ (three or more of one, white space allowed between).
fn _md_hr(r: const u8[:]) -> bool {
    if r.len < 3 { return false; }
    let c = r[0];
    if c != '-' && c != '*' && c != '_' { return false; }
    var n = 0;
    for x in r {
        if x == c { n += 1; } else if x != ' ' && x != '\t' { return false; }
    }
    return n >= 3;
}

// The level of an ATX heading line start (# then a space or the end), else 0.
fn _md_atx(r: const u8[:]) -> i64 {
    var n = 0;
    while n < r.len && r[n] == '#' { n += 1; }
    if n == 0 || n > 6 { return 0; }
    if n < r.len && r[n] != ' ' && r[n] != '\t' { return 0; }
    return n;
}

// The length of an opening fence (``` or ~~~, three or more) and its character, else 0. A backtick fence's info has no backtick.
fn _md_fence(r: const u8[:]) -> i64, u8 {
    if r.len < 3 || (r[0] != '`' && r[0] != '~') { return 0, 0; }
    var n = 0;
    while n < r.len && r[n] == r[0] { n += 1; }
    if n < 3 { return 0, 0; }
    if r[0] == '`' { for x in r[n..] { if x == '`' { return 0, 0; } } }
    return n, r[0];
}

// 0: not allowed, 1: relative, 2: absolute (http:, https:, mailto: or //).
fn _md_url_kind(u: const u8[:]) -> i64 {
    if u.len == 0 || u.len > MD_MAX_URL { return 0; }
    for c in u { if c <= 32 || c == 127 || c == '\\' { return 0; } }
    if u[0] == '#' { return 1; }
    if u[0] == '/' { return if u.len > 1 && u[1] == '/' { 2 } else { 1 }; }
    var k = 0;
    while k < u.len && u[k] != ':' && u[k] != '/' && u[k] != '?' && u[k] != '#' { k += 1; }
    if k == u.len || u[k] != ':' { return 1; }
    if k == 0 || k > 6 { return 0; }
    var s: u8[..8] = "";
    s.append(u[..k]);
    to_lower(s);
    if s == "http" || s == "https" || s == "mailto" { return 2; }
    return 0;
}

// ---------------------------------------------------------------- inline

let T_TEXT = 0;
let T_LIT = 1;      // a = the byte
let T_CODE = 2;
let T_BR = 3;
let T_SOFT = 4;
let T_LINK = 5;     // a,b url; c,d title; e: absolute
let T_ENDLINK = 6;
let T_IMG = 7;      // a,b alt; c,d url ... see below
let T_AUTO = 8;     // a,b url
let T_DELIM = 9;    // a,b the run; ch; can_open, can_close
let T_BARRIER = 10; // a link's open: emphasis does not match across it

// Tok.a..b: the main slice; c..d: a second slice (title); u..v: the url (links and images).
struct Tok { kind: i64, a: i64, b: i64, c: i64, d: i64, u: i64, v: i64, abs: bool,
             ch: u8, can_open: bool, can_close: bool, used_open: i64, used_close: i64,
             opens: u8[..8], closes: u8[..8], left: i64 }   // opens/closes: 'e' or 's' in match order

fn _tok(kind: i64, a: i64, b: i64) -> Tok {
    Tok { kind: kind, a: a, b: b, c: 0, d: 0, u: 0, v: 0, abs: false, ch: 0, can_open: false, can_close: false,
          used_open: 0, used_close: 0, opens: "", closes: "", left: 0 }
}

// Parses (dest "title") after a closing ]; at is the index of '('. Returns the end (after ')') or -1.
fn _md_dest(t: const u8[:], at: i64, us: i64&, ue: i64&, ts: i64&, te: i64&) -> i64 {
    var i = at + 1;
    let limit = min(t.len, at + 1 + 2 * MD_MAX_URL + 8);
    while i < limit && (t[i] == ' ' || t[i] == '\n') { i += 1; }
    if i >= limit { return -1; }
    if t[i] == '<' {
        let s = i + 1;
        var e = s;
        while e < limit && t[e] != '>' && t[e] != '\n' && t[e] != '<' { e += 1; }
        if e >= limit || t[e] != '>' { return -1; }
        us = s; ue = e;
        i = e + 1;
    } else {
        let s = i;
        var depth = 0;
        while i < limit && t[i] > 32 && t[i] != 127 {
            if t[i] == '(' { depth += 1; }
            else if t[i] == ')' { if depth == 0 { break; } depth -= 1; }
            i += 1;
        }
        if i >= limit || depth != 0 { return -1; }
        us = s; ue = i;
    }
    ts = 0; te = 0;
    var j = i;
    while j < limit && (t[j] == ' ' || t[j] == '\n') { j += 1; }
    if j >= limit { return -1; }
    if j > i && (t[j] == '"' || t[j] == '\'') {
        let q = t[j];
        let s = j + 1;
        var e = s;
        while e < limit && t[e] != q { if t[e] == '\\' { e += 1; } e += 1; }
        if e >= limit { return -1; }
        ts = s; te = e;
        j = e + 1;
        while j < limit && (t[j] == ' ' || t[j] == '\n') { j += 1; }
        if j >= limit { return -1; }
    }
    if t[j] != ')' { return -1; }
    return j + 1;
}

// Renders inline Markdown. Not recursive: one scan makes tokens, a second pairs the emphasis, a third writes.
fn _md_inline(out: u8[>..]&, t: const u8[:]) {
    var toks: Tok[>..] = [];
    // Matching ] of every [ (-1 when none), found once so a run of [ costs linear time.
    var close_of: i64[>..] = [];
    {
        var stack: i64[>..] = [];
        var k = 0;
        while k < t.len {
            close_of.push(-1);
            k += 1;
        }
        k = 0;
        while k < t.len {
            let c = t[k];
            if c == '\\' { k += 2; continue; }
            if c == '[' { stack.push(k); }
            else if c == ']' && stack.len > 0 { let o = stack[stack.len - 1]; stack.pop(); close_of[o] = k; }
            k += 1;
        }
    }
    var no_close: i64[33] = [-1; 33];   // a backtick run of this length found no partner after this position
    var ts = 0;
    var i = 0;
    var link_end = -1;      // the ] that ends the open link's text
    var link_resume = 0;
    while i < t.len {
        let c = t[i];
        if i == link_end {
            if i > ts { toks.push(_tok(T_TEXT, ts, i)); }
            toks.push(_tok(T_ENDLINK, 0, 0));
            link_end = -1;
            i = link_resume;
            ts = i;
            continue;
        }
        if c == '\\' && i + 1 < t.len {
            let n = t[i + 1];
            if n == '\n' {
                var e = i;
                if e > ts { toks.push(_tok(T_TEXT, ts, e)); }
                toks.push(_tok(T_BR, 0, 0));
                i += 2; ts = i;
                continue;
            }
            if _md_punct(n) {
                if i > ts { toks.push(_tok(T_TEXT, ts, i)); }
                var l = _tok(T_LIT, n, 0);
                toks.push(l);
                i += 2; ts = i;
                continue;
            }
            i += 1;
            continue;
        }
        if c == '\n' {
            var e = i;
            while e > ts && t[e - 1] == ' ' { e -= 1; }
            let hard = i - e >= 2;
            if e > ts { toks.push(_tok(T_TEXT, ts, e)); }
            toks.push(_tok(if hard { T_BR } else { T_SOFT }, 0, 0));
            i += 1;
            while i < t.len && t[i] == ' ' { i += 1; }
            ts = i;
            continue;
        }
        if c == '`' {
            var n = 0;
            while i + n < t.len && t[i + n] == '`' { n += 1; }
            var found = -1;
            if n <= 32 && no_close[n] < 0 {
                var p = i + n;
                while p < t.len && found < 0 {
                    if t[p] == '`' {
                        var m = 0;
                        while p + m < t.len && t[p + m] == '`' { m += 1; }
                        if m == n { found = p; } else { p += m; }
                    } else { p += 1; }
                }
                if found < 0 { no_close[n] = i; }
            }
            if found >= 0 {
                if i > ts { toks.push(_tok(T_TEXT, ts, i)); }
                var a = i + n;
                var b = found;
                if b - a >= 2 && t[a] == ' ' && t[b - 1] == ' ' && !_md_blank(t[a..b]) { a += 1; b -= 1; }
                toks.push(_tok(T_CODE, a, b));
                i = found + n;
                ts = i;
            } else { i += n; }
            continue;
        }
        if c == '[' || (c == '!' && i + 1 < t.len && t[i + 1] == '[') {
            let img = c == '!';
            let open = if img { i + 1 } else { i };
            let cl = close_of[open];
            var ok = false;
            if cl > 0 && cl + 1 < t.len && t[cl + 1] == '(' && (img || link_end < 0) {
                var us = 0; var ue = 0; var ts2 = 0; var te2 = 0;
                let end = _md_dest(t, cl + 1, us, ue, ts2, te2);
                if end > 0 {
                    let kind = _md_url_kind(t[us..ue]);
                    if kind > 0 {
                        ok = true;
                        if i > ts { toks.push(_tok(T_TEXT, ts, i)); }
                        if img {
                            var k = _tok(T_IMG, open + 1, cl);
                            k.u = us; k.v = ue; k.c = ts2; k.d = te2; k.abs = kind == 2;
                            toks.push(k);
                            i = end; ts = i;
                        } else {
                            var k = _tok(T_LINK, 0, 0);
                            k.u = us; k.v = ue; k.c = ts2; k.d = te2; k.abs = kind == 2;
                            toks.push(k);
                            toks.push(_tok(T_BARRIER, 0, 0));
                            link_end = cl; link_resume = end;
                            i = open + 1; ts = i;
                        }
                    }
                }
            }
            if !ok { i += 1; }
            continue;
        }
        if c == '<' {
            // <http://x>, <https://x> or <mailto:x>
            var e = i + 1;
            while e < t.len && e < i + MD_MAX_URL && t[e] != '>' && t[e] > 32 && t[e] != '<' { e += 1; }
            if e < t.len && t[e] == '>' && _md_url_kind(t[i + 1..e]) == 2 && find(t[i + 1..e], ":") > 0 {
                if i > ts { toks.push(_tok(T_TEXT, ts, i)); }
                toks.push(_tok(T_AUTO, i + 1, e));
                i = e + 1; ts = i;
                continue;
            }
            i += 1;
            continue;
        }
        if c == '*' || c == '_' {
            var n = 0;
            while i + n < t.len && t[i + n] == c { n += 1; }
            let before = if i == 0 { ' ' } else { t[i - 1] };
            let after = if i + n >= t.len { ' ' } else { t[i + n] };
            let left = !_md_space(after) && (!_md_punct(after) || _md_space(before) || _md_punct(before));
            let right = !_md_space(before) && (!_md_punct(before) || _md_space(after) || _md_punct(after));
            var k = _tok(T_DELIM, i, i + n);
            k.ch = c;
            if c == '*' { k.can_open = left; k.can_close = right; }
            else { k.can_open = left && (!right || _md_punct(before)); k.can_close = right && (!left || _md_punct(after)); }
            if i > ts { toks.push(_tok(T_TEXT, ts, i)); }
            k.left = n;
            toks.push(k);
            i += n; ts = i;
            continue;
        }
        i += 1;
    }
    if t.len > ts { toks.push(_tok(T_TEXT, ts, t.len)); }
    if link_end >= 0 { /* the link text never closed: cannot happen, close_of guarantees it */ }

    // Pair the emphasis. stack holds token indexes of openers; a barrier is a T_BARRIER token.
    var stack: i64[>..] = [];
    var k = 0;
    while k < toks.len {
        let kind = toks[k].kind;
        if kind == T_BARRIER { stack.push(k); k += 1; continue; }
        if kind == T_ENDLINK {
            while stack.len > 0 {
                let top = stack[stack.len - 1];
                stack.pop();
                if toks[top].kind == T_BARRIER { break; }
            }
            k += 1;
            continue;
        }
        if kind != T_DELIM { k += 1; continue; }
        if toks[k].can_close {
            var s = stack.len;
            var tries = 0;
            while toks[k].left > 0 && s > 0 && tries < 64 {
                s -= 1;
                tries += 1;
                let o = stack[s];
                if toks[o].kind == T_BARRIER { break; }
                if toks[o].ch != toks[k].ch || toks[o].left == 0 { continue; }
                let use = if toks[o].left >= 2 && toks[k].left >= 2 { 2 } else { 1 };
                toks[o].left -= use;
                toks[k].left -= use;
                let tag: u8 = if use == 2 { 's' } else { 'e' };
                toks[o].opens.push(tag);
                toks[k].closes.push(tag);
                // Openers above o can no longer match: they were inside this pair.
                stack.resize(s + 1, 0);
                if toks[o].left == 0 { stack.pop(); s -= 1; }
                tries = 0;
                s = stack.len;
            }
        }
        if toks[k].can_open && toks[k].left > 0 { stack.push(k); }
        k += 1;
    }

    // Write.
    k = 0;
    while k < toks.len {
        let x = toks[k];
        k += 1;
        if x.kind == T_TEXT { escape(out, t[x.a..x.b]); }
        else if x.kind == T_LIT { var one: u8[..1] = ""; one.push(x.a as u8); escape(out, one); }
        else if x.kind == T_CODE { out.append("<code>"); escape(out, t[x.a..x.b]); out.append("</code>"); }
        else if x.kind == T_BR { out.append("<br>\n"); }
        else if x.kind == T_SOFT { out.push('\n'); }
        else if x.kind == T_LINK {
            out.append("<a href=\""); escape(out, t[x.u..x.v]); out.push('"');
            if x.d > x.c { out.append(" title=\""); escape(out, t[x.c..x.d]); out.push('"'); }
            if x.abs { out.append(" rel=\"noopener\""); }
            out.push('>');
        }
        else if x.kind == T_ENDLINK { out.append("</a>"); }
        else if x.kind == T_IMG {
            out.append("<img src=\""); escape(out, t[x.u..x.v]); out.append("\" alt=\""); escape(out, t[x.a..x.b]); out.push('"');
            if x.d > x.c { out.append(" title=\""); escape(out, t[x.c..x.d]); out.push('"'); }
            out.push('>');
        }
        else if x.kind == T_AUTO {
            out.append("<a href=\""); escape(out, t[x.a..x.b]); out.append("\" rel=\"noopener\">"); escape(out, t[x.a..x.b]); out.append("</a>");
        }
        else if x.kind == T_DELIM {
            for tag in x.closes { out.append(if tag == 's' { "</strong>" } else { "</em>" }); }
            for _ in x.left { out.push(x.ch); }
            var j = x.opens.len;
            while j > 0 { j -= 1; out.append(if x.opens[j] == 's' { "<strong>" } else { "<em>" }); }
        }
    }
}

// ---------------------------------------------------------------- blocks

fn markdown(out: u8[>..]&, src0: const u8[:], max_input: i64 = MD_MAX_INPUT) {
    let src = _md_cut(src0, max(max_input, 0));
    var para: u8[>..] = [];
    var para_open = false;
    var boxes: MdBox[8] = [MdBox { .. }; 8];
    var depth = 0;
    var fence_open = false;
    var fence_ch: u8 = 0;
    var fence_len = 0;
    var fence_indent = 0;

    fn begin_block() {
        if depth > 0 {
            if !boxes[depth - 1].quote && boxes[depth - 1].nl { out.push('\n'); boxes[depth - 1].nl = false; }
            boxes[depth - 1].bare = false;
        }
    }
    fn close_para() {
        if !para_open { return; }
        para_open = false;
        var e = para.len;
        while e > 0 && _md_space(para[e - 1]) { e -= 1; }
        if depth > 0 && !boxes[depth - 1].quote && boxes[depth - 1].bare {
            _md_inline(out, para[..e]);
            boxes[depth - 1].bare = false;
            boxes[depth - 1].nl = true;
        } else {
            begin_block();
            out.append("<p>");
            _md_inline(out, para[..e]);
            out.append("</p>\n");
        }
        para.clear();
    }
    fn close_fence() {
        if fence_open { out.append("</code></pre>\n"); fence_open = false; }
    }
    fn close_top() {
        close_para();
        close_fence();
        depth -= 1;
        let b = boxes[depth];
        if b.quote { out.append("</blockquote>\n"); }
        else { out.append(if b.ordered { "</li>\n</ol>\n" } else { "</li>\n</ul>\n" }); }
    }
    fn close_to(n: i64) { while depth > n { close_top(); } }
    // Opens a list box (a new list) or, with sibling, a new item of the open top box.
    fn open_item(m: MdMarker, base: i64, rest: const u8[:], sibling: bool) -> i64 {
        // rest starts at the marker; returns the bytes the marker and its spaces take.
        let after = rest[m.width..];
        let sp, sn = _md_lead(after);
        var gap = sp;
        var used = m.width + sn;
        if after.len == 0 || _md_blank(after) { gap = 1; used = rest.len; }
        else if sp >= 5 { gap = 1; used = m.width + 1; }
        else if sp == 0 { gap = 1; }
        if sibling {
            out.append("</li>\n<li>");
            boxes[depth - 1].indent = base + m.width + gap;
            boxes[depth - 1].bare = true;
            boxes[depth - 1].nl = false;
        } else {
            begin_block();
            if m.kind == 2 && m.num != 1 { out.append("<ol start=\""); format(out, m.num); out.append("\">\n<li>"); }
            else { out.append(if m.kind == 2 { "<ol>\n<li>" } else { "<ul>\n<li>" }); }
            boxes[depth] = MdBox { quote: false, ordered: m.kind == 2, ch: m.ch, indent: base + m.width + gap, bare: true, nl: false };
            depth += 1;
        }
        return used;
    }
    // A line start the paragraph must not swallow.
    fn starts_block(r0: const u8[:]) -> bool {
        let cols, n = _md_lead(r0);
        if cols >= 4 { return false; }
        let r = r0[n..];
        if r.len == 0 { return false; }
        if r[0] == '>' || _md_hr(r) || _md_atx(r) > 0 { return true; }
        let f, fc = _md_fence(r);
        if f > 0 { return true; }
        let m = _md_marker(r);
        if m.kind == 1 && !_md_blank(r[1..]) { return true; }
        if m.kind == 2 && m.num == 1 && !_md_blank(r[m.width..]) { return true; }
        return false;
    }

    var pos = 0;
    while pos < src.len {
        var eol = pos;
        while eol < src.len && src[eol] != '\n' { eol += 1; }
        var l = src[pos..eol];
        pos = eol + 1;
        if l.len > 0 && l[l.len - 1] == '\r' { l = l[..l.len - 1]; }

        // 1. Which open containers continue on this line.
        var i = 0;
        var matched = 0;
        while matched < depth {
            let b = boxes[matched];
            if b.quote {
                let cols, n = _md_lead(l[i..]);
                if cols < 4 && i + n < l.len && l[i + n] == '>' {
                    i += n + 1;
                    if i < l.len && l[i] == ' ' { i += 1; }
                    matched += 1;
                } else { break; }
            } else {
                let rest = l[i..];
                if _md_blank(rest) { matched += 1; }
                else {
                    let cols, n = _md_lead(rest);
                    if cols >= b.indent { i += _md_skip_cols(rest, b.indent); matched += 1; } else { break; }
                }
            }
        }
        var rest = l[i..];

        // 2. Fenced code takes the line as it is while its containers continue.
        if fence_open {
            if matched < depth { close_fence(); close_to(matched); }
            else {
                let cols, n = _md_lead(rest);
                var closes = false;
                if cols < 4 {
                    let r = rest[n..];
                    var k = 0;
                    while k < r.len && r[k] == fence_ch { k += 1; }
                    if k >= fence_len && _md_blank(r[k..]) { closes = true; }
                }
                if closes { close_fence(); }
                else {
                    let skip = _md_skip_cols(rest, fence_indent);
                    escape(out, rest[skip..]);
                    out.push('\n');
                }
                continue;
            }
        }

        // 3. Blank lines end the paragraph; containers that did not match end too.
        if _md_blank(rest) {
            close_para();
            close_to(matched);
            continue;
        }
        let cols0, n0 = _md_lead(rest);
        if matched < depth {
            let sib = if cols0 < 4 && !boxes[matched].quote { _md_marker(rest[n0..]) } else { MdMarker { kind: 0, ch: 0, width: 0, num: 0 } };
            let is_sib = sib.kind == (if boxes[matched].ordered { 2 } else { 1 }) && sib.ch == boxes[matched].ch && !_md_hr(rest[n0..]);
            if para_open && !is_sib && !starts_block(rest) { para.push('\n'); para.append(rest[n0..]); continue; }
            // A sibling item continues its list.
            if is_sib {
                let m = sib;
                if true {
                    close_to(matched + 1);
                    close_para();
                    let used = open_item(m, cols0, rest[n0..], true);
                    rest = rest[n0 + used..];
                    matched += 1;
                    // fall through to the leaf with the item's first line
                    var nested = true;
                    while nested {
                        nested = false;
                        let c2, n2 = _md_lead(rest);
                        if c2 < 4 && depth < MD_MAX_DEPTH {
                            let r2 = rest[n2..];
                            if r2.len > 0 && r2[0] == '>' {
                                close_para(); begin_block();
                                out.append("<blockquote>\n");
                                boxes[depth] = MdBox { quote: true };
                                depth += 1; matched = depth;
                                rest = r2[1..];
                                if rest.len > 0 && rest[0] == ' ' { rest = rest[1..]; }
                                nested = true;
                            } else if !_md_hr(r2) {
                                let m2 = _md_marker(r2);
                                if m2.kind > 0 {
                                    let u2 = open_item(m2, c2, r2, false);
                                    rest = r2[u2..];
                                    matched = depth;
                                    nested = true;
                                }
                            }
                        }
                    }
                    // leaf below handles rest
                    matched = depth;
                    if _md_blank(rest) { continue; }
                }
            }
            if matched < depth { close_para(); close_to(matched); }
        }

        // 4. New containers.
        var again = true;
        while again {
            again = false;
            let cols, n = _md_lead(rest);
            if cols >= 4 || depth >= MD_MAX_DEPTH { break; }
            let r = rest[n..];
            if r.len == 0 { break; }
            if r[0] == '>' {
                close_para(); begin_block();
                out.append("<blockquote>\n");
                boxes[depth] = MdBox { quote: true };
                depth += 1;
                rest = r[1..];
                if rest.len > 0 && rest[0] == ' ' { rest = rest[1..]; }
                again = true;
                continue;
            }
            if _md_hr(r) { break; }
            let m = _md_marker(r);
            if m.kind == 0 { break; }
            if para_open {
                // Only a non-empty bullet or an ordered item numbered 1 interrupts a paragraph.
                if _md_blank(r[m.width..]) || (m.kind == 2 && m.num != 1) { break; }
            }
            close_para();
            let used = open_item(m, cols, r, false);
            rest = r[used..];
            again = !_md_blank(rest);
        }

        // 5. The leaf.
        if _md_blank(rest) { continue; }
        let cols, n = _md_lead(rest);
        let r = rest[n..];
        if cols < 4 {
            if _md_hr(r) { close_para(); begin_block(); out.append("<hr>\n"); continue; }
            let lv = _md_atx(r);
            if lv > 0 {
                close_para(); begin_block();
                var h = r[lv..];
                h = trim(h);
                var e = h.len;
                while e > 0 && h[e - 1] == '#' { e -= 1; }
                if e == 0 || h[e - 1] == ' ' || h[e - 1] == '\t' { h = trim(h[..e]); }
                format(out, "<h", lv, ">");
                _md_inline(out, h);
                format(out, "</h", lv, ">\n");
                continue;
            }
            let f, fc = _md_fence(r);
            if f > 0 {
                close_para(); begin_block();
                fence_open = true; fence_ch = fc; fence_len = f; fence_indent = cols;
                let info = trim(r[f..]);
                var w = info;
                let sp = find(info, " ");
                if sp >= 0 { w = info[..sp]; }
                var good = w.len > 0 && w.len <= 32;
                for c in w { if !(_md_alnum(c) && c < 128) && c != '_' && c != '+' && c != '.' && c != '#' && c != '-' { good = false; } }
                if good { out.append("<pre><code class=\"language-"); out.append(w); out.append("\">"); }
                else { out.append("<pre><code>"); }
                continue;
            }
        }
        if para_open { para.push('\n'); }
        para_open = true;
        para.append(r);
    }
    close_para();
    close_fence();
    close_to(0);
}

// ---------------------------------------------------------------- plain text

// The text of the Markdown with no markup, white space collapsed, at most max bytes: a cut text ends at a word with "…".
fn markdown_text(out: u8[>..]&, src: const u8[:], max: i64, max_input: i64 = MD_MAX_INPUT) {
    var html: u8[>..] = [];
    markdown(html, src, max_input);
    var text: u8[>..] = [];
    var i = 0;
    var space = true;
    while i < html.len {
        let c = html[i];
        if c == '<' {
            var e = i;
            while e < html.len && html[e] != '>' { e += 1; }
            let tag = html[i + 1..min(e, html.len)];
            let name_start = if tag.len > 0 && tag[0] == '/' { 1 } else { 0 };
            var inline_tag = false;
            for n in ["a", "em", "strong", "code", "img"] {
                if starts_with(tag[name_start..], n) {
                    let after = name_start + n.len;
                    if after >= tag.len || tag[after] == ' ' { inline_tag = true; }
                }
            }
            if !inline_tag && !space { text.push(' '); space = true; }
            i = e + 1;
            continue;
        }
        if c == '&' {
            var ent: u8 = '&';
            var len = 1;
            if starts_with(html[i..], "&amp;") { len = 5; }
            else if starts_with(html[i..], "&lt;") { ent = '<'; len = 4; }
            else if starts_with(html[i..], "&gt;") { ent = '>'; len = 4; }
            else if starts_with(html[i..], "&quot;") { ent = '"'; len = 6; }
            else if starts_with(html[i..], "&#39;") { ent = '\''; len = 5; }
            text.push(ent); space = false; i += len;
            continue;
        }
        if _md_space(c) { if !space { text.push(' '); space = true; } i += 1; continue; }
        text.push(c); space = false; i += 1;
    }
    while text.len > 0 && text[text.len - 1] == ' ' { text.pop(); }
    if text.len <= max { out.append(text); return; }
    let ell = "\xE2\x80\xA6";
    var n = max - ell.len;
    if n < 0 { n = 0; }
    while n > 0 && (text[n] & 0xC0) == 0x80 { n -= 1; }
    var w = n;
    while w > 0 && text[w] != ' ' { w -= 1; }
    if w > n / 2 { n = w; }
    while n > 0 && text[n - 1] == ' ' { n -= 1; }
    out.append(text[..n]);
    if max >= ell.len { out.append(ell); }
}
