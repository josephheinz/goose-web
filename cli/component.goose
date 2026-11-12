// component: the .gshtml component translator (DESIGN-ADDENDUM-3, E1-E3 and
// follow-up 1). gweb calls compile() once for each components/Name.gshtml.
//
// It writes two outputs from one source:
//   .gooseweb/Name.goose  line for line with the source: line 1 is the
//                         header, the script is copied as it is, the
//                         </script> line opens render, and each markup line
//                         is one Goose line. gw_check, gw_json and component
//                         follow the last source line.
//   _gw/Name.js           the browser module: every script function,
//                         render, zero and the component(...) call. Pretty (one
//                         statement per line, real names) or compact.
//
// The script is parsed into nodes, every expression gets a type (Int, Bool,
// Str, Struct, Array), and the JavaScript is written from the nodes. Goose
// compiles the copy itself, so the translator reports only what is outside
// the client subset (E3) and what it cannot type.

namespace component;

import std;

enum Kind { Int, Bool, Str, Struct, Array }

// A field of a struct in the block. cap is N for u8[..N]; struct_name is the
// struct (Struct) or the element struct (Array).
struct Field { name: u8[..64], kind: Kind, struct_name: u8[..64], cap: i64 }

// ---------------------------------------------------------------- types

let T_ERR = 0;       // unknown: an error was reported, or will be
let T_INT = 1;
let T_BOOL = 2;
let T_STR = 3;       // cap: N for u8[..N], 0 for any length
let T_STRUCT = 4;    // name: the struct
let T_ARRAY = 5;     // name: the element struct
let T_VOID = 6;

struct Ty { t: i64, name: u8[..64], cap: i64 }

fn ty(t: i64) -> Ty { Ty { t: t, name: "", cap: 0 } }

// ---------------------------------------------------------------- model

struct SDef { name: u8[..64], line: i64, first: i64, n: i64 }

struct Param { name: u8[..64], ty: Ty, mref: bool, tok: i64, var_id: i64 }

struct FnDef { name: u8[..64], tok: i64, line: i64, first: i64, n: i64, ret: Ty, body: i64,
               js: u8[..72], handler: bool, test: bool }

// A variable in client code; js is its JavaScript name.
struct Var { name: u8[..64], ty: Ty, js: u8[..72] }

// Tokens: offsets into text.
let K_EOF = 0;
let K_ID = 1;
let K_INT = 2;
let K_STR = 3;
let K_OP = 4;
let K_BAD = 5;       // m: 1 char literal, 2 raw string, 3 float, else the text itself

struct Tok { k: i64, s: i64, e: i64, line: i64, m: i64 }   // m: the matching brace

// Node kinds.
let E_INT = 1;
let E_BOOL = 2;
let E_STR = 3;
let E_NAME = 4;
let E_FIELD = 5;     // a.tok
let E_INDEX = 6;     // a[b]
let E_CALL = 7;      // tok(a, a.next, ...); d: second name of web::has; c: 1 for a.f(...)
let E_SLIT = 8;      // tok { a, a.next, ... }
let E_FINIT = 9;     // tok: a
let E_UN = 10;
let E_BIN = 11;
let E_IF = 12;       // if a { b } else { c }
let S_LET = 20;      // tok: name, a: init, b: 1 with a type (ty), c: 1 for var
let S_ASSIGN = 21;   // a tok b
let S_INCDEC = 22;
let S_IF = 23;       // a: cond, b: block, c: else block or S_IF
let S_FOR = 24;      // tok: x, d: index name, a: iter, b: range end, c: body
let S_WHILE = 25;
let S_RETURN = 26;
let S_BREAK = 27;
let S_CONTINUE = 28;
let S_EXPR = 29;
let S_RESULT = 30;   // the block's value
let S_BLOCK = 31;    // a: first statement

// E_CALL ref for the whitelisted functions; user functions are >= 0.
let B_NONE = -1;
let B_MIN = -2;
let B_MAX = -3;
let B_ABS = -4;
let B_STR = -5;
let B_HAS = -6;
let B_PUSH = -7;
let B_REMOVE_AT = -8;
let B_CLEAR = -9;
let B_APPEND = -10;

struct Node {
    k: i64, tok: i64, line: i64,
    a: i64, b: i64, c: i64, d: i64, next: i64,   // children, -1 for none
    t0: i64, t1: i64,                            // first and last token
    ref: i64, ref2: i64,                         // variables or the function
    tv: i64,                                     // S_FOR: the loop bound's temporary
    ty: Ty
}

// The runtime helpers, in the order of the import line.
let HELPERS = ["component", "esc", "at", "set", "rm", "blen", "cap", "idiv", "imod"];
let H_COMPONENT = 0;
let H_ESC = 1;
let H_AT = 2;
let H_SET = 3;
let H_RM = 4;
let H_BLEN = 5;
let H_CAP = 6;
let H_IDIV = 7;
let H_IMOD = 8;

