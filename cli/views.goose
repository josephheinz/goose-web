// vw: the views generator (DESIGN-ADDENDUM-19, D1 and D2).
//
// views/<group>/<Name>.goose (a struct Props) and views/<group>/<Name>.html become the namespace v_<group>_<Name>:
// the user's code, then the generated JSON codec, form and form parser, and the template's render function. The module
// `views` is the registry that finds a view by a name read at run time. The struct scanner is cli/structs.goose, which
// the form decoders share. It uses gweb.goose's helpers (err, read, lit, gen_template, ...) from the global namespace.

namespace vw;

import std;
import os;
import structs;

let K_TEXT = 0;
let K_INT = 1;
let K_BOOL = 2;
let K_ENUM = 3;
let K_GROUP = 4;
let K_LIST = 5;
let K_FOREIGN = 6;
let KIND_NAMES = ["Text", "Int", "Bool", "Enum", "Group", "List", "Foreign"];

let MAX_FIELDS = 32;
let MAX_SLOTS = 8;
let MAX_REPEAT = 64;

struct Fld { owner: u8[..64], name: u8[..64], kind: i64, cap: i64, ty: u8[..96], required: bool, line: i64,
             label: u8[..64], help: u8[..200], editor: u8[..32] }

// ns is v_<group>_<name>; meta_s..meta_e is the view's piece of meta_text.
struct View { group: u8[..32], name: u8[..64], goose: u8[..512], html: u8[..512], ns: u8[..120], meta_s: i64, meta_e: i64 }

var views: View[>..<];
var fields: Fld[>..<];               // every parsed struct field of the view being generated
var meta_text: u8[>..];              // per view, the Goose statements that fill its ViewMeta
var enum_names: u8[..64][>..<];      // enums written as helpers for the view being generated
var enum_vars: u8[>..];
var enum_labels: u8[>..];            // "Enum\tVariant\tlabel\n" from let ENUM_LABELS, for the view being generated
var parsed: u8[..96][>..<];         // the structs parse_struct has read for this view              // "Enum\tA,B,C\n" for each

fn has_views() -> bool { return views.len > 0; }

// ---------------------------------------------------------------- scan

fn group_ok(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > 32 || s[0] < 'a' || s[0] > 'z' { return false; }
    for c in s { if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') { return false; } }
    return true;
}

fn name_ok(s: const u8[:]) -> bool {
    if s.len == 0 || s.len > 64 || s[0] < 'A' || s[0] > 'Z' { return false; }
    for c in s { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) { return false; } }
    return true;
}

// base is a views/ folder: the project's, or a package's.
fn scan_in(base: const u8[:]) {
    var groups: u8[>..] = [];
    if !list_dir(base, groups) { return; }
    for g in split(groups, '\n') {
        if g.len == 0 || g[0] == '.' { continue; }
        var gdir: u8[>..] = [];
        format(gdir, base, "/", g);
        if !is_dir(gdir) { continue; }
        if !group_ok(g) { err(gdir, 0, "a views group is [a-z][a-z0-9_]*, as in views/widgets/"); continue; }
        var files: u8[>..] = [];
        if !list_dir(gdir, files) { continue; }
        for f in split(files, '\n') {
            if f.len == 0 || f[0] == '.' { continue; }
            let is_goose = ends_with(f, ".goose");
            let is_html = ends_with(f, ".html");
            if !is_goose && !is_html { continue; }
            let n = f[..f.len - (if is_goose { 6 } else { 5 })];
            var path: u8[>..] = [];
            format(path, gdir, "/", f);
            if !name_ok(n) { err(path, 0, "a view's name is [A-Z][A-Za-z0-9]*, as in views/widgets/Hero.goose"); continue; }
            // Each name is handled once, from its .goose file; the .html must exist beside it.
            var twin: u8[>..] = [];
            format(twin, gdir, "/", n, if is_goose { ".html" } else { ".goose" });
            if !file_exists(twin) {
                var m: u8[>..] = [];
                format(m, "a view needs both files: ", twin, " is missing");
                err(path, 0, m);
                continue;
            }
            if is_html { continue; }
            var v = View { group: "", name: "", goose: "", html: "", ns: "", meta_s: 0, meta_e: 0 };
            v.group.append(g);
            v.name.append(n);
            if path.len >= 512 || twin.len >= 512 { err(path, 0, "path too long"); continue; }
            v.goose.append(path);
            v.html.append(twin);
            format(v.ns, "v_", g, "_", n);
            views.push(v);
        }
    }
}

// The project's views/ and each package's: one set, sorted by group and name.
fn scan() {
    views.clear();
    scan_in("views");
    for pk in pkgs {
        var dir: u8[>..] = [];
        format(dir, pk.dir, "/views");
        scan_in(dir);
    }
    sort(views) { a, b => compare(a.group, b.group) < 0 || (a.group == b.group && compare(a.name, b.name) < 0) };
    for v, i in views {
        if i > 0 && views[i - 1].group == v.group && views[i - 1].name == v.name {
            var m: u8[>..] = [];
            format(m, "view ", v.group, "/", v.name, " is also defined in ", views[i - 1].goose, "; a view's name is unique in its group");
            err(v.goose, 0, m);
        }
    }
}

// ---------------------------------------------------------------- reading the Goose file

// The string literal after `let NAME = ` (its text between the quotes, as written), or "".
fn let_literal(code: const u8[:], name: const u8[:]) -> const u8[:] {
    var pat: u8[>..] = [];
    format(pat, "let ", name, " ");
    for line in split(code, '\n') {
        let t = trim_start(line);
        if !starts_with(t, pat) { continue; }
        let eq = find(t, "=");
        if eq < 0 { return ""; }
        let r = trim_start(t[eq + 1..]);
        if r.len == 0 || r[0] != '"' { return ""; }
        var e = 1;
        while e < r.len && r[e] != '"' { if r[e] == '\\' { e += 1; } e += 1; }
        if e >= r.len { return ""; }
        return r[1..e];
    }
    return "";
}

