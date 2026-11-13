// i18n: the locales/ catalog compiler. gweb passes the files to start and add_file, then calls compile once;
// it returns the source of .gweb/t.goose. Errors are `locales/<file>:LINE: error: MSG` lines.

namespace i18n;

import std;

struct Loc { tag: u8[..40], file: u8[..80], ts: i64, te: i64 }   // ts, te: the file's text in srcs
struct Key { name: u8[..64], plural: bool, line: i64 }
struct Arg { key: i64, name: u8[..64], int: bool }
struct Ent { loc: i64, key: i64, cat: i64, ts: i64, te: i64, line: i64 }   // loc: index into TAGS; cat -1 for a plain key

let CATS = ["zero", "one", "two", "few", "many", "other"];
let OTHER = 5;

let KEYWORDS = ["import", "namespace", "struct", "enum", "type", "fn", "thread_fn", "export", "simd", "recursive",
                "let", "var", "extern", "const", "pad", "reusable", "if", "else", "while", "for", "in", "loop",
                "block", "guard", "defer", "match", "return", "break", "continue", "as", "true", "false", "null",
                "self", "bool", "varint", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"];
let KEY_TAKEN = ["tag", "find", "TAGS", "std", "net", "http", "gweb", "t", "format"];
let ARG_TAKEN = ["ctx", "loc", "std", "net", "http", "gweb", "t", "format"];

var locs: Loc[>..<];
var srcs: u8[>..];
var dsrc: u8[>..];
var has_default = false;
var def_tag: u8[..40];
var def_file: u8[..80];
var keys: Key[>..<];
var targs: Arg[>..<];
var ents: Ent[>..<];
var tpool: u8[>..];
var order: i64[>..<];          // locs in TAGS order: the default first, then by tag
var errs_buf: u8[>..];
var nerr = 0;

fn put_err(file: const u8[:], line: i64, msg: const u8[:]) {
    format(errs_buf, "locales/", file, ":", line, ": error: ", msg, "\n");
    nerr += 1;
}

fn is_lower(c: u8) -> bool { c >= 'a' && c <= 'z' }
fn is_upper(c: u8) -> bool { c >= 'A' && c <= 'Z' }
fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn key_char(c: u8) -> bool { is_lower(c) || is_digit(c) || c == '_' }

fn name_ok(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > 64 || !is_lower(s[0]) { return false; }
    for c in s { if !key_char(c) { return false; } }
    return true;
}

fn listed(list: const u8[:][:], name: const u8[:]) -> bool {
    for w in list { if name == w { return true; } }
    return false;
}

// [a-z]{2,3}(-[A-Za-z0-9]{2,8})*, at most 32 bytes.
fn valid_tag(s: const u8[:]) -> bool {
    if s.len > 32 { return false; }
    var i = 0;
    while i < s.len && is_lower(s[i]) { i += 1; }
    if i < 2 || i > 3 { return false; }
    while i < s.len {
        if s[i] != '-' { return false; }
        i += 1;
        let st = i;
        while i < s.len && (is_lower(s[i]) || is_upper(s[i]) || is_digit(s[i])) { i += 1; }
        if i - st < 2 || i - st > 8 { return false; }
    }
    return true;
}

fn lower_eq(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len {
        var x = a[i];
        var y = b[i];
        if is_upper(x) { x += 32; }
        if is_upper(y) { y += 32; }
        if x != y { return false; }
    }
    return true;
}

fn lit(out: u8[>..]&, s: const u8[:]) {
    let hex = "0123456789abcdef";
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == '\r' { out.append("\\r"); }
        else if c < 32 || c == 127 { out.append("\\x"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else { out.push(c); }
    }
}

// ---------------------------------------------------------------- input

fn reset() {
    locs.clear();
    srcs.clear();
    dsrc.clear();
    has_default = false;
    def_tag.clear();
    def_file.clear();
    keys.clear();
    targs.clear();
    ents.clear();
    tpool.clear();
    order.clear();
    errs_buf.clear();
    nerr = 0;
}

// The text of locales/default, when the file exists.
fn start(default_src: const u8[:], present: bool) {
    reset();
    has_default = present;
    dsrc.append(default_src);
}

// file is a name in locales/ ending in .txt; src its text.
fn add_file(file: const u8[:], src: const u8[:]) {
    if file.len > 80 { put_err("default", 1, "a file name in locales/ is at most 80 bytes"); return; }
    var l = Loc { tag: "", file: "", ts: srcs.len, te: 0 };
    l.file.append(file);
    let tag = file[..file.len - 4];
    if valid_tag(tag) { l.tag.append(tag); }
    srcs.append(src);
    l.te = srcs.len;
    locs.push(l);
}

// ---------------------------------------------------------------- parsing

fn find_key(name: const u8[:]) -> i64 {
    for k, i in keys { if k.name == name { return i; } }
    return -1;
}

fn find_arg(k: i64, name: const u8[:]) -> i64 {
    for a, i in targs { if a.key == k && a.name == name { return i; } }
    return -1;
}

fn find_ent(p: i64, k: i64, cat: i64) -> i64 {
    for e, i in ents { if e.loc == p && e.key == k && e.cat == cat { return i; } }
    return -1;
}

fn has_key(p: i64, k: i64) -> bool {
    for e in ents { if e.loc == p && e.key == k { return true; } }
    return false;
}

fn cat_index(name: const u8[:]) -> i64 {
    for c in 6 { if name == CATS[c] { return c; } }
    return -1;
}

fn key_ok(file: const u8[:], line: i64, name: const u8[:]) -> bool {
    var m: u8[>..] = [];
    if name.len > 64 { put_err(file, line, "a key is at most 64 bytes"); return false; }
    if starts_with(name, "gw_") { put_err(file, line, "keys starting with gw_ are reserved"); return false; }
    if listed(KEYWORDS, name) { format(m, name, " is a Goose keyword; pick another key"); put_err(file, line, m); return false; }
    if listed(KEY_TAKEN, name) { format(m, name, " is used by the generated module; pick another key"); put_err(file, line, m); return false; }
    return true;
}

// inner is the text between { and }: name or name:int.
fn check_arg(p: i64, file: const u8[:], line: i64, k: i64, inner: const u8[:]) {
    var c = 0;
    while c < inner.len && inner[c] != ':' { c += 1; }
    let name = inner[..c];
    let typed = c < inner.len;
    let ty = if typed { inner[c + 1..] } else { "" };
    var m: u8[>..] = [];
    if name.len == 0 { put_err(file, line, "an argument needs a name, as {name}"); return; }
    if !name_ok(name) { format(m, "'", name, "' is not an argument name; use [a-z][a-z0-9_]*, or write \\{ for a literal brace"); put_err(file, line, m); return; }
    if starts_with(name, "gw_") || listed(KEYWORDS, name) || listed(ARG_TAKEN, name) {
        format(m, "'", name, "' cannot be an argument name here (a Goose keyword or a name the generated module uses)");
        put_err(file, line, m);
        return;
    }
    if typed && ty != "int" { format(m, "unknown type '", ty, "'; the only type is int, as {n:int}"); put_err(file, line, m); return; }
    let a = find_arg(k, name);
    if p == 0 {
        if a < 0 {
            var x = Arg { key: k, name: "", int: typed };
            x.name.append(name);
            targs.push(x);
        } else if typed && !targs[a].int {
            format(m, "type clash: argument ", name, " is text where it is first used; write {", name, ":int} there");
            put_err(file, line, m);
        }
        return;
    }
    if typed { format(m, "types are declared in ", def_file, " only; write {", name, "}"); put_err(file, line, m); return; }
    if a < 0 {
        format(m, "argument ", name, " is not in ", def_file, "'s text for ", keys[k].name, "; a locale may leave arguments out but not add them");
        put_err(file, line, m);
    }
}

fn scan_text(p: i64, file: const u8[:], line: i64, k: i64, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '\\' {
            if i + 1 >= s.len { put_err(file, line, "the text ends in a lone \\; write \\\\ for a backslash"); return; }
            let e = s[i + 1];
            if e != 'n' && e != '{' && e != '}' && e != '\\' { put_err(file, line, "unknown escape; the escapes are \\n, \\{, \\} and \\\\"); }
            i += 2;
        } else if c == '{' {
            var j = i + 1;
            while j < s.len && s[j] != '}' { j += 1; }
            if j >= s.len { put_err(file, line, "{ without }; write \\{ for a literal brace"); return; }
            check_arg(p, file, line, k, s[i + 1..j]);
            i = j + 1;
        } else if c == '}' {
            put_err(file, line, "a lone }; write \\} for a literal brace");
            i += 1;
        } else { i += 1; }
    }
}

// l is a trimmed line that is neither blank nor a comment.
fn parse_entry(p: i64, file: const u8[:], line: i64, l: const u8[:]) {
    var i = 0;
    while i < l.len && key_char(l[i]) { i += 1; }
    let name = l[..i];
    if name.len == 0 || !is_lower(name[0]) { put_err(file, line, "a line is key = text, and a key is [a-z][a-z0-9_]*"); return; }
    var cat = -1;
    if i < l.len && l[i] == '[' {
        var j = i + 1;
        while j < l.len && l[j] != ']' { j += 1; }
        if j >= l.len { put_err(file, line, "[ without ]; a plural form is key[one] = text"); return; }
        cat = cat_index(l[i + 1..j]);
        if cat < 0 { put_err(file, line, "unknown plural form; use [zero], [one], [two], [few], [many] or [other]"); return; }
        i = j + 1;
    }
    while i < l.len && (l[i] == ' ' || l[i] == '\t') { i += 1; }
    if i >= l.len || l[i] != '=' { put_err(file, line, "expected = after the key"); return; }
    let text = trim(l[i + 1..]);
    if !key_ok(file, line, name) { return; }
    var m: u8[>..] = [];
    var k = find_key(name);
    let want_plural = cat >= 0;
    if p == 0 {
        if k < 0 {
            var key = Key { name: "", plural: want_plural, line: line };
            key.name.append(name);
            keys.push(key);
            k = keys.len - 1;
            if want_plural {
                var x = Arg { key: k, name: "", int: true };
                x.name.append("count");
                targs.push(x);
            }
        }
    } else if k < 0 {
        format(m, "key ", name, " is not in the default locale (", def_file, ")");
        put_err(file, line, m);
        return;
    }
    if keys[k].plural != want_plural {
        if keys[k].plural { format(m, name, " is a plural key: write ", name, "[one], ", name, "[other] and the like"); }
        else { format(m, name, " is a plain key: write ", name, " = text"); }
        put_err(file, line, m);
        return;
    }
    let prev = find_ent(p, k, cat);
    if prev >= 0 {
        var shown: u8[>..] = [];
        shown.append(name);
        if want_plural { format(shown, "[", CATS[cat], "]"); }
        format(m, "duplicate key ", shown, " (first at line ", ents[prev].line, ")");
        put_err(file, line, m);
        return;
    }
    let ts = tpool.len;
    tpool.append(text);
    ents.push(Ent { loc: p, key: k, cat: cat, ts: ts, te: tpool.len, line: line });
    scan_text(p, file, line, k, text);
}

fn parse_file(p: i64, file: const u8[:], src: const u8[:]) {
    for raw, i in split(src, '\n') {
        let l = trim(raw);
        if l.len == 0 || l[0] == '#' { continue; }
        parse_entry(p, file, i + 1, l);
    }
}

fn parse_default_tag() {
    if !has_default { put_err("default", 1, "missing; it holds the default locale's tag, as in: en"); return; }
    var found = false;
    for raw, i in split(dsrc, '\n') {
        let l = trim(raw);
        if l.len == 0 || l[0] == '#' { continue; }
        if found { put_err("default", i + 1, "holds one line, the default locale's tag"); return; }
        if !valid_tag(l) { put_err("default", i + 1, "bad tag; a tag is like en, pt-BR or zh-Hant"); return; }
        def_tag.append(l);
        found = true;
    }
    if !found { put_err("default", 1, "is empty; it holds the default locale's tag, as in: en"); }
}

// ---------------------------------------------------------------- generating

fn resolve(p: i64, k: i64, c: i64) -> i64 {
    var e = find_ent(p, k, c);
    if e < 0 { e = find_ent(p, k, OTHER); }
    if e < 0 { e = find_ent(0, k, c); }
    if e < 0 { e = find_ent(0, k, OTHER); }
    return e;
}

fn flush_run(out: u8[>..]&, run: u8[>..]&) {
    if run.len == 0 { return; }
    out.append("gw_o.append(\"");
    lit(out, run);
    out.append("\"); ");
    run.clear();
}

// The statements that append entry e's text to gw_o; the text was checked by scan_text.
fn emit_text(out: u8[>..]&, k: i64, e: i64) {
    let s = tpool[ents[e].ts..ents[e].te];
    var run: u8[>..] = [];
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '\\' {
            if s[i + 1] == 'n' { run.push('\n'); } else { run.push(s[i + 1]); }
            i += 2;
        } else if c == '{' {
            var j = i + 1;
            while s[j] != '}' { j += 1; }
            let inner = s[i + 1..j];
            var q = 0;
            while q < inner.len && inner[q] != ':' { q += 1; }
            let name = inner[..q];
            flush_run(out, run);
            let a = find_arg(k, name);
            if a >= 0 && targs[a].int { format(out, "format(gw_o, ", name, "); "); } else { format(out, "gw_o.append(", name, "); "); }
            i = j + 1;
        } else { run.push(c); i += 1; }
    }
    flush_run(out, run);
}