let JS_RESERVED = ["await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                   "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function",
                   "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null",
                   "package", "private", "protected", "public", "return", "static", "super", "switch", "this",
                   "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "arguments", "eval"];

// Names a pretty-mode JavaScript name may not take: the imports, the
// module's own functions and the globals the output uses.
let JS_TAKEN = ["component", "esc", "at", "set", "rm", "blen", "cap", "idiv", "imod", "render", "zero",
                "Math", "JSON", "structuredClone", "undefined", "NaN", "Infinity", "Object", "String", "Number"];

let GOOSE_KW = ["import", "namespace", "struct", "enum", "type", "fn", "thread_fn", "export", "simd", "recursive",
                "let", "var", "extern", "const", "pad", "reusable", "if", "else", "while", "for", "in", "loop",
                "block", "guard", "defer", "match", "return", "break", "continue", "as", "true", "false", "null",
                "self", "bool", "varint", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"];

let WHITELIST = "(min, max, abs, str, web::has, push, remove_at, clear, append, len)";

// ---------------------------------------------------------------- state (reset by compile)

var text: u8[>..];             // the source
var line_start: i64[>..<];     // offset of each line in text
var line_end: i64[>..<];       // offset of its '\n' (or the end)
var toks: Tok[>..<];
var nodes: Node[>..<];
var structs: SDef[>..<];
var fields: Field[>..<];
var field_lines: i64[>..<];
var fns: FnDef[>..<];
var params: Param[>..<];
var vars: Var[>..<];
var scope: i64[>..<];          // the variables in scope, innermost last
var used: u8[..72][>..<];      // pretty JavaScript names taken in the current function
var pos = 0;                   // the parser's token
var perr = false;              // the parser stopped at something it reported
var nerr = 0;
var errs_buf: u8[>..];
var src_path: u8[..512];
var isl: u8[..64];             // the component's name
var compact = false;
var js: u8[>..];               // the module body
var ind = 0;
var fcount = 0;                // the next compact name in the current function
var mbase = 0;                 // the first compact name a function's locals may take
var tmp_count = 0;             // pretty loop temporaries: $1, $2, ...
var helper_used: bool[9];
var helper_js: u8[..16][9];
var render_js: u8[..8];
var zero_js: u8[..8];
var ty_ref = false;            // parse_type: the type ended with &
var ty_const = false;          // parse_type: the type started with const
var ty_s = 0;                  // parse_type: its first token
var ty_e = 0;                  // parse_type: the token after it

// Markup state.
struct Open { kind: u8, line: i64, mark: i64 }
var opens: Open[>..<];
var pend: u8[>..];             // markup text not yet written to the JS
var cat_open = false;          // an `o += ...` statement is open in the JS
var cat_first = true;
var o_js: u8[..72];            // render's string in the JS
var s_var = -1;                // render's state variable
var gtext: u8[>..];            // markup text not yet written to the Goose line
var gline: u8[>..];            // the Goose line being built
var chk: u8[>..];              // the body of gw_check

// ---------------------------------------------------------------- errors

fn report(line: i64, msg: const u8[:]) {
    format(errs_buf, src_path, ":", line, ": error: ", msg, "\n");
    nerr += 1;
}

fn not_available(line: i64, what: const u8[:]) {
    var m: u8[>..] = [];
    format(m, "'", what, "' is not available in client code (components v1)");
    report(line, m);
}

fn cannot_type(line: i64) { report(line, "cannot tell the type of this expression; add a type to the let"); }

fn not_whitelisted(line: i64, name: const u8[:]) {
    var m: u8[>..] = [];
    format(m, "'", name, "' is not on the client whitelist ", WHITELIST);
    report(line, m);
}

// The parser stops at the first thing it cannot take: report it once.
fn bad_what(line: i64, what: const u8[:]) {
    if perr { return; }
    perr = true;
    not_available(line, what);
}

fn bad_tok(i: i64) {
    if perr { return; }
    let t = toks[i];
    if t.k == K_EOF {
        perr = true;
        report(t.line, "unexpected end of the <script goose> block");
        return;
    }
    if t.k == K_BAD {
        if t.m == 1 { bad_what(t.line, "char literal"); }
        else if t.m == 2 { bad_what(t.line, "raw string"); }
        else if t.m == 3 { bad_what(t.line, "f64"); }
        else { bad_what(t.line, text[t.s..t.e]); }
        return;
    }
    bad_what(t.line, text[t.s..t.e]);
}

// ---------------------------------------------------------------- small helpers

fn in_list(s: const u8[:], list: const u8[:][:]) -> bool {
    for x in list { if x == s { return true; } }
    return false;
}

fn tok_is(i: i64, s: const u8[:]) -> bool {
    let t = toks[i];
    return t.e - t.s == s.len && text[t.s..t.e] == s;
}

fn tok_name(i: i64) -> u8[..64] {
    var r: u8[..64] = "";
    let t = toks[i];
    r.append(text[t.s..min(t.e, t.s + 64)]);
    return r;
}

fn is_keyword(i: i64) -> bool {
    let t = toks[i];
    return t.k == K_ID && in_list(text[t.s..t.e], GOOSE_KW);
}

// The current token is p (an operator or a word).
fn is(p: const u8[:]) -> bool {
    let t = toks[pos];
    return (t.k == K_OP || t.k == K_ID) && t.e - t.s == p.len && text[t.s..t.e] == p;
}

fn at_k(k: i64) -> bool { toks[pos].k == k }

fn accept(p: const u8[:]) -> bool {
    if is(p) { pos += 1; return true; }
    return false;
}

fn expect(p: const u8[:]) -> bool {
    if is(p) { pos += 1; return true; }
    bad_tok(pos);
    return false;
}

fn is_alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn is_dig(c: u8) -> bool { c >= '0' && c <= '9' }
fn is_hexd(c: u8) -> bool { is_dig(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

// Appends s as the inside of a Goose string literal.
fn glit(out: u8[>..]&, s: const u8[:]) {
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

fn find_struct(name: const u8[:]) -> i64 {
    for s, i in structs { if s.name == name { return i; } }
    return -1;
}

fn find_fn(name: const u8[:]) -> i64 {
    for f, i in fns { if f.name == name { return i; } }
    return -1;
}

fn find_field(si: i64, name: const u8[:]) -> i64 {
    if si < 0 { return -1; }
    let first = structs[si].first;
    for k in structs[si].n {
        if fields[first + k].name == name { return first + k; }
    }
    return -1;
}

fn field_ty(fi: i64) -> Ty {
    var r = ty(T_ERR);
    let f = fields[fi];
    match f.kind {
        Int => { r.t = T_INT; },
        Bool => { r.t = T_BOOL; },
        Str => { r.t = T_STR; r.cap = f.cap; },
        Struct => { r.t = T_STRUCT; r.name = f.struct_name; },
        Array => { r.t = T_ARRAY; r.name = f.struct_name; },
    }
    return r;
}

// A struct whose copy must be deep: it holds a struct or an array.
fn is_deep(name: const u8[:]) -> bool {
    let si = find_struct(name);
    if si < 0 { return false; }
    for k in structs[si].n {
        let kind = fields[structs[si].first + k].kind;
        if kind == Kind.Struct || kind == Kind.Array { return true; }
    }
    return false;
}

// The value of integer literal token i, or -1 when it is above 2^53.
fn int_value(i: i64) -> i64 {
    let t = toks[i];
    var v = 0;
    var base = 10;
    var p = t.s;
    if t.e - t.s > 2 && text[p] == '0' && (text[p + 1] == 'x' || text[p + 1] == 'X') { base = 16; p += 2; }
    while p < t.e {
        let c = text[p];
        p += 1;
        if c == '_' { continue; }
        var d = 0;
        if is_dig(c) { d = c - '0'; }
        else if c >= 'a' && c <= 'f' { d = c - 'a' + 10; }
        else { d = c - 'A' + 10; }
        v = v * base + d;
        if v > 9007199254740992 { return -1; }
    }
    return v;
}

// The byte length of string literal token i.
fn lit_bytes(i: i64) -> i64 {
    let t = toks[i];
    var n = 0;
    var p = t.s + 1;
    while p < t.e - 1 {
        if text[p] == '\\' { p += if text[p + 1] == 'x' { 4 } else { 2 }; } else { p += 1; }
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------- tokens

let OPS3 = ["<<=", ">>=", ".==", ".!="];
let OPS2 = ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "++", "--", "->", "::", "..",
            "=>", "<<", ">>", "&=", "|=", "^=", ".="];

fn push_tok(k: i64, s: i64, e: i64, line: i64, m: i64) {
    toks.push(Tok { k: k, s: s, e: e, line: line, m: m });
}

// Tokens of text[s..e], whose first line is line, ending with an EOF token.
// Returns the index of the first.
fn tokenize(s: i64, e: i64, line: i64) -> i64 {
    let first = toks.len;
    var i = s;
    var ln = line;
    while i < e {
        let c = text[i];
        if c == '\n' { ln += 1; i += 1; continue; }
        if c == ' ' || c == '\t' || c == '\r' { i += 1; continue; }
        let nx: u8 = if i + 1 < e { text[i + 1] } else { 0 };
        if c == '/' && nx == '/' {
            while i < e && text[i] != '\n' { i += 1; }
            continue;
        }
        if c == '/' && nx == '*' {
            var depth = 0;
            while i < e {
                let d = text[i];
                let d2: u8 = if i + 1 < e { text[i + 1] } else { 0 };
                if d == '\n' { ln += 1; i += 1; }
                else if d == '/' && d2 == '*' { depth += 1; i += 2; }
                else if d == '*' && d2 == '/' { depth -= 1; i += 2; if depth == 0 { break; } }
                else { i += 1; }
            }
            continue;
        }
        let start = i;
        if is_alpha(c) {
            while i < e && (is_alpha(text[i]) || is_dig(text[i])) { i += 1; }
            push_tok(K_ID, start, i, ln, -1);
            continue;
        }
        if is_dig(c) {
            if c == '0' && (nx == 'x' || nx == 'X') {
                i += 2;
                while i < e && (is_hexd(text[i]) || text[i] == '_') { i += 1; }
            } else {
                while i < e && (is_dig(text[i]) || text[i] == '_') { i += 1; }
                var float = false;
                if i + 1 < e && text[i] == '.' && is_dig(text[i + 1]) { float = true; i += 1; }
                if i < e && (text[i] == 'e' || text[i] == 'E') { float = true; }
                if float {
                    while i < e && (is_alpha(text[i]) || is_dig(text[i]) || text[i] == '.' ||
                                    ((text[i] == '-' || text[i] == '+') && (text[i - 1] == 'e' || text[i - 1] == 'E'))) { i += 1; }
                    push_tok(K_BAD, start, i, ln, 3);
                    continue;
                }
            }
            if i < e && is_alpha(text[i]) {      // a suffix, as in 5u8
                while i < e && (is_alpha(text[i]) || is_dig(text[i])) { i += 1; }
                push_tok(K_BAD, start, i, ln, 0);
                continue;
            }
            push_tok(K_INT, start, i, ln, -1);
            continue;
        }
        if c == '"' {
            if nx == '"' && i + 2 < e && text[i + 2] == '"' {
                i += 3;
                while i < e && !(text[i] == '"' && i + 2 < e && text[i + 1] == '"' && text[i + 2] == '"') {
                    if text[i] == '\n' { ln += 1; }
                    i += 1;
                }
                i = min(i + 3, e);
                push_tok(K_BAD, start, i, ln, 2);
                continue;
            }
            i += 1;
            var bad_s = -1;
            var bad_e = -1;
            while i < e && text[i] != '"' && text[i] != '\n' {
                if text[i] == '\\' && i + 1 < e {
                    let x = text[i + 1];
                    if x == 'n' || x == 't' || x == 'r' || x == '\\' || x == '"' || x == '\'' { i += 2; continue; }
                    if x == 'x' && i + 3 < e && is_hexd(text[i + 2]) && is_hexd(text[i + 3]) && text[i + 2] <= '7' {
                        i += 4;
                        continue;
                    }
                    if bad_s < 0 { bad_s = i; bad_e = min(i + (if x == 'x' { 4 } else { 2 }), e); }
                    i += 2;
                    continue;
                }
                i += 1;
            }
            if i < e && text[i] == '"' { i += 1; }
            if bad_s >= 0 { push_tok(K_BAD, bad_s, bad_e, ln, 0); } else { push_tok(K_STR, start, i, ln, -1); }
            continue;
        }
        if c == '\'' {
            i += 1;
            while i < e && text[i] != '\'' && text[i] != '\n' { if text[i] == '\\' { i += 1; } i += 1; }
            if i < e && text[i] == '\'' { i += 1; }
            push_tok(K_BAD, start, min(i, e), ln, 1);
            continue;
        }
        var len = 1;
        for op in OPS3 { if len == 1 && i + 3 <= e && text[i..i + 3] == op { len = 3; } }
        if len == 1 { for op in OPS2 { if len == 1 && i + 2 <= e && text[i..i + 2] == op { len = 2; } } }
        i += len;
        push_tok(K_OP, start, i, ln, -1);
    }
    push_tok(K_EOF, e, e, ln, -1);
    // Match braces, so a declaration outside the subset can be skipped whole.
    var stack: i64[>..<] = [];
    for k in first..toks.len {
        if toks[k].k != K_OP { continue; }
        if tok_is(k, "{") { stack.push(k); }
        else if tok_is(k, "}") && stack.len > 0 {
            let o = stack[stack.len - 1];
            stack.pop();
            toks[o].m = k;
            toks[k].m = o;
        }
    }
    return first;
}

// ---------------------------------------------------------------- parser

fn new_node(k: i64, tok: i64) -> i64 {
    nodes.push(Node { k: k, tok: tok, line: toks[tok].line, a: -1, b: -1, c: -1, d: -1, next: -1,
                      t0: tok, t1: tok, ref: -1, ref2: -1, tv: -1, ty: ty(T_ERR) });
    return nodes.len - 1;
}

// The source text of node n.
fn span_s(n: i64) -> i64 { toks[nodes[n].t0].s }
fn span_e(n: i64) -> i64 { toks[nodes[n].t1].e }

// Reports the type at ty_s..ty_e as not available.
fn type_bad() {
    var e = max(ty_e, ty_s + 1);
    bad_what(toks[ty_s].line, text[toks[ty_s].s..toks[e - 1].e]);
}

// A type at pos. Sets ty_ref, ty_const and the span; reports a type
// outside the subset and returns T_ERR.
fn parse_type() -> Ty {
    var r = ty(T_ERR);
    ty_s = pos;
    ty_ref = false;
    ty_const = false;
    if is("const") { ty_const = true; pos += 1; }
    if is("i64") { pos += 1; r.t = T_INT; }
    else if is("bool") { pos += 1; r.t = T_BOOL; }
    else if is("u8") && tok_is(pos + 1, "[") {
        if tok_is(pos + 2, "..") && toks[pos + 3].k == K_INT && tok_is(pos + 4, "]") {
            r.t = T_STR;
            r.cap = int_value(pos + 3);
            pos += 5;
        } else if tok_is(pos + 2, ":") && tok_is(pos + 3, "]") {
            r.t = T_STR;
            pos += 4;
        } else {
            pos += 2;
            ty_e = pos;
            type_bad();
            return r;
        }
    }
    else if at_k(K_ID) && !is_keyword(pos) {
        r.t = T_STRUCT;
        r.name = tok_name(pos);
        pos += 1;
        if is("[") {
            if tok_is(pos + 1, ">") && tok_is(pos + 2, "..") && tok_is(pos + 3, "<") && tok_is(pos + 4, "]") { pos += 5; r.t = T_ARRAY; }
            else if tok_is(pos + 1, ">") && tok_is(pos + 2, "..") && tok_is(pos + 3, "]") { pos += 4; r.t = T_ARRAY; }
            else { pos += 1; ty_e = pos; type_bad(); r.t = T_ERR; return r; }
        }
    }
    else {
        pos += 1;
        ty_e = pos;
        type_bad();
        return r;
    }
    if is("&") { ty_ref = true; pos += 1; }
    if is("?") || is("[") || is("<") { pos += 1; ty_e = pos; type_bad(); r.t = T_ERR; return r; }
    ty_e = pos;
    return r;
}

recursive fn parse_expr(ns: bool) -> i64 { return parse_binary(0, ns); }

// The level of the binary operator at token i: 0 || ... 5 * / %, 9 one
// outside the subset, -1 none.
fn binop_level(i: i64) -> i64 {
    if toks[i].k != K_OP { return if tok_is(i, "as") { 9 } else { -1 }; }
    if tok_is(i, "||") { return 0; }
    if tok_is(i, "&&") { return 1; }
    if tok_is(i, "==") || tok_is(i, "!=") { return 2; }
    if tok_is(i, "<") || tok_is(i, "<=") || tok_is(i, ">") || tok_is(i, ">=") { return 3; }
    if tok_is(i, "+") || tok_is(i, "-") { return 4; }
    if tok_is(i, "*") || tok_is(i, "/") || tok_is(i, "%") { return 5; }
    if tok_is(i, "&") || tok_is(i, "|") || tok_is(i, "^") || tok_is(i, "<<") || tok_is(i, ">>") ||
       tok_is(i, ".==") || tok_is(i, ".!=") { return 9; }
    return -1;
}

recursive fn parse_binary(level: i64, ns: bool) -> i64 {
    if level == 6 { return parse_unary(ns); }
    var left = parse_binary(level + 1, ns);
    if perr { return -1; }
    loop {
        let l = binop_level(pos);
        if l == 9 { bad_tok(pos); return -1; }
        if l != level { break; }
        let op = pos;
        pos += 1;
        let right = parse_binary(level + 1, ns);
        if perr { return -1; }
        let n = new_node(E_BIN, op);
        nodes[n].a = left;
        nodes[n].b = right;
        nodes[n].t0 = nodes[left].t0;
        nodes[n].t1 = nodes[right].t1;
        left = n;
    }
    return left;
}

recursive fn parse_unary(ns: bool) -> i64 {
    if is("!") || is("-") {
        let op = pos;
        pos += 1;
        let a = parse_unary(ns);
        if perr { return -1; }
        let n = new_node(E_UN, op);
        nodes[n].a = a;
        nodes[n].t1 = nodes[a].t1;
        return n;
    }
    return parse_postfix(ns);
}

recursive fn parse_postfix(ns: bool) -> i64 {
    var e = parse_primary(ns);
    if perr { return -1; }
    loop {
        if is(".") {
            pos += 1;
            if !at_k(K_ID) { bad_tok(pos); return -1; }
            let name = pos;
            pos += 1;
            if is("(") {
                let n = new_node(E_CALL, name);
                nodes[n].a = e;
                nodes[n].c = 1;
                nodes[n].t0 = nodes[e].t0;
                if !parse_args(n, e, ns) { return -1; }
                e = n;
            } else {
                let n = new_node(E_FIELD, name);
                nodes[n].a = e;
                nodes[n].t0 = nodes[e].t0;
                e = n;
            }
            continue;
        }
        if is("[") {
            let open = pos;
            pos += 1;
            if is("..") { bad_what(toks[open].line, "a[x..y]"); return -1; }
            let i = parse_expr(false);
            if perr { return -1; }
            if is("..") { bad_what(toks[open].line, "a[x..y]"); return -1; }
            if !expect("]") { return -1; }
            let n = new_node(E_INDEX, open);
            nodes[n].a = e;
            nodes[n].b = i;
            nodes[n].t0 = nodes[e].t0;
            nodes[n].t1 = pos - 1;
            e = n;
            continue;
        }
        if is("as") || is("?") { bad_tok(pos); return -1; }
        break;
    }
    return e;
}

// The arguments of call n, after `last` (the receiver of a.f(...), or -1).
recursive fn parse_args(n: i64, last0: i64, ns: bool) -> bool {
    pos += 1;
    var last = last0;
    while !is(")") {
        let a = parse_expr(false);
        if perr { return false; }
        if last < 0 { nodes[n].a = a; } else { nodes[last].next = a; }
        last = a;
        if !accept(",") { break; }
    }
    if !expect(")") { return false; }
    nodes[n].t1 = pos - 1;
    if !ns && is("{") { bad_what(toks[pos].line, "closure"); return false; }
    return true;
}

recursive fn parse_struct_lit(name: i64) -> i64 {
    let n = new_node(E_SLIT, name);
    pos += 1;
    var last = -1;
    while !is("}") {
        if is("..") { bad_tok(pos); return -1; }
        if !at_k(K_ID) || !tok_is(pos + 1, ":") { bad_what(toks[pos].line, "a field value without its name"); return -1; }
        let f = new_node(E_FINIT, pos);
        pos += 2;
        let v = parse_expr(false);
        if perr { return -1; }
        nodes[f].a = v;
        if last < 0 { nodes[n].a = f; } else { nodes[last].next = f; }
        last = f;
        if !accept(",") { break; }
    }
    if !expect("}") { return -1; }
    nodes[n].t1 = pos - 1;
    return n;
}

recursive fn parse_if_expr() -> i64 {
    let n = new_node(E_IF, pos);
    pos += 1;
    let c = parse_expr(true);
    if perr { return -1; }
    if !expect("{") { return -1; }
    let a = parse_expr(false);
    if perr { return -1; }
    if !expect("}") { return -1; }
    if !expect("else") { return -1; }
    var b = -1;
    if is("if") {
        b = parse_if_expr();
        if perr { return -1; }
    } else {
        if !expect("{") { return -1; }
        b = parse_expr(false);
        if perr { return -1; }
        if !expect("}") { return -1; }
    }
    nodes[n].a = c;
    nodes[n].b = a;
    nodes[n].c = b;
    nodes[n].t1 = pos - 1;
    return n;
}

recursive fn parse_primary(ns: bool) -> i64 {
    let t = toks[pos];
    if t.k == K_INT {
        let n = new_node(E_INT, pos);
        pos += 1;
        if int_value(nodes[n].tok) < 0 { report(t.line, "integer literal is too large for client code (limit 2^53)"); }
        return n;
    }
    if t.k == K_STR {
        let n = new_node(E_STR, pos);
        pos += 1;
        return n;
    }
    if t.k != K_ID {
        if is("(") {
            let open = pos;
            pos += 1;
            let inner = parse_expr(false);
            if perr { return -1; }
            if !expect(")") { return -1; }
            nodes[inner].t0 = open;
            nodes[inner].t1 = pos - 1;
            return inner;
        }
        if is("{") { bad_what(t.line, "block"); return -1; }
        bad_tok(pos);
        return -1;
    }
    if is("true") || is("false") {
        let n = new_node(E_BOOL, pos);
        pos += 1;
        return n;
    }
    if is("if") { return parse_if_expr(); }
    if is_keyword(pos) { bad_tok(pos); return -1; }
    let name = pos;
    pos += 1;
    if is("::") {
        pos += 1;
        if !at_k(K_ID) || !tok_is(pos + 1, "(") { bad_tok(pos - 1); return -1; }
        let n = new_node(E_CALL, name);
        nodes[n].d = pos;
        pos += 1;
        if !parse_args(n, -1, ns) { return -1; }
        return n;
    }
    if is("<") && toks[pos + 1].k == K_ID && (tok_is(pos + 2, ">") || tok_is(pos + 2, ",")) {
        bad_what(t.line, "generics");
        return -1;
    }
    if is("(") {
        let n = new_node(E_CALL, name);
        if !parse_args(n, -1, ns) { return -1; }
        return n;
    }
    if is("{") && !ns { return parse_struct_lit(name); }
    return new_node(E_NAME, name);
}

recursive fn parse_block() -> i64 {
    let n = new_node(S_BLOCK, pos);
    if !expect("{") { return -1; }
    var last = -1;
    while !is("}") {
        if at_k(K_EOF) { bad_tok(pos); return -1; }
        if accept(";") { continue; }
        let s = parse_stmt();
        if perr { return -1; }
        if last < 0 { nodes[n].a = s; } else { nodes[last].next = s; }
        last = s;
    }
    pos += 1;
    nodes[n].t1 = pos - 1;
    return n;
}

recursive fn parse_if_stmt() -> i64 {
    let n = new_node(S_IF, pos);
    pos += 1;
    let c = parse_expr(true);
    if perr { return -1; }
    let b = parse_block();
    if perr { return -1; }
    nodes[n].a = c;
    nodes[n].b = b;
    if accept("else") {
        if is("if") {
            let e = parse_if_stmt();
            if perr { return -1; }
            nodes[n].c = e;
        } else {
            let e = parse_block();
            if perr { return -1; }
            nodes[n].c = e;
        }
    }
    return n;
}

// for x[, i] in e[..e2]: the header, after `for`, into node n. Shared by
// statements and {{#for}}.
recursive fn parse_for_head(n: i64) -> bool {
    if is("&") { bad_tok(pos); return false; }
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return false; }
    nodes[n].tok = pos;
    pos += 1;
    if accept(",") {
        if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return false; }
        nodes[n].d = pos;
        pos += 1;
    }
    if !expect("in") { return false; }
    let it = parse_expr(true);
    if perr { return false; }
    nodes[n].a = it;
    if accept("..") {
        let e2 = parse_expr(true);
        if perr { return false; }
        nodes[n].b = e2;
    }
    return true;
}

// let/var x[: T] = e, after the keyword, into node n (no `;`).
recursive fn parse_let_head(n: i64) -> bool {
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return false; }
    nodes[n].tok = pos;
    pos += 1;
    if is(",") { bad_tok(pos); return false; }
    if accept(":") {
        let t = parse_type();
        if perr { return false; }
        if ty_ref || t.t == T_ARRAY { type_bad(); return false; }
        nodes[n].ty = t;
        nodes[n].b = 1;
    }
    if !expect("=") { return false; }
    let e = parse_expr(false);
    if perr { return false; }
    nodes[n].a = e;
    return true;
}

recursive fn parse_stmt() -> i64 {
    let t = pos;
    let line = toks[t].line;
    if is("let") || is("var") {
        let n = new_node(S_LET, t);
        if is("var") { nodes[n].c = 1; }
        pos += 1;
        if !parse_let_head(n) { return -1; }
        if !expect(";") { return -1; }
        return n;
    }
    if is("if") { return parse_if_stmt(); }
    if is("for") {
        let n = new_node(S_FOR, t);
        pos += 1;
        if !parse_for_head(n) { return -1; }
        let body = parse_block();
        if perr { return -1; }
        nodes[n].c = body;
        return n;
    }
    if is("while") {
        let n = new_node(S_WHILE, t);
        pos += 1;
        let c = parse_expr(true);
        if perr { return -1; }
        let body = parse_block();
        if perr { return -1; }
        nodes[n].a = c;
        nodes[n].c = body;
        return n;
    }
    if is("return") {
        let n = new_node(S_RETURN, t);
        pos += 1;
        if !is(";") && !is("}") {
            let e = parse_expr(false);
            if perr { return -1; }
            nodes[n].a = e;
        }
        if !accept(";") && !is("}") { bad_tok(pos); return -1; }
        return n;
    }
    if is("break") || is("continue") {
        let n = new_node(if is("break") { S_BREAK } else { S_CONTINUE }, t);
        pos += 1;
        if !accept(";") && !is("}") { bad_tok(pos); return -1; }
        return n;
    }
    if is("{") { bad_what(line, "block"); return -1; }
    let e = parse_expr(false);
    if perr { return -1; }
    if is("=") || is("+=") || is("-=") || is("*=") || is("/=") || is("%=") {
        let n = new_node(S_ASSIGN, pos);
        pos += 1;
        let r = parse_expr(false);
        if perr { return -1; }
        nodes[n].a = e;
        nodes[n].b = r;
        nodes[n].line = line;
        if !expect(";") { return -1; }
        return n;
    }
    if is("++") || is("--") {
        let n = new_node(S_INCDEC, pos);
        pos += 1;
        nodes[n].a = e;
        nodes[n].line = line;
        if !expect(";") { return -1; }
        return n;
    }
    if accept(";") {
        let n = new_node(S_EXPR, t);
        nodes[n].a = e;
        return n;
    }
    if is("}") {
        let n = new_node(S_RESULT, t);
        nodes[n].a = e;
        return n;
    }
    bad_tok(pos);
    return -1;
}

fn parse_struct() {
    let line = toks[pos].line;
    pos += 1;
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
    let name_tok = pos;
    pos += 1;
    if is("<") { bad_what(line, "generics"); return; }
    if !expect("{") { return; }
    let si = structs.len;
    structs.push(SDef { name: tok_name(name_tok), line: line, first: fields.len, n: 0 });
    while !is("}") {
        if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
        let fname = pos;
        pos += 1;
        if !expect(":") { return; }
        let t = parse_type();
        if perr { return; }
        if ty_ref || ty_const || (t.t == T_STR && t.cap <= 0) { type_bad(); return; }
        if is("=") { bad_what(toks[pos].line, "field defaults"); return; }
        var f = Field { name: tok_name(fname), kind: Kind.Int, struct_name: "", cap: 0 };
        if t.t == T_BOOL { f.kind = Kind.Bool; }
        else if t.t == T_STR { f.kind = Kind.Str; f.cap = t.cap; }
        else if t.t == T_STRUCT { f.kind = Kind.Struct; f.struct_name = t.name; }
        else if t.t == T_ARRAY { f.kind = Kind.Array; f.struct_name = t.name; }
        fields.push(f);
        field_lines.push(toks[fname].line);
        structs[si].n += 1;
        if !accept(",") { break; }
    }
    expect("}");
}

fn check_reserved(tok: i64) {
    let t = toks[tok];
    let name = text[t.s..t.e];
    if in_list(name, JS_RESERVED) {
        var m: u8[>..] = [];
        format(m, "'", name, "' is a reserved word in JavaScript; rename it");
        report(t.line, m);
    }
}

fn parse_fn() {
    let line = toks[pos].line;
    pos += 1;
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
    let name_tok = pos;
    pos += 1;
    if is("<") { bad_what(line, "generics"); return; }
    if !expect("(") { return; }
    let fi = fns.len;
    fns.push(FnDef { name: tok_name(name_tok), tok: name_tok, line: line, first: params.len, n: 0,
                     ret: ty(T_VOID), body: -1, js: "", handler: false, test: false });
    check_reserved(name_tok);
    while !is(")") {
        if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
        let pn = pos;
        pos += 1;
        if !expect(":") { return; }
        let t = parse_type();
        if perr { return; }
        var ok = false;
        if (t.t == T_INT || t.t == T_BOOL) && !ty_ref && !ty_const { ok = true; }
        if t.t == T_STR && t.cap == 0 && ty_const && !ty_ref { ok = true; }
        if t.t == T_STRUCT && ty_ref && (ty_const || t.name == "State") { ok = true; }
        if !ok { type_bad(); return; }
        params.push(Param { name: tok_name(pn), ty: t, mref: ty_ref && !ty_const, tok: pn, var_id: -1 });
        fns[fi].n += 1;
        if !accept(",") { break; }
    }
    if !expect(")") { return; }
    if accept("->") {
        let t = parse_type();
        if perr { return; }
        if (t.t != T_INT && t.t != T_BOOL) || ty_ref || ty_const { type_bad(); return; }
        if is(",") { bad_tok(pos); return; }
        fns[fi].ret = t;
    }
    let b = parse_block();
    if perr { return; }
    fns[fi].body = b;
}

// After a declaration the parser stopped in: the token after it.
fn skip_decl(start: i64) {
    var i = start + 1;
    while toks[i].k != K_EOF {
        if tok_is(i, ";") { pos = i + 1; return; }
        if tok_is(i, "fn") || tok_is(i, "struct") { pos = i; return; }
        if tok_is(i, "{") {
            // An unclosed brace: nothing after it can be parsed.
            if toks[i].m < 0 {
                while toks[i].k != K_EOF { i += 1; }
                break;
            }
            pos = toks[i].m + 1;
            return;
        }
        i += 1;
    }
    pos = i;
}

// The script lines first_line..close-1 (0-based; the <script goose> line is
// before them) into structs and functions. False when it reported errors.
fn parse_script(first_line: i64, close: i64) -> bool {
    let before = nerr;
    pos = tokenize(line_start[first_line], line_start[close], first_line + 1);
    while !at_k(K_EOF) {
        let start = pos;
        perr = false;
        if is("struct") { parse_struct(); }
        else if is("fn") { parse_fn(); }
        else if is("let") || is("var") || is("const") { bad_what(toks[pos].line, "global"); }
        else { bad_tok(pos); }
        if perr {
            for &f in fns { if f.tok >= start { f.body = -1; } }
            skip_decl(start);
        }
    }
    perr = false;
    return nerr == before;
}

// ---------------------------------------------------------------- names

// The compact name number idx: a-z, A-Z, then two characters.
fn short_name(idx: i64) -> u8[..8] {
    let first = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let rest = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$";
    var r: u8[..8] = "";
    if idx < 52 { r.push(first[idx]); return r; }
    let k = idx - 52;
    r.push(first[(k / 64) % 52]);
    r.push(rest[k % 64]);
    return r;
}

fn next_short() -> u8[..8] {
    loop {
        let r = short_name(fcount);
        fcount += 1;
        if r != "do" && r != "if" && r != "in" { return r; }
    }
}

fn name_taken(c: const u8[:]) -> bool {
    if in_list(c, JS_TAKEN) { return true; }
    for f in fns { if f.js == c { return true; } }
    for u in used { if u == c { return true; } }
    return false;
}

// A pretty name for a local: the Goose name, or name$N when that is taken.
fn pick_name(base: const u8[:]) -> u8[..72] {
    var c: u8[..72] = "";
    c.append(base);
    var k = 1;
    while name_taken(c) {
        c.clear();
        format(c, base, "$", k);
        k += 1;
    }
    used.push(c);
    return c;
}

fn begin_fn() {
    scope.clear();
    used.clear();
    fcount = mbase;
    tmp_count = 0;
}

// A new variable named by token tok, in scope until its block ends.
fn declare(tok: i64, t: Ty) -> i64 {
    check_reserved(tok);
    var v = Var { name: tok_name(tok), ty: t, js: "" };
    if compact { v.js.append(next_short()); } else { v.js = pick_name(v.name); }
    vars.push(v);
    scope.push(vars.len - 1);
    return vars.len - 1;
}

// A JavaScript-only temporary (a loop bound).
fn temp_name() -> u8[..72] {
    var r: u8[..72] = "";
    if compact { r.append(next_short()); return r; }
    tmp_count += 1;
    format(r, "$", tmp_count);
    return r;
}

fn lookup(tok: i64) -> i64 {
    let t = toks[tok];
    let name = text[t.s..t.e];
    var k = scope.len;
    while k > 0 {
        k -= 1;
        if vars[scope[k]].name == name { return scope[k]; }
    }
    return -1;
}

// Names for the helpers, render, zero and every function.
fn assign_module_names() {
    for h in 9 {
        helper_js[h].clear();
        if compact { helper_js[h].append(short_name(h)); } else { helper_js[h].append(HELPERS[h]); }
        helper_used[h] = false;
    }
    render_js.clear();
    zero_js.clear();
    if compact { render_js.append(short_name(9)); zero_js.append(short_name(10)); }
    else { render_js.append("render"); zero_js.append("zero"); }
    for &f, i in fns {
        f.js.clear();
        if compact { f.js.append(short_name(11 + i)); }
        else {
            f.js.append(f.name);
            if in_list(f.js, JS_TAKEN) { f.js.push('$'); }
        }
    }
    mbase = 11 + fns.len;
}

// ---------------------------------------------------------------- types of expressions

fn same_ty(a: const Ty&, b: const Ty&) -> bool {
    if a.t != b.t { return false; }
    if a.t == T_STRUCT || a.t == T_ARRAY { return a.name == b.name; }
    return true;
}

fn args_count(n: i64) -> i64 {
    var k = 0;
    var a = nodes[n].a;
    while a >= 0 { k += 1; a = nodes[a].next; }
    return k;
}

fn arg_at(n: i64, i: i64) -> i64 {
    var a = nodes[n].a;
    for k in i { if a >= 0 { a = nodes[a].next; } }
    return a;
}

fn arg_t(n: i64, i: i64) -> i64 {
    let a = arg_at(n, i);
    return if a < 0 { -1 } else { nodes[a].ty.t };
}

// Whitelisted function number for name token i, or B_NONE.
fn builtin_of(i: i64) -> i64 {
    if tok_is(i, "min") { return B_MIN; }
    if tok_is(i, "max") { return B_MAX; }
    if tok_is(i, "abs") { return B_ABS; }
    if tok_is(i, "str") { return B_STR; }
    if tok_is(i, "push") { return B_PUSH; }
    if tok_is(i, "remove_at") { return B_REMOVE_AT; }
    if tok_is(i, "clear") { return B_CLEAR; }
    if tok_is(i, "append") { return B_APPEND; }
    return B_NONE;
}

// Sets the type of call n from its arguments' types.
fn type_call(n: i64) {
    let line = nodes[n].line;
    let r = nodes[n].ref;
    let na = args_count(n);
    var a = nodes[n].a;
    while a >= 0 { if nodes[a].ty.t == T_ERR { return; } a = nodes[a].next; }
    if r >= 0 {
        nodes[n].ty = fns[r].ret;
        return;
    }
    let t0 = arg_t(n, 0);
    let t1 = arg_t(n, 1);
    var ok = false;
    var res = ty(T_VOID);
    if r == B_MIN || r == B_MAX { ok = na == 2 && t0 == T_INT && t1 == T_INT; res = ty(T_INT); }
    else if r == B_ABS { ok = na == 1 && t0 == T_INT; res = ty(T_INT); }
    else if r == B_STR {
        ok = na > 0;
        var x = nodes[n].a;
        while x >= 0 {
            let t = nodes[x].ty.t;
            if t != T_INT && t != T_BOOL && t != T_STR { ok = false; }
            x = nodes[x].next;
        }
        res = ty(T_STR);
    }
    else if r == B_HAS { ok = na == 2 && t0 == T_STR && t1 == T_STR; res = ty(T_BOOL); }
    else if r == B_PUSH {
        ok = na == 2 && t0 == T_ARRAY && t1 == T_STRUCT && nodes[arg_at(n, 0)].ty.name == nodes[arg_at(n, 1)].ty.name;
    }
    else if r == B_REMOVE_AT { ok = na == 2 && t0 == T_ARRAY && t1 == T_INT; }
    else if r == B_CLEAR { ok = na == 1 && (t0 == T_STR || t0 == T_ARRAY); }
    else if r == B_APPEND { ok = na == 2 && t0 == T_STR && t1 == T_STR; }
    if !ok { cannot_type(line); return; }
    nodes[n].ty = res;
}

recursive fn check_expr(n: i64) {
    let k = nodes[n].k;
    let line = nodes[n].line;
    if k == E_INT { nodes[n].ty = ty(T_INT); return; }
    if k == E_BOOL { nodes[n].ty = ty(T_BOOL); return; }
    if k == E_STR { nodes[n].ty = ty(T_STR); return; }
    if k == E_NAME {
        let v = lookup(nodes[n].tok);
        if v < 0 { cannot_type(line); return; }
        nodes[n].ref = v;
        nodes[n].ty = vars[v].ty;
        return;
    }
    if k == E_FIELD {
        let a = nodes[n].a;
        check_expr(a);
        let at = nodes[a].ty;
        if at.t == T_ERR { return; }
        let f = nodes[n].tok;
        if tok_is(f, "len") && (at.t == T_STR || at.t == T_ARRAY) { nodes[n].ty = ty(T_INT); return; }
        if at.t == T_STRUCT {
            let fi = find_field(find_struct(at.name), text[toks[f].s..toks[f].e]);
            if fi >= 0 { nodes[n].ty = field_ty(fi); return; }
        }
        if at.t == T_STR || at.t == T_ARRAY { not_whitelisted(line, text[toks[f].s..toks[f].e]); return; }
        cannot_type(line);
        return;
    }
    if k == E_INDEX {
        let a = nodes[n].a;
        let b = nodes[n].b;
        check_expr(a);
        check_expr(b);
        let at = nodes[a].ty;
        if at.t == T_ERR || nodes[b].ty.t == T_ERR { return; }
        if at.t == T_STR { report(line, "string indexing is not available in client code; compare or append whole strings"); return; }
        if at.t != T_ARRAY || nodes[b].ty.t != T_INT { cannot_type(line); return; }
        var r = ty(T_STRUCT);
        r.name = at.name;
        nodes[n].ty = r;
        return;
    }
    if k == E_CALL {
        let tk = nodes[n].tok;
        if nodes[n].d >= 0 {
            if tok_is(tk, "web") && tok_is(nodes[n].d, "has") { nodes[n].ref = B_HAS; }
            else {
                var q: u8[..160] = "";
                q.append(tok_name(tk));
                q.append("::");
                q.append(tok_name(nodes[n].d));
                not_whitelisted(line, q);
                return;
            }
        } else {
            let fi = find_fn(text[toks[tk].s..toks[tk].e]);
            if fi >= 0 { nodes[n].ref = fi; }
            else {
                let b = builtin_of(tk);
                if b == B_NONE { not_whitelisted(line, text[toks[tk].s..toks[tk].e]); return; }
                nodes[n].ref = b;
            }
        }
        var a = nodes[n].a;
        while a >= 0 { check_expr(a); a = nodes[a].next; }
        type_call(n);
        return;
    }
    if k == E_SLIT {
        let si = find_struct(text[toks[nodes[n].tok].s..toks[nodes[n].tok].e]);
        var f = nodes[n].a;
        var bad = si < 0;
        while f >= 0 {
            let v = nodes[f].a;
            check_expr(v);
            if nodes[v].ty.t == T_ERR { bad = true; }
            let fi = find_field(si, text[toks[nodes[f].tok].s..toks[nodes[f].tok].e]);
            if fi < 0 { bad = true; } else { nodes[f].ty = field_ty(fi); }
            f = nodes[f].next;
        }
        if si < 0 { cannot_type(line); return; }
        if bad { return; }
        var r = ty(T_STRUCT);
        r.name = structs[si].name;
        nodes[n].ty = r;
        return;
    }
    if k == E_UN {
        let a = nodes[n].a;
        check_expr(a);
        let t = nodes[a].ty.t;
        if t == T_ERR { return; }
        let want = if tok_is(nodes[n].tok, "!") { T_BOOL } else { T_INT };
        if t != want { cannot_type(line); return; }
        nodes[n].ty = ty(want);
        return;
    }
    if k == E_BIN {
        let a = nodes[n].a;
        let b = nodes[n].b;
        check_expr(a);
        check_expr(b);
        let ta = nodes[a].ty.t;
        let tb = nodes[b].ty.t;
        if ta == T_ERR || tb == T_ERR { return; }
        let op = nodes[n].tok;
        let lv = binop_level(op);
        if lv == 2 {
            if ta == T_STRUCT || ta == T_ARRAY || tb == T_STRUCT || tb == T_ARRAY {
                report(line, "comparing structs is not available in client code");
                return;
            }
            if ta != tb || ta == T_VOID { cannot_type(line); return; }
            nodes[n].ty = ty(T_BOOL);
            return;
        }
        if lv == 0 || lv == 1 {
            if ta != T_BOOL || tb != T_BOOL { cannot_type(line); return; }
            nodes[n].ty = ty(T_BOOL);
            return;
        }
        if ta != T_INT || tb != T_INT { cannot_type(line); return; }
        nodes[n].ty = ty(if lv == 3 { T_BOOL } else { T_INT });
        return;
    }
    if k == E_IF {
        let c = nodes[n].a;
        let a = nodes[n].b;
        let b = nodes[n].c;
        check_expr(c);
        check_expr(a);
        check_expr(b);
        if nodes[c].ty.t == T_ERR || nodes[a].ty.t == T_ERR || nodes[b].ty.t == T_ERR { return; }
        let ta = nodes[a].ty;
        let tb = nodes[b].ty;
        if nodes[c].ty.t != T_BOOL || !same_ty(ta, tb) || ta.t == T_VOID { cannot_type(line); return; }
        var r = ta;
        if r.t == T_STR && (ta.cap == 0 || tb.cap == 0) { r.cap = 0; }
        else if r.t == T_STR { r.cap = max(ta.cap, tb.cap); }
        nodes[n].ty = r;
        return;
    }
    cannot_type(line);
}

// A value the program reads: an error unless it has a type.
fn want_value(n: i64) -> bool {
    let t = nodes[n].ty.t;
    if t == T_ERR { return false; }
    if t == T_VOID { cannot_type(nodes[n].line); return false; }
    return true;
}

fn is_lvalue(n: i64) -> bool {
    let k = nodes[n].k;
    return k == E_NAME || k == E_FIELD || k == E_INDEX;
}

// The variables of a for header in node n (statement or {{#for}}).
fn check_for_head(n: i64) {
    let it = nodes[n].a;
    check_expr(it);
    let line = nodes[n].line;
    var xt = ty(T_ERR);
    let t = nodes[it].ty;
    if nodes[n].b >= 0 {
        check_expr(nodes[n].b);
        let t2 = nodes[nodes[n].b].ty.t;
        if t.t != T_ERR && t2 != T_ERR {
            if t.t != T_INT || t2 != T_INT || nodes[n].d >= 0 { cannot_type(line); } else { xt = ty(T_INT); }
        }
    } else if t.t == T_INT && nodes[n].d < 0 {
        xt = ty(T_INT);
    } else if t.t == T_ARRAY {
        xt = ty(T_STRUCT);
        xt.name = t.name;
    } else if t.t != T_ERR {
        cannot_type(line);
    }
    nodes[n].ref = declare(nodes[n].tok, xt);
    if nodes[n].d >= 0 { nodes[n].ref2 = declare(nodes[n].d, ty(T_INT)); }
    if nodes[n].b >= 0 || t.t == T_INT {
        var v = Var { name: "", ty: ty(T_INT), js: "" };
        v.js = temp_name();
        vars.push(v);
        nodes[n].tv = vars.len - 1;
    }
}

fn check_let(n: i64) {
    let a = nodes[n].a;
    check_expr(a);
    var t = nodes[a].ty;
    if t.t == T_VOID { cannot_type(nodes[n].line); t = ty(T_ERR); }
    if nodes[n].b == 1 { t = nodes[n].ty; } else { nodes[n].ty = t; }
    nodes[n].ref = declare(nodes[n].tok, t);
}

recursive fn check_block(n: i64) {
    let mark = scope.len;
    var s = nodes[n].a;
    while s >= 0 {
        check_stmt(s);
        s = nodes[s].next;
    }
    scope.resize(mark);
}

recursive fn check_stmt(n: i64) {
    let k = nodes[n].k;
    let line = nodes[n].line;
    if k == S_LET { check_let(n); return; }
    if k == S_ASSIGN {
        let a = nodes[n].a;
        let b = nodes[n].b;
        check_expr(a);
        check_expr(b);
        if !is_lvalue(a) { cannot_type(line); return; }
        let ta = nodes[a].ty.t;
        let tb = nodes[b].ty.t;
        if ta == T_ERR || tb == T_ERR { return; }
        if tb == T_VOID { cannot_type(line); return; }
        if !tok_is(nodes[n].tok, "=") && (ta != T_INT || tb != T_INT) { cannot_type(line); }
        return;
    }
    if k == S_INCDEC {
        let a = nodes[n].a;
        check_expr(a);
        let ta = nodes[a].ty.t;
        if ta != T_ERR && (ta != T_INT || !is_lvalue(a)) { cannot_type(line); }
        return;
    }
    if k == S_IF {
        let c = nodes[n].a;
        check_expr(c);
        if nodes[c].ty.t != T_ERR && nodes[c].ty.t != T_BOOL { cannot_type(line); }
        check_block(nodes[n].b);
        let e = nodes[n].c;
        if e >= 0 {
            if nodes[e].k == S_IF { check_stmt(e); } else { check_block(e); }
        }
        return;
    }
    if k == S_FOR {
        let mark = scope.len;
        check_for_head(n);
        check_block(nodes[n].c);
        scope.resize(mark);
        return;
    }
    if k == S_WHILE {
        let c = nodes[n].a;
        check_expr(c);
        if nodes[c].ty.t != T_ERR && nodes[c].ty.t != T_BOOL { cannot_type(line); }
        check_block(nodes[n].c);
        return;
    }
    if k == S_RETURN || k == S_RESULT {
        let a = nodes[n].a;
        if a >= 0 { check_expr(a); want_value(a); }
        return;
    }
    if k == S_EXPR {
        check_expr(nodes[n].a);
        return;
    }
}

fn check_fn(fi: i64) {
    begin_fn();
    let f = fns[fi];
    for p in f.first..f.first + f.n {
        params[p].var_id = declare(params[p].tok, params[p].ty);
    }
    if f.body >= 0 { check_block(f.body); }
}

// ---------------------------------------------------------------- JavaScript

fn w(s: const u8[:]) { js.append(s); }

// Closes a block; compact mode drops the `;` before it.
fn close_brace() {
    if compact && js.len > 0 && js[js.len - 1] == ';' { js.pop(); }
    w("}");
}

// true and false (compact: !0 and !1).
fn w_bool(v: bool) {
    if compact { w(if v { "!0" } else { "!1" }); } else { w(if v { "true" } else { "false" }); }
}

// An operator or separator with spaces in pretty mode, without in compact.
// In compact mode a space stays only between two name characters.
fn wo(s: const u8[:]) {
    if !compact { js.append(s); return; }
    for c, i in s {
        if c != ' ' { js.push(c); continue; }
        let prev_name = js.len > 0 && (is_alpha(js[js.len - 1]) || is_dig(js[js.len - 1]) || js[js.len - 1] == '$');
        let next_name = i + 1 >= s.len || is_alpha(s[i + 1]) || is_dig(s[i + 1]);
        if prev_name && next_name { js.push(' '); }
    }
}

fn nl() {
    if compact { return; }
    js.push('\n');
    for k in ind { js.append("  "); }
}

fn helper(h: i64) {
    helper_used[h] = true;
    js.append(helper_js[h]);
}

fn w_tok(i: i64) { js.append(text[toks[i].s..toks[i].e]); }

fn w_var(v: i64) { js.append(vars[v].js); }

// A JavaScript string literal for s.
fn js_str(s: const u8[:]) {
    let hex = "0123456789abcdef";
    js.push('"');
    for c in s {
        if c == '"' { js.append("\\\""); }
        else if c == '\\' { js.append("\\\\"); }
        else if c == '\n' { js.append("\\n"); }
        else if c == '\r' { js.append("\\r"); }
        else if c == '\t' { js.append("\\t"); }
        else if c < 32 || c == 127 { js.append("\\x"); js.push(hex[c >> 4]); js.push(hex[c & 15]); }
        else { js.push(c); }
    }
    js.push('"');
}

// An expression. top: the context delimits it, so a binary operation needs
// no parentheses of its own.
recursive fn emit_expr(n: i64, top: bool) {
    let k = nodes[n].k;
    if k == E_INT || k == E_STR { w_tok(nodes[n].tok); return; }
    if k == E_BOOL { w_bool(tok_is(nodes[n].tok, "true")); return; }
    if k == E_NAME { w_var(nodes[n].ref); return; }
    if k == E_FIELD {
        let a = nodes[n].a;
        let at = nodes[a].ty.t;
        if tok_is(nodes[n].tok, "len") && at == T_STR {
            helper(H_BLEN);
            w("(");
            emit_expr(a, true);
            w(")");
            return;
        }
        emit_expr(a, false);
        if tok_is(nodes[n].tok, "len") && at == T_ARRAY { w(".length"); return; }
        w(".");
        w_tok(nodes[n].tok);
        return;
    }
    if k == E_INDEX {
        helper(H_AT);
        w("(");
        emit_expr(nodes[n].a, true);
        wo(", ");
        emit_expr(nodes[n].b, true);
        w(")");
        return;
    }
    if k == E_CALL { emit_call(n, top); return; }
    if k == E_SLIT {
        w("{");
        var f = nodes[n].a;
        var first = true;
        while f >= 0 {
            if !first { w(","); }
            if !compact { w(" "); }
            first = false;
            w_tok(nodes[f].tok);
            wo(": ");
            emit_val(nodes[f].a, nodes[f].ty);
            f = nodes[f].next;
        }
        if !compact && !first { w(" "); }
        w("}");
        return;
    }
    if k == E_UN {
        if !top { w("("); }
        w_tok(nodes[n].tok);
        emit_expr(nodes[n].a, false);
        if !top { w(")"); }
        return;
    }
    if k == E_BIN {
        let op = nodes[n].tok;
        if tok_is(op, "/") || tok_is(op, "%") {
            helper(if tok_is(op, "/") { H_IDIV } else { H_IMOD });
            w("(");
            emit_expr(nodes[n].a, true);
            wo(", ");
            emit_expr(nodes[n].b, true);
            w(")");
            return;
        }
        if !top { w("("); }
        emit_expr(nodes[n].a, false);
        if tok_is(op, "==") { wo(" === "); }
        else if tok_is(op, "!=") { wo(" !== "); }
        else {
            if !compact { w(" "); }
            w_tok(op);
            if !compact { w(" "); }
        }
        emit_expr(nodes[n].b, false);
        if !top { w(")"); }
        return;
    }
    if k == E_IF {
        w("(");
        emit_expr(nodes[n].a, false);
        wo(" ? ");
        emit_expr(nodes[n].b, false);
        wo(" : ");
        emit_expr(nodes[n].c, false);
        w(")");
        return;
    }
}

recursive fn emit_args(n: i64) {
    var a = nodes[n].a;
    var first = true;
    while a >= 0 {
        if !first { wo(", "); }
        first = false;
        emit_expr(a, true);
        a = nodes[a].next;
    }
}

recursive fn emit_call(n: i64, top: bool) {
    let r = nodes[n].ref;
    if r >= 0 {
        w(fns[r].js);
        w("(");
        emit_args(n);
        w(")");
        return;
    }
    if r == B_MIN || r == B_MAX || r == B_ABS {
        w(if r == B_MIN { "Math.min(" } else if r == B_MAX { "Math.max(" } else { "Math.abs(" });
        emit_args(n);
        w(")");
        return;
    }
    if r == B_STR {
        if !top { w("("); }
        w("\"\"");
        var a = nodes[n].a;
        while a >= 0 {
            wo(" + ");
            emit_expr(a, false);
            a = nodes[a].next;
        }
        if !top { w(")"); }
        return;
    }
    if r == B_HAS {
        emit_expr(arg_at(n, 0), false);
        w(".includes(");
        emit_expr(arg_at(n, 1), true);
        w(")");
        return;
    }
}

// Node n's value, stored into a slot of type target: structs are copied,
// and a string going into u8[..N] is checked against N.
recursive fn emit_val(n: i64, target: Ty) {
    let nt = nodes[n].ty;
    if nt.t == T_STRUCT && nodes[n].k != E_SLIT {
        if is_deep(nt.name) {
            w("structuredClone(");
            emit_expr(n, true);
            w(")");
        } else {
            w("{...");
            emit_expr(n, true);
            w("}");
        }
        return;
    }
    if target.t == T_STR && target.cap > 0 {
        var fits = false;
        if nt.t == T_STR && nt.cap > 0 && nt.cap <= target.cap { fits = true; }
        if nodes[n].k == E_STR && lit_bytes(nodes[n].tok) <= target.cap { fits = true; }
        if !fits {
            helper(H_CAP);
            w("(");
            emit_expr(n, true);
            w(",");
            if !compact { w(" "); }
            format(js, target.cap);
            w(")");
            return;
        }
    }
    emit_expr(n, true);
}

// The header of a for loop, through its `{`.
fn emit_for_head(n: i64) {
    let x = nodes[n].ref;
    let it = nodes[n].a;
    if nodes[n].tv >= 0 {
        let tmp = vars[nodes[n].tv].js;
        wo("for (");
        w("let ");
        w_var(x);
        wo(" = ");
        if nodes[n].b >= 0 { emit_expr(it, true); } else { w("0"); }
        wo(", ");
        w(tmp);
        wo(" = ");
        emit_expr(if nodes[n].b >= 0 { nodes[n].b } else { it }, true);
        wo("; ");
        w_var(x);
        wo(" < ");
        w(tmp);
        wo("; ");
        w_var(x);
        w("++");
        wo(") {");
        return;
    }
    wo("for (");
    w("const ");
    if nodes[n].d >= 0 {
        w("[");
        w_var(nodes[n].ref2);
        wo(", ");
        w_var(x);
        w("] of ");
        emit_expr(it, false);
        w(".entries()");
    } else {
        w_var(x);
        w(" of ");
        emit_expr(it, false);
    }
    wo(") {");
}

recursive fn emit_block(n: i64) {
    ind += 1;
    var s = nodes[n].a;
    while s >= 0 {
        emit_stmt(s);
        s = nodes[s].next;
    }
    ind -= 1;
    nl();
    close_brace();
}

recursive fn emit_if(n: i64) {
    wo("if (");
    emit_expr(nodes[n].a, true);
    wo(") {");
    emit_block(nodes[n].b);
    let e = nodes[n].c;
    if e >= 0 {
        wo(" else ");
        if nodes[e].k == S_IF { emit_if(e); }
        else {
            w("{");
            emit_block(e);
        }
    }
}

recursive fn emit_stmt(n: i64) {
    let k = nodes[n].k;
    nl();
    if k == S_LET {
        w("let ");
        w_var(nodes[n].ref);
        wo(" = ");
        emit_val(nodes[n].a, nodes[n].ty);
        w(";");
        return;
    }
    if k == S_ASSIGN {
        let a = nodes[n].a;
        let b = nodes[n].b;
        let op = nodes[n].tok;
        if tok_is(op, "=") {
            if nodes[a].k == E_INDEX {
                helper(H_SET);
                w("(");
                emit_expr(nodes[a].a, true);
                wo(", ");
                emit_expr(nodes[a].b, true);
                wo(", ");
                emit_val(b, nodes[a].ty);
                w(");");
                return;
            }
            emit_expr(a, true);
            wo(" = ");
            emit_val(b, nodes[a].ty);
            w(";");
            return;
        }
        if tok_is(op, "/=") || tok_is(op, "%=") {
            emit_expr(a, true);
            wo(" = ");
            helper(if tok_is(op, "/=") { H_IDIV } else { H_IMOD });
            w("(");
            emit_expr(a, true);
            wo(", ");
            emit_expr(b, true);
            w(");");
            return;
        }
        emit_expr(a, true);
        if !compact { w(" "); }
        w_tok(op);
        if !compact { w(" "); }
        emit_expr(b, true);
        w(";");
        return;
    }
    if k == S_INCDEC {
        emit_expr(nodes[n].a, true);
        w_tok(nodes[n].tok);
        w(";");
        return;
    }
    if k == S_IF { emit_if(n); return; }
    if k == S_FOR {
        emit_for_head(n);
        emit_block(nodes[n].c);
        return;
    }
    if k == S_WHILE {
        wo("while (");
        emit_expr(nodes[n].a, true);
        wo(") {");
        emit_block(nodes[n].c);
        return;
    }
    if k == S_RETURN || k == S_RESULT {
        w("return");
        if nodes[n].a >= 0 {
            w(" ");
            emit_expr(nodes[n].a, true);
        }
        w(";");
        return;
    }
    if k == S_BREAK { w("break;"); return; }
    if k == S_CONTINUE { w("continue;"); return; }
    if k == S_EXPR {
        let e = nodes[n].a;
        if nodes[e].k == E_CALL && nodes[e].ref <= B_PUSH {
            emit_builtin_stmt(e);
            return;
        }
        emit_expr(e, true);
        w(";");
        return;
    }
}

// push, remove_at, clear and append, which change their first argument.
recursive fn emit_builtin_stmt(n: i64) {
    let r = nodes[n].ref;
    let a = arg_at(n, 0);
    let at = nodes[a].ty;
    if r == B_PUSH {
        emit_expr(a, false);
        w(".push(");
        var et = ty(T_STRUCT);
        et.name = at.name;
        emit_val(arg_at(n, 1), et);
        w(");");
        return;
    }
    if r == B_REMOVE_AT {
        helper(H_RM);
        w("(");
        emit_expr(a, true);
        wo(", ");
        emit_expr(arg_at(n, 1), true);
        w(");");
        return;
    }
    if r == B_CLEAR {
        emit_expr(a, true);
        if at.t == T_STR { wo(" = "); w("\"\";"); } else { w(".length"); wo(" = "); w("0;"); }
        return;
    }
    if r == B_APPEND {
        let x = arg_at(n, 1);
        emit_expr(a, true);
        if at.cap > 0 {
            wo(" = ");
            helper(H_CAP);
            w("(");
            emit_expr(a, true);
            wo(" + ");
            emit_expr(x, false);
            w(",");
            if !compact { w(" "); }
            format(js, at.cap);
            w(");");
        } else {
            wo(" += ");
            emit_expr(x, false);
            w(";");
        }
        return;
    }
}

// A comment naming the source line, above each function in pretty mode.
fn emit_line_note(line: i64) {
    if compact { return; }
    js.append("\n// ");
    js.append(src_path);
    format(js, ":", line, "\n");
}

// One parsed function.
fn emit_js_fn(i: i64) {
    let f = fns[i];
    emit_line_note(f.line);
    w("function ");
    w(f.js);
    w("(");
    for p in f.first..f.first + f.n {
        if p > f.first { wo(", "); }
        w_var(params[p].var_id);
    }
    wo(") {");
    emit_block(f.body);
    if !compact { w("\n"); }
}

// zero(): the state every field at its default, as State { .. } gives it.
recursive fn zero_obj(si: i64, depth: i64) {
    w("{");
    let first = structs[si].first;
    for k in structs[si].n {
        if k > 0 { w(","); }
        if !compact { w(" "); }
        let f = fields[first + k];
        js.append(f.name);
        wo(": ");
        match f.kind {
            Int => w("0"),
            Bool => w_bool(false),
            Str => w("\"\""),
            Array => w("[]"),
            Struct => {
                let sub = find_struct(f.struct_name);
                if sub >= 0 && depth < 16 { zero_obj(sub, depth + 1); } else { w("{}"); }
            },
        }
    }
    if !compact && structs[si].n > 0 { w(" "); }
    w("}");
}

fn emit_zero() {
    if !compact { w("\n"); }
    w("function ");
    w(zero_js);
    wo("() {");
    ind += 1;
    nl();
    w("return ");
    let si = find_struct("State");
    if si >= 0 { zero_obj(si, 0); } else { w("{}"); }
    w(";");
    ind -= 1;
    nl();
    close_brace();
    if !compact { w("\n"); }
}

// component("Name", { render, zero, handlers: {...}, tests: {...} });
fn emit_component_call() {
    if !compact { w("\n"); }
    helper(H_COMPONENT);
    w("(\"");
    js.append(isl);
    w("\",");
    wo(" { ");
    for which in 2 {
        if which == 0 {
            if compact { w("render:"); w(render_js); w(",zero:"); w(zero_js); }
            else { w("render, zero"); }
        }
        wo(", ");
        w(if which == 0 { "handlers" } else { "tests" });
        wo(": {");
        var first = true;
        for f in fns {
            if f.body < 0 { continue; }
            if (which == 0 && !f.handler) || (which == 1 && !f.test) { continue; }
            if !first { w(","); }
            if !compact { w(" "); }
            first = false;
            js.append(f.name);
            if f.js != f.name { wo(": "); js.append(f.js); }
        }
        if !compact && !first { w(" "); }
        w("}");
    }
    wo(" });");
    if !compact { w("\n"); }
}

// ---------------------------------------------------------------- markup

// Markup text for both outputs.
fn mtext(s: const u8[:]) {
    gtext.append(s);
    pend.append(s);
}

// Goose: writes pending text, then code.
fn g_flush() {
    if gtext.len > 0 {
        gline.append("out.append(\"");
        glit(gline, gtext);
        gline.append("\"); ");
        gtext.clear();
    }
}

fn g_code(s: const u8[:]) {
    g_flush();
    gline.append(s);
}

// JavaScript: `o += piece + piece ...;`
fn cat_start() {
    if cat_open { return; }
    nl();
    w(o_js);
    wo(" += ");
    cat_open = true;
    cat_first = true;
}

fn cat_plus() {
    if !cat_first { wo(" + "); }
    cat_first = false;
}

fn cat_pend() {
    if pend.len == 0 { return; }
    cat_start();
    cat_plus();
    js_str(pend);
    pend.clear();
}

fn cat_close() {
    cat_pend();
    if cat_open { w(";"); cat_open = false; }
}

// Before an expression piece. A raw piece first in the statement is
// prefixed with "" so + concatenates.
fn cat_expr(raw: bool) {
    cat_pend();
    cat_start();
    if cat_first && raw { w("\"\""); cat_first = false; }
    cat_plus();
}

// One gw_check line, tagged with its source line so gweb can map a
// compiler error in it back to the markup.
fn chk_line(s: const u8[:], line: i64) {
    chk.append(s);
    format(chk, "   // gw:line ", line, "\n");
}

// Tokenizes and parses the expression text[s..e]; -1 after an error.
fn parse_tag_expr(s: i64, e: i64, line: i64) -> i64 {
    pos = tokenize(s, e, line);
    perr = false;
    let n = parse_expr(false);
    if perr { perr = false; return -1; }
    if !at_k(K_EOF) { bad_tok(pos); perr = false; return -1; }
    return n;
}

// {{ e }} (raw: {{{ e }}}).
fn m_expr(s: i64, e: i64, line: i64, raw: bool) {
    g_flush();
    format(gline, if raw { "web::raw(out, " } else { "web::put(out, " }, text[s..e], "); ");
    let n = parse_tag_expr(s, e, line);
    if n < 0 { return; }
    check_expr(n);
    let t = nodes[n].ty.t;
    if t == T_ERR { return; }
    if t != T_INT && t != T_BOOL && t != T_STR { cannot_type(line); return; }
    cat_expr(raw);
    if raw { emit_expr(n, false); }
    else {
        helper(H_ESC);
        w("(");
        emit_expr(n, true);
        w(")");
    }
}

fn open_tag(kind: u8, line: i64) {
    opens.push(Open { kind: kind, line: line, mark: scope.len });
}

// {{#if c}} and {{#else if c}}.
fn m_if(s: i64, e: i64, line: i64, else_if: bool) {
    g_flush();
    var head: u8[>..] = [];
    format(head, if else_if { "} else if " } else { "if " }, text[s..e], " {");
    gline.append(head);
    gline.push(' ');
    chk_line(head, line);
    cat_close();
    if else_if {
        if opens.len == 0 || opens[opens.len - 1].kind != 'i' { report(line, "{{#else if}} outside {{#if}}"); return; }
        scope.resize(opens[opens.len - 1].mark);
        ind -= 1;
    } else {
        open_tag('i', line);
    }
    nl();
    if else_if { wo("} else if ("); } else { wo("if ("); }
    let n = parse_tag_expr(s, e, line);
    if n >= 0 {
        check_expr(n);
        let t = nodes[n].ty.t;
        if t != T_ERR && t != T_BOOL { cannot_type(line); }
        else if t == T_BOOL { emit_expr(n, true); }
    }
    wo(") {");
    ind += 1;
}

fn m_else(line: i64) {
    g_code("} else { ");
    chk_line("} else {", line);
    cat_close();
    if opens.len == 0 || opens[opens.len - 1].kind != 'i' { report(line, "{{#else}} outside {{#if}}"); return; }
    scope.resize(opens[opens.len - 1].mark);
    ind -= 1;
    nl();
    wo("} else {");
    ind += 1;
}

fn m_close(want: u8, line: i64) {
    g_code("} ");
    chk_line("}", line);
    cat_close();
    if opens.len == 0 || opens[opens.len - 1].kind != want {
        report(line, if want == 'i' { "{{/if}} does not close an open {{#if}}" } else { "{{/for}} does not close an open {{#for}}" });
        return;
    }
    scope.resize(opens[opens.len - 1].mark);
    opens.pop();
    ind -= 1;
    nl();
    close_brace();
}

fn m_for(s: i64, e: i64, line: i64) {
    g_flush();
    var head: u8[>..] = [];
    format(head, "for ", text[s..e], " {");
    gline.append(head);
    gline.push(' ');
    chk_line(head, line);
    cat_close();
    open_tag('f', line);
    pos = tokenize(s, e, line);
    perr = false;
    let n = new_node(S_FOR, pos);
    var ok = parse_for_head(n);
    if ok && !at_k(K_EOF) { bad_tok(pos); ok = false; }
    perr = false;
    nl();
    if ok {
        check_for_head(n);
        emit_for_head(n);
    } else {
        wo("for (;;) {");
    }
    ind += 1;
}

fn m_let(s: i64, e: i64, line: i64) {
    g_flush();
    var head: u8[>..] = [];
    format(head, "let ", text[s..e], ";");
    gline.append(head);
    gline.push(' ');
    chk_line(head, line);
    cat_close();
    pos = tokenize(s, e, line);
    perr = false;
    let n = new_node(S_LET, pos);
    var ok = parse_let_head(n);
    if ok && !at_k(K_EOF) { bad_tok(pos); ok = false; }
    perr = false;
    if !ok { return; }
    check_let(n);
    nl();
    w("let ");
    w_var(nodes[n].ref);
    wo(" = ");
    emit_val(nodes[n].a, nodes[n].ty);
    w(";");
}

// on:EVENT="name" or on:EVENT="name(a, b)"; value text[vs..ve].
fn m_on(event: const u8[:], vs: i64, ve: i64, line: i64) {
    let n = parse_tag_expr(vs, ve, line);
    if n < 0 { return; }
    var name_tok = -1;
    if nodes[n].k == E_NAME { name_tok = nodes[n].tok; }
    else if nodes[n].k == E_CALL && nodes[n].c != 1 && nodes[n].d < 0 { name_tok = nodes[n].tok; }
    var fi = -1;
    if name_tok >= 0 { fi = find_fn(text[toks[name_tok].s..toks[name_tok].e]); }
    if fi < 0 || fns[fi].n == 0 || !params[fns[fi].first].mref || params[fns[fi].first].ty.name != "State" {
        var m: u8[>..] = [];
        let shown = if name_tok >= 0 { text[toks[name_tok].s..toks[name_tok].e] } else { text[vs..ve] };
        format(m, "on:", event, " handler '", shown, "' is not a function taking s: State&");
        report(line, m);
        return;
    }
    let fname = text[toks[name_tok].s..toks[name_tok].e];
    var t: u8[>..] = [];
    format(t, "data-on-", event, "=\"", fname, "\"");
    mtext(t);
    var call: u8[>..] = [];
    format(call, fname, "(gw_w");
    if nodes[n].k == E_CALL && nodes[n].a >= 0 {
        mtext(" data-args=\"[");
        var a = nodes[n].a;
        var first = true;
        while a >= 0 {
            if !first { mtext(","); }
            first = false;
            let src = text[span_s(a)..span_e(a)];
            format(call, ", ", src);
            g_flush();
            format(gline, "web::arg(out, ", src, "); ");
            check_expr(a);
            let at = nodes[a].ty.t;
            if at != T_ERR && at != T_INT && at != T_BOOL && at != T_STR {
                var m: u8[>..] = [];
                format(m, "on:", event, " arguments must be i64, bool or strings");
                report(line, m);
            } else if at != T_ERR {
                cat_expr(false);
                helper(H_ESC);
                w("(");
                if at == T_STR { w("JSON.stringify("); emit_expr(a, true); w(")"); } else { emit_expr(a, true); }
                w(")");
            }
            a = nodes[a].next;
        }
        mtext("]\"");
    }
    call.append(");");
    chk_line(call, line);
}

// bind:value="field" or bind:checked="field".
fn m_bind(what: const u8[:], vs: i64, ve: i64, line: i64) {
    let field = trim(text[vs..ve]);
    let fi = find_field(find_struct("State"), field);
    var ok = fi >= 0;
    if ok {
        let kind = fields[fi].kind;
        if what == "checked" { ok = kind == Kind.Bool; }
        else { ok = kind == Kind.Int || kind == Kind.Bool || kind == Kind.Str; }
    }
    if !ok {
        if what == "checked" { report(line, "bind:checked needs a State field of type bool"); return; }
        var m: u8[>..] = [];
        format(m, "bind:", what, " needs a State field of type i64, bool or u8[..N]");
        report(line, m);
        return;
    }
    var code: u8[>..] = [];
    if what == "value" {
        mtext("value=\"");
        format(code, "web::put(out, s.", field, "); ");
        g_code(code);
        cat_expr(false);
        helper(H_ESC);
        w("(");
        w_var(s_var);
        w(".");
        w(field);
        w(")");
        var t: u8[>..] = [];
        format(t, "\" data-bind=\"", field, "\"");
        if fields[fi].kind == Kind.Str { format(t, " data-cap=\"", fields[fi].cap, "\""); }
        mtext(t);
        return;
    }
    // checked: {{#if s.field}}checked{{/if}} data-bind="field"
    format(code, "if s.", field, " { ");
    g_code(code);
    gtext.append("checked");
    g_code("} ");
    cat_close();
    nl();
    wo("if (");
    w_var(s_var);
    w(".");
    w(field);
    wo(") {");
    ind += 1;
    pend.append("checked");
    cat_close();
    ind -= 1;
    nl();
    close_brace();
    var t: u8[>..] = [];
    format(t, " data-bind=\"", field, "\"");
    mtext(t);
}

// The first on: or bind: attribute in text[p..e] that follows white space.
fn next_attr(p: i64, e: i64) -> i64 {
    for i in p..e {
        if i == 0 { continue; }
        let prev = text[i - 1];
        if prev != ' ' && prev != '\t' && prev != '\n' { continue; }
        if starts_with(text[i..e], "on:") || starts_with(text[i..e], "bind:") { return i; }
    }
    return -1;
}

// Markup text text[s..e] with its on: and bind: attributes rewritten. The value
// takes double or single quotes, so on:click='say("x")' works; there is no
// escape syntax, and the output attributes are always double-quoted.
fn m_text(s: i64, e: i64, line: i64) {
    var p = s;
    while p < e {
        let k = next_attr(p, e);
        if k < 0 { mtext(text[p..e]); return; }
        mtext(text[p..k]);
        let on = text[k] == 'o';
        let name_s = k + (if on { 3 } else { 5 });
        var q = name_s;
        while q < e && text[q] >= 'a' && text[q] <= 'z' { q += 1; }
        let quoted = q + 1 < e && text[q] == '=' && (text[q + 1] == '"' || text[q + 1] == '\'');
        var ve = q + 2;
        if quoted {
            let qc = text[q + 1];
            while ve < e && text[ve] != qc { ve += 1; }
        }
        if !quoted || ve >= e {
            report(line, "on: and bind: take a value in quotes on the same line");
            mtext(text[k..e]);
            return;
        }
        let name = text[name_s..q];
        if on {
            if name == "click" || name == "change" || name == "input" || name == "submit" { m_on(name, q + 2, ve, line); }
            else { not_available(line, text[k..q]); }
        } else {
            if name == "value" || name == "checked" { m_bind(name, q + 2, ve, line); }
            else { not_available(line, text[k..q]); }
        }
        p = ve + 1;
    }
}

// The trimmed text[s..e].
fn trim_s(s: i64, e: i64) -> i64 {
    var a = s;
    while a < e && (text[a] == ' ' || text[a] == '\t') { a += 1; }
    return a;
}

fn trim_e(s: i64, e: i64) -> i64 {
    var b = e;
    while b > s && (text[b - 1] == ' ' || text[b - 1] == '\t' || text[b - 1] == '\r') { b -= 1; }
    return b;
}

// One markup line (0-based li); writes its Goose line.
fn markup_line(li: i64, last: bool, goose_out: u8[>..]&) {
    let ln = li + 1;
    let le = line_end[li];
    gline.clear();
    gtext.clear();
    var p = line_start[li];
    while p < le {
        let k = find(text[p..le], "{{");
        if k < 0 { m_text(p, le, ln); break; }
        m_text(p, p + k, ln);
        let at = p + k;
        if starts_with(text[at..le], "{{--") {
            let e = find(text[at..le], "--}}");
            if e < 0 { report(ln, "{{-- needs --}} on the same line"); break; }
            p = at + e + 4;
            continue;
        }
        if starts_with(text[at..le], "{{{") {
            let e = find(text[at..le], "}}}");
            if e < 0 { report(ln, "{{{ needs }}} on the same line"); break; }
            let a = trim_s(at + 3, at + e);
            let b = trim_e(a, at + e);
            if a == b { report(ln, "empty {{{ }}}"); } else { m_expr(a, b, ln, true); }
            p = at + e + 3;
            continue;
        }
        let e = find(text[at..le], "}}");
        if e < 0 { report(ln, "{{ needs }} on the same line"); break; }
        let a = trim_s(at + 2, at + e);
        let b = trim_e(a, at + e);
        p = at + e + 2;
        let inner = text[a..b];
        if starts_with(inner, "#if ") { m_if(trim_s(a + 4, b), b, ln, false); }
        else if starts_with(inner, "#else if ") { m_if(trim_s(a + 9, b), b, ln, true); }
        else if inner == "#else" { m_else(ln); }
        else if starts_with(inner, "#for ") { m_for(trim_s(a + 5, b), b, ln); }
        else if starts_with(inner, "#let ") { m_let(trim_s(a + 5, b), b, ln); }
        else if inner == "/if" { m_close('i', ln); }
        else if inner == "/for" { m_close('f', ln); }
        else if starts_with(inner, "component ") || inner == "component" { not_available(ln, "{{component}}"); }
        else if inner == "slot" { not_available(ln, "{{slot}}"); }
        else if starts_with(inner, ">") { not_available(ln, "{{> f()}}"); }
        else if starts_with(inner, "#") || starts_with(inner, "/") {
            var m: u8[>..] = [];
            format(m, "unknown tag {{", inner, "}}");
            report(ln, m);
        }
        else if a == b { report(ln, "empty {{ }}"); }
        else { m_expr(a, b, ln, false); }
    }
    if !last { mtext("\n"); }
    g_flush();
    if last { gline.append("}"); }
    goose_out.append(gline);
    goose_out.push('\n');
    if !compact { cat_close(); }
}

// The markup lines first_line.. (0-based) into render: Goose lines, the JS
// render function, and gw_check's body in chk.
fn compile_markup(first_line: i64, render_line: i64, goose_out: u8[>..]&) {
    begin_fn();
    var st = ty(T_STRUCT);
    st.name.append("State");
    if compact {
        o_js.clear();
        o_js.append(next_short());
        var v = Var { name: "s", ty: st, js: "" };
        v.js.append(next_short());
        vars.push(v);
    } else {
        o_js.clear();
        o_js.append("o");
        used.push("o");
        var v = Var { name: "s", ty: st, js: "" };
        v.js = pick_name("s");
        vars.push(v);
    }
    s_var = vars.len - 1;
    scope.push(s_var);
    emit_line_note(render_line);
    w("function ");
    w(render_js);
    w("(");
    w_var(s_var);
    wo(") {");
    ind = 1;
    nl();
    w("let ");
    w(o_js);
    wo(" = ");
    w("\"\";");
    opens.clear();
    pend.clear();
    cat_open = false;
    let nl_count = line_start.len;
    for li in first_line..nl_count { markup_line(li, li == nl_count - 1, goose_out); }
    cat_close();
    if opens.len > 0 {
        let o = opens[opens.len - 1];
        report(o.line, if o.kind == 'i' { "{{#if}} is never closed with {{/if}}" } else { "{{#for}} is never closed with {{/for}}" });
    }
    ind = 1;
    nl();
    w("return ");
    w(o_js);
    w(";");
    ind = 0;
    nl();
    close_brace();
    if !compact { w("\n"); }
}

// gw_json: one overload per struct, the fields in declaration order.
fn emit_json_writer(out: u8[>..]&) {
    for sd in structs {
        format(out, "fn gw_json(out: u8[>..]&, s: const ", sd.name, "&) { ");
        for k in sd.n {
            let f = fields[sd.first + k];
            format(out, "out.append(\"", if k == 0 { "{" } else { "," }, "\\\"", f.name, "\\\":\"); ");
            match f.kind {
                Int => format(out, "format(out, s.", f.name, "); "),
                Bool => format(out, "format(out, s.", f.name, "); "),
                Str => format(out, "web::json_text(out, s.", f.name, "); "),
                Struct => format(out, "gw_json(out, s.", f.name, "); "),
                Array => format(out, "out.push('['); for x, i in s.", f.name, " { if i > 0 { out.push(','); } gw_json(out, x); } out.push(']'); "),
            }
        }
        out.append(if sd.n == 0 { "out.append(\"{}\"); }\n" } else { "out.push('}'); }\n" });
    }
}

// Structural rules: State exists, and holds the only array, last.
fn check_structs() {
    let si = find_struct("State");
    if si < 0 { report(1, "a component needs struct State { ... } in its <script goose> block"); }
    for sd, i in structs {
        for k in sd.n {
            let fi = sd.first + k;
            if fields[fi].kind != Kind.Array { continue; }
            if i != si || k != sd.n - 1 { report(field_lines[fi], "State may hold one array, as its last field"); }
        }
    }
}

// The parity tests (test_* functions) of the component compile() last read,
// one name per line.
fn test_names() -> u8[>..] {
    var r: u8[>..] = [];
    for f in fns { if f.test && f.body >= 0 { r.append(f.name); r.push('\n'); } }
    return r;
}

fn reset() {
    text.clear();
    line_start.clear();
    line_end.clear();
    toks.clear();
    nodes.clear();
    structs.clear();
    fields.clear();
    field_lines.clear();
    fns.clear();
    params.clear();
    vars.clear();
    scope.clear();
    used.clear();
    opens.clear();
    pos = 0;
    perr = false;
    nerr = 0;
    errs_buf.clear();
    js.clear();
    ind = 0;
    chk.clear();
    pend.clear();
    gtext.clear();
    gline.clear();
    cat_open = false;
}

// Translates components/Name.gshtml (src, at path). compact picks the
// production JavaScript. Errors go to errs as `path:LINE: error: MSG`
// lines; false when there were any. goose_out is written even then, so the
// Goose compiler can report its own errors too.
fn compile(name: const u8[:], path: const u8[:], src: const u8[:], compact_js: bool,
           goose_out: u8[>..]&, js_out: u8[>..]&, errs: u8[>..]&) -> bool {
    reset();
    compact = compact_js;
    src_path.clear();
    src_path.append(path);
    isl.clear();
    isl.append(name);
    text.append(src);
    var s = 0;
    for i in text.len + 1 {
        if i == text.len || text[i] == '\n' {
            line_start.push(s);
            line_end.push(i);
            s = i + 1;
        }
    }
    let nlines = line_start.len;
    if trim_end(text[line_start[0]..line_end[0]]) != "<script goose>" {
        report(1, "a component starts with a line that is exactly <script goose>");
        errs.append(errs_buf);
        return false;
    }
    var close = -1;
    for li in 1..nlines {
        if close < 0 && trim_end(text[line_start[li]..line_end[li]]) == "</script>" { close = li; }
    }
    if close < 0 {
        report(1, "the <script goose> block needs a line that is exactly </script>");
        errs.append(errs_buf);
        return false;
    }
    // Goose: header, the script as it is, render's header.
    format(goose_out, "namespace ", name, "; import std; import json; import web; import web.template;\n");
    for li in 1..close {
        goose_out.append(text[line_start[li]..line_end[li]]);
        goose_out.push('\n');
    }
    goose_out.append("fn render(out: u8[>..]&, s: const State&) {\n");
    parse_script(1, close);
    check_structs();
    for &f in fns {
        if f.n > 0 && params[f.first].mref && params[f.first].ty.name == "State" {
            f.test = starts_with(f.name, "test_") && f.n == 1;
            f.handler = !f.test;
        }
    }
    assign_module_names();
    for i in fns.len { check_fn(i); }
    for i in fns.len { if fns[i].body >= 0 { emit_js_fn(i); } }
    compile_markup(close + 1, close + 1, goose_out);
    if close + 1 >= nlines { goose_out.append("}\n"); }
    emit_zero();
    emit_component_call();
    // The generated tail.
    goose_out.append("fn gw_check(s: const State&) { var gw_w = State { .. };\n");
    goose_out.append(chk);
    goose_out.append("}\n");
    emit_json_writer(goose_out);
    format(goose_out, "fn component(out: u8[>..]&, s: const State&) { out.append(\"<div data-component=\\\"", name,
           "\\\">\"); render(out, s); out.append(\"</div><script type=\\\"application/json\\\">\"); gw_json(out, s); ",
           "out.append(\"</script><script type=\\\"module\\\" src=\\\"/_gw/", name, ".js\\\"></script>\"); }\n");
    // JavaScript: the import line, then the body.
    if compact {
        js_out.append("import{");
        var first = true;
        for h in 9 {
            if !helper_used[h] { continue; }
            if !first { js_out.push(','); }
            first = false;
            format(js_out, HELPERS[h], " as ", helper_js[h]);
        }
        js_out.append("}from\"./gwi.js\";");
    } else {
        js_out.append("// Generated by gweb from ");
        js_out.append(path);
        js_out.append(". Do not edit.\nimport { component, esc, at, set, rm, blen, cap, idiv, imod } from \"./gwi.js\";\n");
    }
    js_out.append(js);
    errs.append(errs_buf);
    return nerr == 0;
}