// In text, after key: ("name:" then a string literal), the literal's inside as written; ok false when there is none.
fn key_literal(text: const u8[:], key: const u8[:]) -> const u8[:], bool {
    var pat: u8[>..] = [];
    format(pat, key, ":");
    var at = 0;
    while at < text.len {
        let k = find(text[at..], pat);
        if k < 0 { return "", false; }
        let p = at + k;
        let ok_start = p == 0 || !(ident_byte(text[p - 1]));
        at = p + pat.len;
        if !ok_start { continue; }
        let r = trim_start(text[at..]);
        if r.len == 0 || r[0] != '"' { return "", false; }
        var e = 1;
        while e < r.len && r[e] != '"' { if r[e] == '\\' { e += 1; } e += 1; }
        if e >= r.len { return "", false; }
        return r[1..e], true;
    }
    return "", false;
}

// The brace groups `Type { ... }` of the `let NAME = [ ... ];` statement, each handed to F(text, line).
fn each_literal<F>(code: const u8[:], name: const u8[:], type_name: const u8[:]) {
    let lines = split(code, '\n');
    var pat: u8[>..] = [];
    format(pat, "let ", name, " ");
    var start = -1;
    for line, i in lines { if starts_with(trim_start(line), pat) { start = i; break; } }
    if start < 0 { return; }
    var depth = 0;
    var in_str = false;
    var cur: u8[>..] = [];
    var cur_line = 0;
    var ln = start;
    var done = false;
    var seen_eq = false;
    while ln < lines.len && !done {
        let line = lines[ln];
        var ci = 0;
        while ci < line.len {
            let c = line[ci];
            if in_str {
                if depth >= 2 { cur.push(c); }
                if c == '\\' && ci + 1 < line.len { ci += 1; if depth >= 2 { cur.push(line[ci]); } }
                else if c == '"' { in_str = false; }
                ci += 1;
                continue;
            }
            if c == '/' && ci + 1 < line.len && line[ci + 1] == '/' { break; }
            if !seen_eq { if c == '=' { seen_eq = true; } ci += 1; continue; }
            if c == ';' && depth == 0 { done = true; break; }
            if c == '"' { in_str = true; }
            if c == '[' || c == '{' || c == '(' {
                depth += 1;
                if c == '{' && depth == 2 { cur.clear(); cur_line = ln + 1; ci += 1; continue; }
            }
            if c == ']' || c == '}' || c == ')' {
                if c == '}' && depth == 2 { F(cur, cur_line); cur.clear(); }
                depth -= 1;
            }
            if depth >= 2 { cur.push(c); }
            ci += 1;
        }
        if depth >= 2 { cur.push(' '); }
        ln += 1;
    }
}

// ---------------------------------------------------------------- the struct and its fields

// Adds the fields of `struct sname` to `fields` (owner sname). top: Props, which may hold a group and a repeater.
// Returns false after reporting.
fn parse_struct(src: const u8[:], lines, sname: const u8[:], top: bool, from_line: i64) -> bool {
    var pn: u8[..96] = "";
    pn.append(sname);
    parsed.push(pn);
    let k = structs::find_decl(lines, "struct", sname);
    if k < 0 {
        var m: u8[>..] = [];
        if top { format(m, "a view needs `struct ", sname, " {` in its .goose file"); }
        else { format(m, "struct ", sname, " is not declared in this file"); }
        err(src, from_line, m);
        return false;
    }
    var good = true;
    let first = fields.len;
    let next, closed = structs::fields(lines, k) { text, ln => if !add_field(src, lines, sname, top, text, ln) { good = false; }; };
    if !closed { err(src, k + 1, "this struct is never closed with }"); return false; }
    if fields.len - first > MAX_FIELDS {
        var m: u8[>..] = [];
        format(m, "struct ", sname, " has more than ", MAX_FIELDS, " fields");
        err(src, k + 1, m);
        good = false;
    }
    // A repeater is the last field, so its growable array stays the tail of the struct.
    for i in first..fields.len {
        if fields[i].kind == K_LIST && i != fields.len - 1 {
            err(src, fields[i].line, "a repeater (T[>..<]) is the last field of Props");
            good = false;
        }
    }
    return good;
}

// Parses the structs behind groups and repeaters, once each. Returns false after reporting.
fn parse_inner(src: const u8[:], lines) -> bool {
    var good = true;
    var j = 0;
    while j < fields.len {
        if fields[j].kind == K_GROUP || fields[j].kind == K_LIST {
            let inner: u8[..96] = fields[j].ty;
            var known = false;
            for p in parsed { if p == inner { known = true; } }
            if !known && !parse_struct(src, lines, inner, false, fields[j].line) { good = false; }
        }
        j += 1;
    }
    return good;
}

fn is_number(s: const u8[:]) -> bool {
    if s.len == 0 { return false; }
    for c in s { if c < '0' || c > '9' { return false; } }
    return true;
}