// Locale p's text for key k; p is an index into TAGS.
fn emit_body(out: u8[>..]&, p: i64, k: i64) {
    if !keys[k].plural {
        var e = find_ent(p, k, -1);
        if e < 0 { e = find_ent(0, k, -1); }
        emit_text(out, k, e);
        return;
    }
    let other = resolve(p, k, OTHER);
    var any = false;
    for c in 5 { if resolve(p, k, c) != other { any = true; } }
    if !any { emit_text(out, k, other); return; }
    format(out, "let gw_p = gweb::_plural_index(TAGS[", p, "], count); ");
    var first = true;
    for c in 5 {
        let r = resolve(p, k, c);
        if r == other { continue; }
        if first { out.append("if "); } else { out.append(" else if "); }
        first = false;
        format(out, "gw_p == ", c, " { ");
        emit_text(out, k, r);
        out.append("}");
    }
    out.append(" else { ");
    emit_text(out, k, other);
    out.append("}");
}

fn emit_key(out: u8[>..]&, k: i64) {
    var params: u8[>..] = [];
    var call: u8[>..] = [];
    for a in targs {
        if a.key != k { continue; }
        if a.int { format(params, ", ", a.name, ": i64"); } else { format(params, ", ", a.name, ": const u8[:]"); }
        format(call, ", ", a.name);
    }
    format(out, "\nfn ", keys[k].name, "(ctx: const gweb::Ctx&", params, ") -> u8[>..] { return ", keys[k].name, "(ctx.locale", call, "); }\n");
    format(out, "fn ", keys[k].name, "(loc: i64", params, ") -> u8[>..] {\n    var gw_o: u8[>..] = [];\n    ");
    for p in 1..order.len {
        format(out, "if loc == ", p, " { ");
        emit_body(out, p, k);
        out.append("} else ");
    }
    out.append("{ ");
    emit_body(out, 0, k);
    out.append("}\n    return gw_o;\n}\n");
}