fn add_field(src: const u8[:], lines, sname: const u8[:], top: bool, text: const u8[:], ln: i64) -> bool {
    let t = trim(text);
    if t.len == 0 { return true; }
    let colon = find(t, ":");
    let msg = "Props fields are i64, bool, u8[..N], an enum without payloads, a struct of this file, a repeater of one (last) or ns::T";
    if colon <= 0 { err(src, ln, msg); return false; }
    let name = trim(t[..colon]);
    let rest = trim_start(t[colon + 1..]);
    let eq = find(rest, "=");
    let ty = trim(if eq >= 0 { rest[..eq] } else { rest });
    if !is_ident(name) || name.len > 64 || ty.len == 0 || ty.len > 96 { err(src, ln, msg); return false; }
    var f = Fld { owner: "", name: "", kind: K_TEXT, cap: 0, ty: "", required: eq < 0, line: ln, label: "", help: "", editor: "" };
    f.owner.append(sname);
    f.name.append(name);
    f.ty.append(ty);
    if ty == "i64" { f.kind = K_INT; }
    else if ty == "bool" { f.kind = K_BOOL; }
    else if starts_with(ty, "u8[..") && ends_with(ty, "]") {
        let n, ok = parse_int(ty[5..ty.len - 1]);
        if !ok || n <= 0 { err(src, ln, "a text field is u8[..N] with N a number above 0"); return false; }
        f.kind = K_TEXT;
        f.cap = n;
    }
    else if ends_with(ty, "[>..<]") || ends_with(ty, "[>..]") || (find(ty, "[..") > 0 && ends_with(ty, "]")) {
        if !top { err(src, ln, "a repeater's items hold no repeater"); return false; }
        let br = find(ty, "[");
        let el = ty[..br];
        if !is_ident(el) { err(src, ln, "a repeater is T[>..<] of a struct of this file"); return false; }
        f.kind = K_LIST;
        f.cap = MAX_REPEAT;
        if find(ty, "[..") > 0 {
            let n, ok = parse_int(ty[br + 3..ty.len - 1]);
            if !ok || n <= 0 || n > MAX_REPEAT { err(src, ln, "a repeater holds at most 64 items"); return false; }
            f.cap = n;
        }
        f.ty.clear();
        f.ty.append(el);
        if structs::find_decl(lines, "struct", el) < 0 {
            var m: u8[>..] = [];
            format(m, "struct ", el, " is not declared in this file");
            err(src, ln, m);
            return false;
        }
    }
    else if find(ty, "::") > 0 { f.kind = K_FOREIGN; }
    else if is_ident(ty) {
        if structs::find_decl(lines, "enum", ty) >= 0 {
            f.kind = K_ENUM;
            if !note_enum(src, lines, ty, ln) { return false; }
        } else if structs::find_decl(lines, "struct", ty) >= 0 {
            if !top { err(src, ln, "a struct inside a struct holds no struct"); return false; }
            f.kind = K_GROUP;
        } else {
            var m: u8[>..] = [];
            format(m, ty, " is not a type views know: ", msg);
            err(src, ln, m);
            return false;
        }
    }
    else { err(src, ln, msg); return false; }
    fields.push(f);
    return true;
}

// Records the variants of an enum; false for a variant with a payload or a value.
fn note_enum(src: const u8[:], lines, name: const u8[:], at: i64) -> bool {
    for n in enum_names { if n == name { return true; } }
    let k = structs::find_decl(lines, "enum", name);
    var list: u8[>..] = [];
    var good = true;
    let next, closed = structs::fields(lines, k) { text, ln =>
        let v = trim(text);
        if v.len > 0 {
            if !is_ident(v) {
                var m: u8[>..] = [];
                format(m, "enum ", name, ": a view's enum has variants with no payload, as in { Light, Dark }");
                err(src, ln, m);
                good = false;
            } else { if list.len > 0 { list.push(','); } list.append(v); }
        }
    };
    if !closed || !good || list.len == 0 { if good { err(src, at, "this enum has no variants"); } return false; }
    var e: u8[..64] = "";
    e.append(name);
    enum_names.push(e);
    format(enum_vars, name, "\t", list, "\n");
    return true;
}

fn variants_of(name: const u8[:]) -> const u8[:] {
    for l in split(enum_vars, '\n') {
        let a, b, ok = split_once(l, '\t');
        if ok && a == name { return b; }
    }
    return "";
}

// ---------------------------------------------------------------- labels, UI and renames

fn humanize(out: u8[>..]&, s: const u8[:]) {
    for c, i in s {
        if c == '_' { out.push(' '); }
        else if i == 0 { out.push(if c >= 'a' && c <= 'z' { c - 32 } else { c }); }
        else { out.push(c); }
    }
}

// "TwoColumn" is "Two column".
fn humanize_camel(out: u8[>..]&, s: const u8[:]) {
    for c, i in s {
        if c >= 'A' && c <= 'Z' {
            if i > 0 { out.push(' '); out.push(c + 32); } else { out.push(c); }
        } else { out.push(c); }
    }
}

fn find_field(owner: const u8[:], name: const u8[:]) -> i64 {
    for f, i in fields { if f.owner == owner && f.name == name { return i; } }
    return -1;
}

// Applies let UI = [gweb::FieldUi { ... }]; each `field:` must name a field.
fn apply_ui(src: const u8[:], code: const u8[:]) {
    each_literal(code, "UI", "FieldUi") { text, ln =>
        let name, ok = key_literal(text, "field");
        if !ok { err(src, ln, "each gweb::FieldUi needs field: \"name\" (string literals only)"); }
        else {
            var idx = -1;
            let dot = find(name, ".");
            if dot < 0 { idx = find_field("Props", name); }
            else {
                let g = find_field("Props", name[..dot]);
                if g >= 0 && (fields[g].kind == K_GROUP || fields[g].kind == K_LIST) {
                    let inner: u8[..96] = fields[g].ty;
                    idx = find_field(inner, name[dot + 1..]);
                }
            }
            if idx < 0 {
                var m: u8[>..] = [];
                format(m, "UI: field \"", name, "\" is not a field of Props");
                err(src, ln, m);
            } else {
                let label, lok = key_literal(text, "label");
                let help, hok = key_literal(text, "help");
                let editor, eok = key_literal(text, "editor");
                if lok { fields[idx].label.clear(); fields[idx].label.append(label[..min(label.len, 64)]); }
                if hok { fields[idx].help.clear(); fields[idx].help.append(help[..min(help.len, 200)]); }
                if eok { fields[idx].editor.clear(); fields[idx].editor.append(editor[..min(editor.len, 32)]); }
            }
        }
    };
}

// Reads let ENUM_LABELS = [gweb::EnumLabel { ty: "Gap", variant: "Wide", label: "Wide gap" }]; each names an enum of
// the view's fields and one of its variants.
fn apply_enum_labels(src: const u8[:], code: const u8[:]) {
    enum_labels.clear();
    each_literal(code, "ENUM_LABELS", "EnumLabel") { text, ln =>
        let ty, tok = key_literal(text, "ty");
        let variant, vok = key_literal(text, "variant");
        let label, lok = key_literal(text, "label");
        if !tok || !vok || !lok { err(src, ln, "each gweb::EnumLabel needs ty, variant and label (string literals only)"); }
        else {
            var known = false;
            for v in split(variants_of(ty), ',') { if v.len > 0 && v == variant { known = true; } }
            if !known {
                var m: u8[>..] = [];
                format(m, "ENUM_LABELS: ", ty, ".", variant, " is not a variant of an enum of this view's fields");
                err(src, ln, m);
            } else if label.len == 0 || label.len > 64 || find(label, "\t") >= 0 {
                err(src, ln, "ENUM_LABELS: a label is 1 to 64 bytes");
            } else { format(enum_labels, ty, "\t", variant, "\t", label, "\n"); }
        }
    };
}

// The label of a variant: from ENUM_LABELS, else "".
fn enum_label(ty: const u8[:], variant: const u8[:]) -> const u8[:] {
    for l in split(enum_labels, '\n') {
        let f = split(l, '\t');
        if f.len == 3 && f[0] == ty && f[1] == variant { return f[2]; }
    }
    return "";
}

fn has_enum_labels(ty: const u8[:]) -> bool {
    for v in split(variants_of(ty), ',') { if enum_label(ty, v).len > 0 { return true; } }
    return false;
}

// The stored keys that also read as field `name`.
fn renamed_from(code: const u8[:], name: const u8[:], keys: u8[>..]&) {
    each_literal(code, "RENAMED", "Renamed") { text, ln =>
        let from, fok = key_literal(text, "from");
        let to, tok = key_literal(text, "to");
        if fok && tok && to == name { keys.append(from); keys.push('\n'); }
    };
}

fn label_of(f: const Fld&, out: u8[>..]&) {
    if f.label.len > 0 { out.append(f.label); } else { humanize(out, f.name); }
}

// ---------------------------------------------------------------- generated code for one struct

fn names_array(m: u8[>..]&, enum_name: const u8[:]) {
    m.push('[');
    for v, i in split(variants_of(enum_name), ',') { if i > 0 { m.append(", "); } format(m, "\"", v, "\""); }
    m.push(']');
}

fn gen_read_struct(m: u8[>..]&, code: const u8[:], sname: const u8[:]) {
    format(m, "fn gw_read_", sname, "(r: json::Reader&, v: ", sname, "&, warn: i64&) {\n");
    m.append("    if json::peek(r) != '{' { json::skip(r); warn += 1; return; }\n    json::each_member(r) { key =>\n");
    var first = true;
    for f in fields {
        if f.owner != sname { continue; }
        m.append(if first { "        if key == \"" } else { "        else if key == \"" });
        first = false;
        m.append(f.name);
        m.push('"');
        if sname == "Props" {
            var keys: u8[>..] = [];
            renamed_from(code, f.name, keys);
            for k in split(keys, '\n') { if k.len > 0 { format(m, " || key == \"", k, "\""); } }
        }
        m.append(" { ");
        if f.kind == K_TEXT { format(m, "gweb::_jr_text(r, v.", f.name, ", warn);"); }
        else if f.kind == K_INT { format(m, "gweb::_jr_int(r, v.", f.name, ", warn);"); }
        else if f.kind == K_BOOL { format(m, "gweb::_jr_bool(r, v.", f.name, ", warn);"); }
        else if f.kind == K_ENUM {
            m.append("let k = gweb::_jr_enum(r, ");
            names_array(m, f.ty);
            format(m, ", warn); if k >= 0 { v.", f.name, " = gw_pick_", f.ty, "(k); }");
        }
        else if f.kind == K_GROUP { format(m, "gw_read_", f.ty, "(r, v.", f.name, ", warn);"); }
        else if f.kind == K_LIST {
            format(m, "if json::peek(r) == '[' { json::each_element(r) { var it = ", f.ty, " { .. }; gw_read_", f.ty, "(r, it, warn); ",
                   "if v.", f.name, ".len < ", f.cap, " { v.", f.name, ".push(it); } else { warn += 1; } }; } else { json::skip(r); warn += 1; }");
        }
        else { format(m, find_ns(f.ty), "::gw_read(r, v.", f.name, ", warn);"); }
        m.append(" }\n");
    }
    if first { m.append("        json::skip(r);\n"); }
    else { m.append("        else { json::skip(r); }\n"); }
    m.append("    };\n}\n");
}

fn find_ns(ty: const u8[:]) -> const u8[:] { return ty[..find(ty, "::")]; }