fn generate(out: u8[>..]&) {
    let n = order.len;
    out.append("// Generated by gweb from locales/. Do not edit; it is rewritten on every build.\n");
    out.append("namespace t;\nimport std;\nimport net;\nimport net.http;\nimport gweb;\nimport gweb.site.i18n;\n\n");
    out.append("let TAGS = [");
    for p in n {
        if p > 0 { out.append(", "); }
        format(out, "\"", locs[order[p]].tag, "\"");
    }
    out.append("];\n\n");
    format(out, "fn tag(ctx: const gweb::Ctx&) -> const u8[:] {\n    if ctx.locale < 0 || ctx.locale >= ", n, " { return TAGS[0]; }\n    return TAGS[ctx.locale];\n}\n\n");
    format(out, "fn find(tag: const u8[:]) -> i64, bool {\n    for i in ", n, " { if http::eq_nocase(tag, TAGS[i]) { return i, true; } }\n    return 0, false;\n}\n");
    for k in keys.len { emit_key(out, k); }
}

// The lines for the build to print: which keys a locale leaves to the default.
fn lacks(notes: u8[>..]&) {
    for p in 1..order.len {
        var list: u8[>..] = [];
        var n = 0;
        for k, ki in keys {
            if has_key(p, ki) { continue; }
            if n > 0 { list.append(", "); }
            list.append(k.name);
            n += 1;
        }
        if n == 0 { continue; }
        let l = locs[order[p]];
        var noun: const u8[:] = " keys";
        if n == 1 { noun = " key"; }
        format(notes, "gweb: locales/", l.file, " lacks ", n, noun, " (falls back to ", def_tag, "): ", list, "\n");
    }
}