fn gen_write_struct(m: u8[>..]&, sname: const u8[:]) {
    format(m, "fn gw_write_", sname, "(out: u8[>..]&, v: const ", sname, "&) {\n    out.push('{');\n");
    var first = true;
    for f in fields {
        if f.owner != sname { continue; }
        if !first { m.append("    out.push(',');\n"); }
        first = false;
        format(m, "    json::format_key(out, \"", f.name, "\"); ");
        if f.kind == K_TEXT { format(m, "json::format_string(out, v.", f.name, ");"); }
        else if f.kind == K_INT { format(m, "json::format_int(out, v.", f.name, ");"); }
        else if f.kind == K_BOOL { format(m, "json::format_bool(out, v.", f.name, ");"); }
        else if f.kind == K_ENUM { format(m, "json::format_string(out, gw_name_", f.ty, "(v.", f.name, "));"); }
        else if f.kind == K_GROUP { format(m, "gw_write_", f.ty, "(out, v.", f.name, ");"); }
        else if f.kind == K_LIST {
            format(m, "out.push('['); var first = true; for it in v.", f.name, " { if !first { out.push(','); } first = false; gw_write_", f.ty, "(out, it); } out.push(']');");
        }
        else { format(m, find_ns(f.ty), "::gw_write(out, v.", f.name, ");"); }
        m.push('\n');
    }
    m.append("    out.push('}');\n}\n");
}

fn lit_arg(m: u8[>..]&, s: const u8[:]) { m.push('"'); m.append(s); m.push('"'); }

fn gen_form_struct(m: u8[>..]&, sname: const u8[:]) {
    format(m, "fn gw_form_", sname, "(out: u8[>..]&, prefix: const u8[:], v: const ", sname, "&, errs: const gweb::FieldErrors&, req: const http::Request&, rich: bool) {\n");
    for f in fields {
        if f.owner != sname { continue; }
        var label: u8[>..] = [];
        label_of(f, label);
        m.append("    ");
        if f.kind == K_TEXT {
            format(m, "gweb::_vf_text(out, prefix, \"", f.name, "\", \"", label, "\", \"", f.help, "\", \"", f.editor, "\", ", f.cap, ", v.", f.name,
                   ", errs, ", if f.required { "true" } else { "false" }, ", req, rich);");
        }
        else if f.kind == K_INT {
            format(m, "gweb::_vf_int(out, prefix, \"", f.name, "\", \"", label, "\", \"", f.help, "\", \"", f.editor, "\", v.", f.name,
                   ", errs, ", if f.required { "true" } else { "false" }, ", req, rich);");
        }
        else if f.kind == K_BOOL { format(m, "gweb::_vf_bool(out, prefix, \"", f.name, "\", \"", label, "\", \"", f.help, "\", v.", f.name, ", errs, rich);"); }
        else if f.kind == K_ENUM && (f.editor == "radio" || has_enum_labels(f.ty)) {
            format(m, "{ let ui = gweb::_EnumUi { field: \"", f.name, "\", label: \"", label, "\", help: \"", f.help, "\", radio: ",
                   if f.editor == "radio" { "true" } else { "false" }, ", required: ", if f.required { "true" } else { "false" }, ", names: ");
            m.push('"');
            for v, i in split(variants_of(f.ty), ',') { if i > 0 { m.append("\\n"); } m.append(v); }
            m.append("\", labels: \"");
            for v, i in split(variants_of(f.ty), ',') {
                if i > 0 { m.append("\\n"); }
                let l = enum_label(f.ty, v);
                m.append(if l.len > 0 { l } else { v });
            }
            format(m, "\" }; gweb::_vf_choice(out, prefix, ui, gw_name_", f.ty, "(v.", f.name, "), errs, rich); }");
        }
        else if f.kind == K_ENUM {
            format(m, "gweb::_vf_enum(out, prefix, \"", f.name, "\", \"", label, "\", \"", f.help, "\", ");
            names_array(m, f.ty);
            format(m, ", gw_name_", f.ty, "(v.", f.name, "), errs, ", if f.required { "true" } else { "false" }, ", rich);");
        }
        else if f.kind == K_GROUP {
            format(m, "{ gweb::_vf_group_open(out, \"", label, "\"); var gp: u8[>..] = []; format(gp, prefix, \"", f.name, ".\"); gw_form_", f.ty,
                   "(out, gp, v.", f.name, ", errs, req, rich); gweb::_vf_group_close(out); }");
        }
        else if f.kind == K_LIST {
            // The item's legend shows its ITEM_LABEL field in rich forms.
            var item_label: u8[>..] = [];
            if item_label_field.len > 0 { format(item_label, "it.", item_label_field); } else { item_label.append("\"\""); }
            format(m, "{ gweb::_vf_list_open(out, prefix, \"", f.name, "\", \"", label, "\", v.", f.name, ".len, rich); var n = 0; for it in v.", f.name,
                   " { var ip: u8[>..] = []; format(ip, prefix, \"", f.name, ".\", n, \".\"); gweb::_vf_item_open(out, n, ", item_label, ", rich); gw_form_", f.ty,
                   "(out, ip, it, errs, req, rich); gweb::_vf_item_close(out, prefix, \"", f.name, "\", n, v.", f.name, ".len, rich); n += 1; } gweb::_vf_list_close(out, prefix, \"",
                   f.name, "\", v.", f.name, ".len, ", f.cap, ", rich); }");
        }
        else {
            format(m, "{ var fname: u8[>..] = []; format(fname, prefix, \"", f.name, "\"); ", find_ns(f.ty), "::gw_field(out, fname, v.", f.name,
                   ", \"", label, "\", \"", f.help, "\", \"", f.editor, "\", errs); }");
        }
        m.push('\n');
    }
    m.append("}\n");
}