fn count() -> i64 { return order.len; }

// out gets the source of t.goose, errs the error lines and notes the "lacks" lines. False when there are errors.
fn compile(out: u8[>..]&, errs: u8[>..]&, notes: u8[>..]&) -> bool {
    parse_default_tag();
    for l in locs {
        if l.tag.len == 0 { put_err(l.file, 1, "the file name is not <tag>.txt with a tag like en or pt-BR"); }
    }
    var di = -1;
    if def_tag.len > 0 {
        for l, i in locs { if l.tag == def_tag { di = i; } }
        if di < 0 { var m: u8[>..] = []; format(m, "there is no locales/", def_tag, ".txt for the default locale"); put_err("default", 1, m); }
    }
    for l, i in locs {
        if l.tag.len == 0 { continue; }
        for j in i { if locs[j].tag.len > 0 && lower_eq(locs[j].tag, l.tag) {
            var m: u8[>..] = [];
            format(m, "the same tag as ", locs[j].file, " when case is ignored");
            put_err(l.file, 1, m);
        } }
    }
    if nerr > 0 || di < 0 { errs.append(errs_buf); return false; }
    def_file.append(locs[di].file);
    order.push(di);
    var rest: i64[>..<] = [];
    for i in locs.len {
        if i == di { continue; }
        var j = rest.len;
        rest.push(i);
        while j > 0 && compare(locs[rest[j - 1]].tag, locs[i].tag) > 0 { rest[j] = rest[j - 1]; j -= 1; }
        rest[j] = i;
    }
    for i in rest { order.push(i); }
    for p in order.len {
        let l = locs[order[p]];
        parse_file(p, l.file, srcs[l.ts..l.te]);
    }
    for key in keys {
        if key.plural && find_ent(0, find_key(key.name), OTHER) < 0 {
            var m: u8[>..] = [];
            format(m, "plural key ", key.name, " needs an [other] form");
            put_err(def_file, key.line, m);
        }
    }
    if nerr > 0 { errs.append(errs_buf); return false; }
    generate(out);
    lacks(notes);
    return true;
}