fn gen_parse_struct(m: u8[>..]&, sname: const u8[:]) {
    format(m, "fn gw_parse_", sname, "(req: const http::Request&, prefix: const u8[:], v: ", sname, "&, errs: gweb::FieldErrors&) {\n");
    for f in fields {
        if f.owner != sname { continue; }
        let req = if f.required { "true" } else { "false" };
        m.append("    ");
        if f.kind == K_TEXT { format(m, "gweb::_vp_text(req, prefix, \"", f.name, "\", v.", f.name, ", errs, ", req, ");"); }
        else if f.kind == K_INT { format(m, "gweb::_vp_int(req, prefix, \"", f.name, "\", v.", f.name, ", errs, ", req, ");"); }
        else if f.kind == K_BOOL { format(m, "gweb::_vp_bool(req, prefix, \"", f.name, "\", v.", f.name, ");"); }
        else if f.kind == K_ENUM {
            m.append("{ let k = gweb::_vp_enum(req, prefix, \"");
            format(m, f.name, "\", ");
            names_array(m, f.ty);
            format(m, ", errs, ", req, "); if k >= 0 { v.", f.name, " = gw_pick_", f.ty, "(k); } }");
        }
        else if f.kind == K_GROUP {
            format(m, "{ var gp: u8[>..] = []; format(gp, prefix, \"", f.name, ".\"); gw_parse_", f.ty, "(req, gp, v.", f.name, ", errs); }");
        }
        else if f.kind == K_LIST {
            format(m, "{ let n = gweb::_vp_count(req, prefix, \"", f.name, "\", ", f.cap, ", errs); v.", f.name, ".clear(); for k in n { var it = ", f.ty,
                   " { .. }; var ip: u8[>..] = []; format(ip, prefix, \"", f.name, ".\", k, \".\"); gw_parse_", f.ty, "(req, ip, it, errs); v.", f.name, ".push(it); } }");
        }
        else {
            format(m, "{ var fname: u8[>..] = []; format(fname, prefix, \"", f.name, "\"); ", find_ns(f.ty), "::gw_parse(req, fname, v.", f.name, ", errs); }");
        }
        m.push('\n');
    }
    m.append("}\n");
}

// The repeater buttons of a rich form (up, down, del, add), applied after the items are read. Returns true when one
// was applied; the errors the parse added are dropped then, since the form is shown again, not saved.
fn gen_act_struct(m: u8[>..]&, sname: const u8[:]) {
    format(m, "fn gw_act_", sname, "(req: const http::Request&, prefix: const u8[:], v: ", sname, "&, errs: gweb::FieldErrors&, before: i64) -> bool {\n");
    var has_list = false;
    for f in fields {
        if f.owner != sname || f.kind != K_LIST { continue; }
        has_list = true;
        let n = f.name;
        format(m, "    let kind, k = gweb::_vp_act(req, prefix, \"", n, "\");\n    if kind == 0 { return false; }\n");
        m.append("    errs.n = before;\n    if before == 0 { errs.dropped = false; }\n");
        format(m, "    if kind == 1 {\n        if v.", n, ".len < ", f.cap, " { v.", n, ".push(", f.ty, " { .. }); }\n",
               "        else { var id: u8[>..] = []; format(id, prefix, \"", n, ".n\"); gweb::add_error(errs, id, \"Too many items.\"); }\n    }\n");
        format(m, "    else if kind == 2 && k < v.", n, ".len {\n        var i = k;\n        while i + 1 < v.", n, ".len { v.", n, "[i] = v.", n, "[i + 1]; i += 1; }\n        v.", n, ".pop();\n    }\n");
        format(m, "    else if kind == 3 && k > 0 && k < v.", n, ".len { let t = v.", n, "[k]; v.", n, "[k] = v.", n, "[k - 1]; v.", n, "[k - 1] = t; }\n");
        format(m, "    else if kind == 4 && k + 1 < v.", n, ".len { let t = v.", n, "[k]; v.", n, "[k] = v.", n, "[k + 1]; v.", n, "[k + 1] = t; }\n");
        m.append("    return true;\n");
    }
    if !has_list { m.append("    return false;\n"); }
    m.append("}\n");
}

fn gen_enum_helpers(m: u8[>..]&) {
    for e in enum_names {
        let vs = variants_of(e);
        format(m, "fn gw_name_", e, "(v: ", e, ") -> const u8[:] {\n    match v {\n");
        for n in split(vs, ',') { format(m, "        ", n, " => \"", n, "\",\n"); }
        m.append("    }\n}\n");
        format(m, "fn gw_pick_", e, "(k: i64) -> ", e, " {\n    match k {\n");
        for n, i in split(vs, ',') { format(m, "        ", i, " => ", e, ".", n, ",\n"); }
        format(m, "        _ => ", e, ".", split(vs, ',')[0], ",\n    }\n}\n");
    }
}

// ---------------------------------------------------------------- one view

fn field_kind_ty(f: const Fld&) -> const u8[:] {
    if f.kind == K_ENUM || f.kind == K_GROUP || f.kind == K_LIST || f.kind == K_FOREIGN { return f.ty; }
    return "";
}

// let ITEM_LABEL = "title"; names a text field of the repeater's item. A rich form shows it in the item's legend.
fn check_item_label(src: const u8[:], code: const u8[:]) {
    item_label_field.clear();
    let name = let_literal(code, "ITEM_LABEL");
    if name.len == 0 { return; }
    var list_ty: u8[..96] = "";
    for f in fields { if f.owner == "Props" && f.kind == K_LIST { list_ty.clear(); list_ty.append(f.ty); } }
    var ln = 0;
    for line, i in split(code, '\n') { if starts_with(trim_start(line), "let ITEM_LABEL ") { ln = i + 1; } }
    var m: u8[>..] = [];
    if list_ty.len == 0 { err(src, ln, "ITEM_LABEL needs a repeater in Props"); return; }
    let idx = find_field(list_ty, name);
    if idx < 0 || fields[idx].kind != K_TEXT {
        format(m, "ITEM_LABEL: \"", name, "\" is not a text field of ", list_ty);
        err(src, ln, m);
        return;
    }
    item_label_field.append(name);
}

// Generates the view's namespace file and its template. Returns false after reporting.
fn gen_view(v: View&) -> bool {
    var code: u8[>..] = [];
    if !read_checked(v.goose, code) { return false; }
    let before = errors;
    for n in ["read", "write", "defaults", "form", "form_req", "parse"] {
        if defines(code, n) {
            var m: u8[>..] = [];
            format(m, "fn ", n, " is generated for every view; rename yours");
            for line, i in split(code, '\n') {
                var pat: u8[>..] = [];
                format(pat, "fn ", n, "(");
                if starts_with(trim_start(line), pat) { err(v.goose, i + 1, m); }
            }
        }
    }
    fields.clear();
    parsed.clear();
    enum_names.clear();
    enum_vars.clear();
    enum_labels.clear();
    let lines = split(code, '\n');
    if parse_struct(v.goose, lines, "Props", true, 0) && parse_inner(v.goose, lines) { apply_ui(v.goose, code); check_item_label(v.goose, code); apply_enum_labels(v.goose, code); }
    if errors > before { return false; }
    var extra: u8[>..] = [];
    extra.append("\n// gweb: view codec, form and parser (generated)\n");
    gen_enum_helpers(extra);
    var seen: u8[..64][>..<] = [];
    for f in fields {
        var done = false;
        for s in seen { if s == f.owner { done = true; } }
        if done { continue; }
        var o: u8[..64] = "";
        o.append(f.owner);
        seen.push(o);
        gen_read_struct(extra, code, f.owner);
        gen_write_struct(extra, f.owner);
        gen_form_struct(extra, f.owner);
        gen_parse_struct(extra, f.owner);
        if f.owner == "Props" { gen_act_struct(extra, f.owner); }
    }
    extra.append("""
fn read(text: const u8[:], p: Props&) -> i64 {
    var r = json::reader(text);
    var warn = 0;
    if json::peek(r) == 0 { return 0; }
    gw_read_Props(r, p, warn);
    if !json::finish(r) { warn += 1; }
    return warn;
}
fn write(out: u8[>..]&, p: const Props&) { gw_write_Props(out, p); }
fn defaults(out: u8[>..]&) { var p = Props { .. }; gw_write_Props(out, p); }
fn form(out: u8[>..]&, text: const u8[:], errs: const gweb::FieldErrors&, prefix: const u8[:]) {
    var p = Props { .. };
    read(text, p);
    let none = http::empty_request();
    gw_form_Props(out, prefix, p, errs, none, false);
}
fn form_req(out: u8[>..]&, req: const http::Request&, text: const u8[:], errs: const gweb::FieldErrors&, prefix: const u8[:]) {
    var p = Props { .. };
    read(text, p);
    gw_form_Props(out, prefix, p, errs, req, true);
}
fn parse(req: const http::Request&, prefix: const u8[:], out: u8[>..]&, errs: gweb::FieldErrors&) -> bool {
    var p = Props { .. };
    let before = errs.n;
    gw_parse_Props(req, prefix, p, errs);
    let acted = gw_act_Props(req, prefix, p, errs, before);
""");
    // validate names its fields plainly ("title"); the form shows errors under the control's name, so they get the prefix.
    if defines(code, "validate") {
        extra.append("    if errs.n == before && !acted {\n        var ve = gweb::no_errors();\n        validate(p, ve);\n");
        extra.append("        for k in ve.n {\n            var fname: u8[>..] = [];\n            if ve.items[k].field.len > 0 { format(fname, prefix, ve.items[k].field); }\n");
        extra.append("            gweb::add_error(errs, fname, ve.items[k].message);\n        }\n    }\n");
    }
    // The JSON is written after an error too: it holds what the user sent, so the page can show the form again as typed.
    extra.append("    write(out, p);\n    return errs.n == before && !acted;\n}\n");
    var more: u8[>..] = [];
    more.append("import json; import net.http; import gweb; import gweb.site.views; import gweb.forms.valid; ");
    write_prefixed(v.goose, v.ns, code, extra, more);

    // The template.
    var imports: u8[>..] = [];
    imports_of(code, imports);
    add_default_imports(imports);
    var frags: u8[>..] = [];
    var base: u8[>..] = [];
    format(base, v.ns, "_html");
    view_group.clear(); view_group.append(v.group);
    view_name.clear(); view_name.append(v.name);
    gen_template(v.html, v.ns, base,
                 "fn render<Z, D>(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, props: const Props&, doc: const D&, at: i64)",
                 imports, K_VIEW, -1, frags);
    return errors == before;
}

// The statements that fill the view's ViewMeta, from its fields and the slots its template declared.
fn gen_meta(v: const View&, label: const u8[:], slots: const u8[:]) {
    var m: u8[>..] = [];
    var lbl: u8[>..] = [];
    if label.len > 0 { lbl.append(label); } else { humanize_camel(lbl, v.name); }
    let icon = let_literal(cur_code, "ICON");
    format(m, "            m.name.append(\"", v.name, "\"); m.group.append(\"", v.group, "\"); m.label.append(\"", lbl[..min(lbl.len, 64)], "\"); m.icon.append(\"", icon, "\");\n");
    for f in fields {
        if f.owner != "Props" { continue; }
        var l: u8[>..] = [];
        label_of(f, l);
        var kind: u8[>..] = [];
        format(kind, "gweb::FieldKind.", KIND_NAMES[f.kind]);
        format(m, "            gweb::_vm_field(m, \"", f.name, "\", \"", l, "\", \"", f.help, "\", \"", f.editor, "\", ", kind, ", \"", field_kind_ty(f), "\", ",
               f.cap, ", ", if f.required { "true" } else { "false" }, ");\n");
    }
    for l in split(slots, '\n') {
        let parts = split(l, '\t');
        if parts.len != 4 || parts[0] != v.group || parts[1] != v.name { continue; }
        format(m, "            gweb::_vm_slot(m, \"", parts[2], "\", \"", parts[3], "\");\n");
    }
    meta_text.append(m);
}

var cur_code: u8[>..];
var item_label_field: u8[>..];       // let ITEM_LABEL = "field"; of the view being generated, "" for none

// ---------------------------------------------------------------- everything

// Writes each view and returns the registry source (the file .gweb/views.goose), or "" when there are none.
fn gen() -> u8[>..] {
    var reg: u8[>..] = [];
    meta_text.clear();
    if views.len == 0 { return reg; }
    for &v in views {
        cur_code.clear();
        if !gen_view(v) { continue; }
        read(v.goose, cur_code);
        v.meta_s = meta_text.len;
        gen_meta(v, let_literal(cur_code, "LABEL"), view_slots);
        v.meta_e = meta_text.len;
    }
    if errors > 0 { return reg; }
    reg.append("// Generated by gweb. Do not edit; it is rewritten on every build.\nnamespace views;\n\nimport std;\nimport net.http;\nimport gweb;\nimport gweb.site.views;\nimport gweb.forms.valid;\n");
    for v in views { format(reg, "import ", v.ns, ";\nimport ", v.ns, "_html;\n"); }
    var i = 0;
    while i < views.len {
        let g = views[i].group;
        var j = i;
        while j < views.len && views[j].group == g { j += 1; }
        gen_group(reg, g, i, j);
        i = j;
    }
    return reg;
}

fn gen_group(m: u8[>..]&, g: const u8[:], a: i64, b: i64) {
    format(m, "\nlet ", g, "_NAMES = [");
    for k in a..b { if k > a { m.append(", "); } format(m, "\"", views[k].name, "\""); }
    m.append("];\n");
    format(m, "fn ", g, "_count() -> i64 { return ", b - a, "; }\n");
    format(m, "fn ", g, "_name(i: i64) -> const u8[:] { return ", g, "_NAMES[i]; }\n");
    format(m, "fn ", g, "_index(name: const u8[:]) -> i64 {\n    for n, i in ", g, "_NAMES { if n == name { return i; } }\n    return -1;\n}\n");
    format(m, "fn ", g, "_meta(i: i64) -> gweb::ViewMeta {\n    var m = gweb::ViewMeta { .. };\n    match i {\n");
    for k in a..b {
        format(m, "        ", k - a, " => {\n");
        m.append(meta_text[views[k].meta_s..views[k].meta_e]);
        m.append("        },\n");
    }
    m.append("        _ => {},\n    }\n    return m;\n}\n");
    // Z is passed after the arguments: views::g_render(out, req, ctx, name, json, doc, at, fill).
    format(m, "fn ", g, "_render<Z, D>(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&, name: const u8[:], props_json: const u8[:],\n",
           "                       doc: const D&, at: i64) -> bool {\n    let i = ", g, "_index(name);\n");
    for k in a..b {
        format(m, "    if i == ", k - a, " { var p = ", views[k].ns, "::Props { .. }; ", views[k].ns, "::read(props_json, p); ",
               views[k].ns, "::render(out, req, ctx, p, doc, at, Z); return true; }\n");
    }
    m.append("    return false;\n}\n");
    format(m, "fn ", g, "_defaults(name: const u8[:], out_json: u8[>..]&) -> bool {\n    let i = ", g, "_index(name);\n");
    for k in a..b { format(m, "    if i == ", k - a, " { ", views[k].ns, "::defaults(out_json); return true; }\n"); }
    m.append("    return false;\n}\n");
    format(m, "fn ", g, "_form(out: u8[>..]&, name: const u8[:], props_json: const u8[:], errs: const gweb::FieldErrors&, prefix: const u8[:]) -> bool {\n    let i = ", g, "_index(name);\n");
    for k in a..b { format(m, "    if i == ", k - a, " { ", views[k].ns, "::form(out, props_json, errs, prefix); return true; }\n"); }
    m.append("    return false;\n}\n");
    format(m, "fn ", g, "_form_req(out: u8[>..]&, req: const http::Request&, name: const u8[:], props_json: const u8[:], errs: const gweb::FieldErrors&, prefix: const u8[:]) -> bool {\n    let i = ", g, "_index(name);\n");
    for k in a..b { format(m, "    if i == ", k - a, " { ", views[k].ns, "::form_req(out, req, props_json, errs, prefix); return true; }\n"); }
    m.append("    return false;\n}\n");
    format(m, "fn ", g, "_parse(req: const http::Request&, name: const u8[:], prefix: const u8[:], out_json: u8[>..]&, errs: gweb::FieldErrors&) -> bool {\n    let i = ", g, "_index(name);\n");
    for k in a..b { format(m, "    if i == ", k - a, " { return ", views[k].ns, "::parse(req, prefix, out_json, errs); }\n"); }
    m.append("    gweb::add_error(errs, \"\", \"Unknown view.\");\n    return false;\n}\n");
}
