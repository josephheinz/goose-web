// component: the .gshtml component translator. gweb calls compile() once for each
// components/Name.gshtml.
//
// .gooseweb/Name.goose stays line for line with the source, so a Goose compiler
// error maps back to its markup line; gw_check, gw_json and component follow
// the last source line. _gw/Name.js is the browser module.

namespace component;

import std;
import tscan;

enum Kind { Int, Bool, Str, Struct, Array }

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
               js: u8[..72], handler: bool, test: bool,
               event: bool,       // reactive: `@event fn name(params);`, no body
               r: i64, w: i64,    // reactive: the bits it reads and writes, through calls
               is_async: bool,    // reactive: awaits, or calls one that does
               emits: bool }      // reactive: sends an @event, or calls a function that does

struct Var { name: u8[..64], ty: Ty, js: u8[..72] }

// ---------------------------------------------------------------- reactive model (Addendum 12)

let R_PROP = 0;
let R_STATE = 1;
let R_COMPUTED = 2;

// A T_ARRAY whose cap is RO is `S[:]`, a read-only array (props only).
let RO = 1;

// One @prop, @state or @computed. bit is the declaration index; mask is 1 << bit.
// init: the default (@prop, -1 when required), the initializer (@state, @computed), or -1;
// an array @state has init -1 (its initializer is []). r: the bits the initializer reads, through calls.
// order: for a computed, its place in rorder.
// ts, te: the type's text in the source (offsets), as the Goose structs write it.
struct RDecl { kind: i64, name: u8[..64], tok: i64, line: i64, ty: Ty, keyword_tok: i64, init: i64,
               bit: i64, mask: i64, r: i64, order: i64, ts: i64, te: i64 }

let RB_WATCH = 0;
let RB_MOUNT = 1;
let RB_UNMOUNT = 2;
let RB_EVERY = 3;

// @watch, @mount, @unmount or @every(ms) with its block. r and w as for a function. lb: the block's `{` token.
struct RBlock { kind: i64, tok: i64, line: i64, ms: i64, body: i64, r: i64, w: i64, is_async: bool, lb: i64, emits: bool }

struct RUse { name: u8[..64], line: i64 }

let RM_TEXT = 0;
let RM_IF = 1;
let RM_FOR = 2;
let RM_LET = 3;
let RM_RAW = 4;
let RM_ON = 5;
let RM_BIND = 6;

// A markup expression: the bits it reads and writes (bind: writes), by line.
struct RMk { kind: i64, line: i64, r: i64, w: i64 }

// A part of the markup (Addendum 12 section 3.2): a dynamic place outside every block. kind: PK_*; r: the bits it
// reads; pcode[s..e]: its value as JavaScript (see emit_part_value); simple: pcode holds one string expression,
// otherwise statements that append to the accumulator.
let PK_TEXT = 0;
let PK_ATTR = 1;
let PK_BLOCK = 2;
let PK_CHILD = 3;     // @Child(...): the marker is before the child's root; the value is its props object
struct RPart { kind: i64, r: i64, s: i64, e: i64, simple: bool, kids: bool }   // kids: a block that holds child calls

// What the scanner of scan_parts found: a dynamic open tag (s: its `<`, ne: after its name, e: its `>`),
// an HTML comment, or the content of a <textarea> (s, e; ne is s).
let PS_TAG = 0;
let PS_COMMENT = 1;
let PS_TEXTAREA = 2;
struct PSpan { kind: i64, s: i64, ne: i64, e: i64 }

// A rewrite of the Goose output: text[at..at + len] becomes `text` (an insertion when len is 0).
// An edit never spans a line break (edit_range splits one that does).
struct Edit { at: i64, len: i64, text: u8[..512] }

// Tokens: offsets into text.
let K_EOF = 0;
let K_ID = 1;
let K_INT = 2;
let K_STR = 3;
let K_OP = 4;
let K_BAD = 5;       // m: 1 char literal, 2 raw string, 3 float, else the text itself

struct Tok { k: i64, s: i64, e: i64, line: i64, m: i64 }   // m: the matching brace

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
let E_AWAIT = 13;    // await a: a is the call; c: 1 when it stands where check_await allows it
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
let B_HTTP_GET = -11;   // http::get(u): tv is its stub, ref2 its decoder (reactive, awaited)
let B_HTTP_POST = -12;  // http::post(u, v)

struct Node {
    k: i64, tok: i64, line: i64,
    a: i64, b: i64, c: i64, d: i64, next: i64,   // children, -1 for none
    t0: i64, t1: i64,                            // first and last token
    ref: i64, ref2: i64,                         // variables or the function
    tv: i64,                                     // S_FOR: the loop bound's temporary
    ty: Ty
}

// The runtime helpers, in the order of the import line.
let HELPERS = ["component", "esc", "at", "set", "rm", "blen", "cap", "idiv", "imod", "swap", "T", "A", "B"];
let H_COMPONENT = 0;
let H_ESC = 1;
let H_AT = 2;
let H_SET = 3;
let H_RM = 4;
let H_BLEN = 5;
let H_CAP = 6;
let H_IDIV = 7;
let H_IMOD = 8;
let H_SWAP = 9;
let H_T = 10;
let H_A = 11;
let H_B = 12;
let HN = 13;     // helpers

let JS_RESERVED = ["await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                   "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function",
                   "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null",
                   "package", "private", "protected", "public", "return", "static", "super", "switch", "this",
                   "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "arguments", "eval"];

// Names a pretty-mode JavaScript name may not take: the imports, the
// module's own functions and the globals the output uses.
let JS_TAKEN = ["component", "esc", "at", "set", "rm", "blen", "cap", "idiv", "imod", "swap", "T", "A", "B",
                "render", "zero", "update", "watch", "init", "Math", "JSON", "structuredClone", "undefined", "NaN", "Infinity", "Object", "String", "Number"];

let GOOSE_KW = ["import", "namespace", "struct", "enum", "type", "fn", "thread_fn", "export", "simd", "recursive",
                "let", "var", "extern", "const", "pad", "reusable", "if", "else", "while", "for", "in", "loop",
                "block", "guard", "defer", "match", "return", "break", "continue", "as", "true", "false", "null",
                "self", "bool", "varint", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"];

let WHITELIST = "(min, max, abs, str, web::has, push, remove_at, clear, append, len)";

// ---------------------------------------------------------------- state (reset by compile)

var text: u8[>..];
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
var helper_used: bool[13];
var helper_js: u8[..16][13];
var render_js: u8[..8];
var zero_js: u8[..8];
var u_js: u8[..8];             // reactive: update, watch and init at module level
var w_js: u8[..8];
var i_js: u8[..8];
var s_js: u8[..72];            // the names the protocol parameters have in every function: state,
var c_js: u8[..72];            // the change handle, the mask, props (and anchors), root and force
var m_js: u8[..72];
var p_js: u8[..72];
var root_js: u8[..72];
var f_js: u8[..72];
var pbase = 0;                 // compact: the first name a reactive function's locals may take
var ty_ref = false;            // parse_type: the type ended with &
var ty_const = false;          // parse_type: the type started with const
var ty_s = 0;                  // parse_type: its first token
var ty_e = 0;                  // parse_type: the token after it

struct Open { kind: u8, line: i64, mark: i64, part: i64 }
var opens: Open[>..<];
var pend: u8[>..];             // markup text not yet written to the JS
var cat_open = false;          // an `o += ...` statement is open in the JS
var cat_first = true;
var o_js: u8[..72];            // render's string in the JS
var s_var = -1;                // render's state variable
var gtext: u8[>..];            // markup text not yet written to the Goose line
var gline: u8[>..];            // the Goose line being built
var chk: u8[>..];              // the body of gw_check
var raw_st = 0;                // tscan's <script>/<style> state across markup lines

var reactive = false;          // the script has @ declarations (set by parse_script)
var rdecls: RDecl[>..<];
var rblocks: RBlock[>..<];
var ruses: RUse[>..<];
var rorder: i64[>..<];         // the computeds, each after the computeds it reads
var rmarks: RMk[>..<];
var mk_r = 0;                  // every bit the markup reads
var rw_r = 0;                  // the R/W walker's accumulators
var rw_w = 0;
var rw_rep = false;            // the walker reports errors (the last pass only)
var rw_ctx = 0;                // 0 function or block, 1 computed, 2 @state initializer, 3 markup
var rw_ctx_name: u8[..64];
var warns_buf: u8[>..];        // reactive warnings, in the warns format
var edits: Edit[>..<];         // the Goose rewrites of 3.1, in the order they were recorded
var props_buf: u8[>..];        // `name\tdefault source\n` for each @prop, for gweb
var parts: RPart[>..<];        // reactive markup parts, in document order
var pcode: u8[>..];            // their values
var letcode: u8[>..];          // the top-level {#let} statements, for update
var pspans: PSpan[>..<];       // scan_parts, in source order
var ptag = 0;                  // the dynamic tag whose events come next
var ptag_phase = 0;            // 0: before its `<`, 1: before the end of its name, 2: before its `>`
var pr_open = -1;              // the attribute or block part collecting its R and code
var pr_acc = 0;                // the bits read since it opened
var pr_ra = 0;                 // where its code starts in js
var pr_flow = 0;
var n_flow = 0;                // statements other than text pieces written so far: {#if}, {#for}, {#let}
var mk_after = 0;              // the source offset after the `}` of the expression being compiled
var var_r: i64[>..<];          // the bits a {#let} variable reads, by variable
var ev_types: u8[>..];         // the on: event types used, space separated

// A typed fetch (Addendum 12 section 7.3): the Goose stub of one http::get or http::post, its reply and value types.
struct Stub { post: bool, reply: Ty, val: Ty }
var stubs: Stub[>..<];
var decs: Ty[>..<];            // the reply decoders of the JavaScript module (roots first, then the structs they reach)
var dec_bits = 0;              // the scalar checks the decoders use: 1 int, 2 bool, 4 string, 8 object, 16 array
var http_urls_buf: u8[>..];    // `METHOD\tLINE\turl\n` for each string-literal url, for gweb's route check
var mods_use = 0;              // 1: the module imports gwm.js (on: modifiers)
var life_use = 0;              // 1: the module imports life from gwl.js
var http_use = 0;              // 1: http::get is used, 2: http::post
var await_ctx: u8[..96];       // the place an await may not stand in (markup, a computed), or empty
var rw_noasync: u8[..96];      // the same for calls of async functions; empty where they are allowed
var rw_async = false;          // the walker met an await or a call of an async function
var rw_emits = false;          // the walker met an @event call or a call of a function that sends one
var rw_awaited = -1;           // the call node of the await being walked

// The components of this gweb run (child calls, Addendum 12 section 7.5), kept across compile() calls: gweb
// compiles a component after the components it calls. done: 0 not compiled yet, 1 legacy, 2 reactive.
struct RegC { name: u8[..64], done: i64 }
var reg: RegC[>..<];
var reg_props: u8[>..];        // `Name\tprop\tt\tcap\tdefault in Goose\tdefault in JavaScript\n`, each @prop of each reactive component
var reg_events: u8[>..];       // `Name\tevent\ttype codes (1 i64, 2 bool, 3 text), comma separated\n`, each @event of each reactive component
var kids: u8[..64][>..<];      // the components this module calls (its imports)
var child_use = 0;             // gwc.js helpers the module imports: 1 H (render), 2 Q (top-level part), 4 M (block)

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
            if i < e && is_alpha(text[i]) {
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

fn span_s(n: i64) -> i64 { toks[nodes[n].t0].s }
fn span_e(n: i64) -> i64 { toks[nodes[n].t1].e }

fn type_bad() {
    var e = max(ty_e, ty_s + 1);
    bad_what(toks[ty_s].line, text[toks[ty_s].s..toks[e - 1].e]);
}

// Sets ty_ref, ty_const and the span; a type outside the subset is reported and gives T_ERR.
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
            if reactive && tok_is(pos + 1, ":") && tok_is(pos + 2, "]") { pos += 3; r.t = T_ARRAY; r.cap = RO; }
            else if tok_is(pos + 1, ">") && tok_is(pos + 2, "..") && tok_is(pos + 3, "<") && tok_is(pos + 4, "]") { pos += 5; r.t = T_ARRAY; }
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
    if reactive && is("await") {
        let n = new_node(E_AWAIT, pos);
        pos += 1;
        let a = parse_unary(ns);
        if perr { return -1; }
        nodes[n].a = a;
        nodes[n].t1 = nodes[a].t1;
        return n;
    }
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
    if reactive && starts_with(name, "gw_") { report(t.line, "names starting with gw_ are reserved"); }
}

// bodyless: `@event fn name(params);`
fn parse_fn(bodyless: bool) {
    let line = toks[pos].line;
    pos += 1;
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
    let name_tok = pos;
    pos += 1;
    if is("<") { bad_what(line, "generics"); return; }
    if !expect("(") { return; }
    let fi = fns.len;
    fns.push(FnDef { name: tok_name(name_tok), tok: name_tok, line: line, first: params.len, n: 0,
                     ret: ty(T_VOID), body: -1, js: "", handler: false, test: false,
                     event: false, r: 0, w: 0, is_async: false, emits: false });
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
        if reactive && t.t == T_STRUCT && ty_ref && t.name != "State" { ok = true; }
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
    if bodyless {
        expect(";");
        return;
    }
    let b = parse_block();
    if perr { return; }
    fns[fi].body = b;
}

// ---------------------------------------------------------------- reactive declarations

fn find_rdecl(name: const u8[:]) -> i64 {
    for d, i in rdecls { if d.name == name { return i; } }
    return -1;
}

fn rmark(k: i64) -> u8[..16] {
    var r: u8[..16] = "";
    if k == R_PROP { r.append("@prop"); }
    else if k == R_STATE { r.append("@state"); }
    else { r.append("@computed"); }
    return r;
}

fn warn_buf(code: const u8[:], line: i64, msg: const u8[:]) {
    format(warns_buf, code, "\t", src_path, ":", line, ": warning: ", msg, "\n");
}

// Does the script have a top-level @? Then it is reactive.
fn detect_reactive() {
    reactive = false;
    var depth = 0;
    var k = pos;
    while toks[k].k != K_EOF {
        if toks[k].k == K_OP {
            if tok_is(k, "{") { depth += 1; }
            else if tok_is(k, "}") { depth -= 1; }
            else if depth == 0 && tok_is(k, "@") { reactive = true; }
        }
        k += 1;
    }
}

fn skip_to_semi() {
    while !at_k(K_EOF) && !is(";") && !is("}") { pos += 1; }
    if is(";") { pos += 1; }
}

fn is_literal(n: i64) -> bool {
    let k = nodes[n].k;
    if k == E_INT || k == E_BOOL || k == E_STR { return true; }
    return k == E_UN && tok_is(nodes[n].tok, "-") && nodes[nodes[n].a].k == E_INT;
}

// pos is at the word after @ (prop, state or computed).
fn parse_rdecl(kind: i64) {
    pos += 1;
    if !is("const") && !is("let") && !is("var") { bad_tok(pos); return; }
    let kw = pos;
    pos += 1;
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
    let nt = pos;
    pos += 1;
    let line = toks[nt].line;
    let di = rdecls.len;
    var mask = 1;
    for k in min(di, 62) { mask *= 2; }
    rdecls.push(RDecl { kind: kind, name: tok_name(nt), tok: nt, line: line, ty: ty(T_ERR), keyword_tok: kw,
                        init: -1, bit: di, mask: mask, r: 0, order: -1, ts: 0, te: 0 });
    let name = tok_name(nt);
    let mk = rmark(kind);
    check_reserved(nt);
    if find_rdecl(name) < di {
        var m: u8[>..] = [];
        format(m, "'", name, "' is declared twice as a reactive name");
        report(line, m);
    }
    if di == 31 { report(line, "a component may have at most 31 @prop, @state and @computed names"); }
    let kwtext = text[toks[kw].s..toks[kw].e];
    if kind == R_PROP && kwtext != "const" { warn_buf("prop-keyword", toks[kw].line, "a prop should be const"); }
    if kind == R_COMPUTED && kwtext != "let" { warn_buf("computed-keyword", toks[kw].line, "a computed value should be let"); }
    if kind == R_STATE && kwtext != "var" { warn_buf("state-keyword", toks[kw].line, "state should be var"); }
    if !is(":") {
        var m: u8[>..] = [];
        format(m, mk, " ", name, " needs a type: write ", mk, " ", kwtext, " ", name, ": T");
        if kind != R_PROP { m.append(" = ..."); }
        report(line, m);
        skip_to_semi();
        return;
    }
    pos += 1;
    let t = parse_type();
    if perr { return; }
    var ok = !ty_ref && !ty_const;
    var allowed: u8[..80] = "";
    if kind == R_PROP {
        ok = ok && (t.t == T_INT || t.t == T_BOOL || t.t == T_STR || t.t == T_STRUCT || (t.t == T_ARRAY && t.cap == RO));
        allowed.append("i64, bool, u8[:], u8[..N], a struct or S[:]");
    } else if kind == R_STATE {
        ok = ok && (t.t == T_INT || t.t == T_BOOL || (t.t == T_STR && t.cap > 0) || t.t == T_STRUCT || (t.t == T_ARRAY && t.cap != RO));
        allowed.append("i64, bool, u8[..N], a struct or S[>..<]");
    } else {
        ok = ok && (t.t == T_INT || t.t == T_BOOL || (t.t == T_STR && t.cap > 0) || t.t == T_STRUCT);
        allowed.append("i64, bool, u8[..N] or a struct");
    }
    if !ok {
        var m: u8[>..] = [];
        format(m, mk, " ", name, " cannot have type ", text[toks[ty_s].s..toks[ty_e - 1].e], "; allowed: ", allowed);
        report(toks[ty_s].line, m);
        skip_to_semi();
        return;
    }
    rdecls[di].ty = t;
    rdecls[di].ts = toks[ty_s].s;
    rdecls[di].te = toks[ty_e - 1].e;
    if kind == R_STATE && t.t == T_ARRAY {
        for j in di {
            if rdecls[j].kind == R_STATE && rdecls[j].ty.t == T_ARRAY { report(line, "a component may hold one array @state"); }
        }
    }
    if kind == R_PROP {
        if accept(";") { return; }
        if !expect("=") { return; }
        let e = parse_expr(false);
        if perr { return; }
        rdecls[di].init = e;
        if t.t == T_STRUCT || t.t == T_ARRAY {
            var m: u8[>..] = [];
            format(m, mk, " ", name, " cannot have a default; it is required at every call site");
            report(line, m);
        } else if !is_literal(e) {
            var m: u8[>..] = [];
            format(m, mk, " ", name, ": a default must be a literal (a whole number, true, false or a string)");
            report(line, m);
        }
        expect(";");
        return;
    }
    if !is("=") {
        var m: u8[>..] = [];
        format(m, mk, " ", name, " needs an initializer");
        report(line, m);
        skip_to_semi();
        return;
    }
    pos += 1;
    if t.t == T_ARRAY {
        if is("[") && tok_is(pos + 1, "]") { pos += 2; }
        else {
            var m: u8[>..] = [];
            format(m, mk, " ", name, " is an array; its initializer must be []");
            report(line, m);
            skip_to_semi();
            return;
        }
        expect(";");
        return;
    }
    let e = parse_expr(false);
    if perr { return; }
    rdecls[di].init = e;
    expect(";");
}

// @watch { }, @mount { }, @unmount { }, @every(MS) { }; pos is at the word after @.
fn parse_rblock() {
    let line = toks[pos].line;
    var kind = RB_WATCH;
    if is("mount") { kind = RB_MOUNT; }
    else if is("unmount") { kind = RB_UNMOUNT; }
    else if is("every") { kind = RB_EVERY; }
    let tk = pos;
    pos += 1;
    var ms = 0;
    if kind == RB_EVERY {
        var good = false;
        if is("(") {
            pos += 1;
            if at_k(K_INT) { ms = int_value(pos); pos += 1; }
            if ms >= 16 && is(")") { good = true; }
        }
        if !good { report(line, "@every needs a whole number of milliseconds, at least 16"); }
        while !at_k(K_EOF) && !is("{") && !is(";") { pos += 1; }
    }
    if !is("{") { bad_tok(pos); return; }
    let lb = pos;
    let b = parse_block();
    if perr { return; }
    rblocks.push(RBlock { kind: kind, tok: tk, line: line, ms: ms, body: b, r: 0, w: 0, is_async: false, lb: lb, emits: false });
}

// @event fn name(params);  pos is at the word after @.
fn parse_revent() {
    pos += 1;
    if !is("fn") { bad_tok(pos); return; }
    let before = fns.len;
    parse_fn(true);
    if fns.len > before { fns[fns.len - 1].event = true; }
}

fn parse_ruse() {
    let line = toks[pos].line;
    pos += 1;
    if !at_k(K_ID) || is_keyword(pos) { bad_tok(pos); return; }
    ruses.push(RUse { name: tok_name(pos), line: line });
    pos += 1;
    report(line, "@use is not built yet (Addendum 12 step 12)");
    expect(";");
}

// pos is at the @.
fn parse_at() {
    pos += 1;
    if !at_k(K_ID) { bad_tok(pos); return; }
    if is("prop") { parse_rdecl(R_PROP); }
    else if is("state") { parse_rdecl(R_STATE); }
    else if is("computed") { parse_rdecl(R_COMPUTED); }
    else if is("watch") || is("mount") || is("unmount") || is("every") { parse_rblock(); }
    else if is("event") { parse_revent(); }
    else if is("use") { parse_ruse(); }
    else {
        var m: u8[>..] = [];
        format(m, "unknown declaration '@", text[toks[pos].s..toks[pos].e], "'");
        report(toks[pos].line, m);
        perr = true;
    }
}

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

fn parse_script(first_line: i64, close: i64) -> bool {
    let before = nerr;
    pos = tokenize(line_start[first_line], line_start[close], first_line + 1);
    detect_reactive();
    while !at_k(K_EOF) {
        let start = pos;
        perr = false;
        if is("struct") { parse_struct(); }
        else if is("fn") { parse_fn(false); }
        else if reactive && is("@") { parse_at(); }
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

// The Goose name, or name$N when that is taken.
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
    // A reactive function's protocol names are taken: locals do not reuse them.
    if reactive {
        if compact { fcount = pbase; }
        else {
            used.push(s_js);
            used.push(c_js);
            used.push(m_js);
            used.push(p_js);
            used.push(root_js);
            used.push(f_js);
        }
    }
}

fn declare(tok: i64, t: Ty) -> i64 {
    check_reserved(tok);
    if reactive {
        let d = find_rdecl(text[toks[tok].s..toks[tok].e]);
        if d >= 0 {
            var m: u8[>..] = [];
            let mk = rmark(rdecls[d].kind);
            format(m, "'", rdecls[d].name, "' is ", mk, "; a local cannot reuse the name");
            report(toks[tok].line, m);
        }
    }
    var v = Var { name: tok_name(tok), ty: t, js: "" };
    if compact { v.js.append(next_short()); } else { v.js = pick_name(v.name); }
    vars.push(v);
    scope.push(vars.len - 1);
    return vars.len - 1;
}

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

// A name for a pretty-mode protocol parameter: base, or base$N when something takes it.
fn free_name(base: const u8[:]) -> u8[..72] {
    var c: u8[..72] = "";
    c.append(base);
    var k = 1;
    while name_taken(c) {
        c.clear();
        format(c, base, "$", k);
        k += 1;
    }
    return c;
}

fn assign_module_names() {
    for h in HN {
        helper_js[h].clear();
        if compact { helper_js[h].append(short_name(h)); } else { helper_js[h].append(HELPERS[h]); }
        helper_used[h] = false;
    }
    render_js.clear();
    zero_js.clear();
    u_js.clear();
    w_js.clear();
    i_js.clear();
    if compact {
        render_js.append(short_name(13));
        zero_js.append(short_name(14));
        u_js.append(short_name(15));
        w_js.append(short_name(16));
        i_js.append(short_name(17));
    } else {
        render_js.append("render");
        zero_js.append("zero");
        u_js.append("update");
        w_js.append("watch");
        i_js.append("init");
    }
    for &f, i in fns {
        f.js.clear();
        if compact { f.js.append(short_name(18 + i)); }
        else {
            f.js.append(f.name);
            if in_list(f.js, JS_TAKEN) { f.js.push('$'); }
        }
    }
    mbase = 18 + fns.len;
    used.clear();
    if compact {
        fcount = mbase;
        s_js.clear();
        s_js.append(next_short());
        c_js.clear();
        c_js.append(next_short());
        m_js.clear();
        m_js.append(next_short());
        p_js.clear();
        p_js.append(next_short());
        root_js.clear();
        root_js.append(next_short());
        f_js.clear();
        f_js.append(next_short());
        pbase = fcount;
    } else {
        s_js = free_name("s");
        c_js = free_name("c");
        m_js = free_name("m");
        p_js = free_name("p");
        root_js = free_name("root");
        f_js = free_name("f");
    }
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
        if v < 0 && reactive {
            let d = find_rdecl(text[toks[nodes[n].tok].s..toks[nodes[n].tok].e]);
            if d >= 0 { nodes[n].ref2 = d; nodes[n].ty = rdecls[d].ty; return; }
            if tok_is(nodes[n].tok, "s") {
                report(line, "'s' does not exist in a reactive component; name the state directly");
                return;
            }
        }
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
            else if reactive && is_http(n) {
                var m: u8[>..] = [];
                format(m, "http::", tok_name(nodes[n].d), " needs await");
                report(line, m);
                return;
            }
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
    if k == E_AWAIT {
        if await_ctx.len > 0 {
            var m: u8[>..] = [];
            format(m, await_ctx, " cannot await");
            report(line, m);
        } else {
            report(line, "await only goes at the start of a statement, after x =, or after let x: T =");
        }
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

// http::get or http::post.
fn is_http(c: i64) -> bool {
    return nodes[c].d >= 0 && tok_is(nodes[c].tok, "http") && (tok_is(nodes[c].d, "get") || tok_is(nodes[c].d, "post"));
}

// A type a reply decodes into: i64, bool, u8[..N], a struct, or an array of struct.
fn reply_ok(t: const Ty&) -> bool {
    if t.t == T_INT || t.t == T_BOOL { return true; }
    if t.t == T_STR { return t.cap > 0; }
    if t.t == T_STRUCT { return find_struct(t.name) >= 0; }
    if t.t == T_ARRAY { return t.cap != RO && find_struct(t.name) >= 0; }
    return false;
}

fn same_reply(a: const Ty&, b: const Ty&) -> bool {
    return same_ty(a, b) && (a.t != T_STR || a.cap == b.cap);
}

// The stub of one kind of http call: gw_get_K or gw_post_K in the Goose tail.
fn stub_of(post: bool, reply: const Ty&, val: const Ty&) -> i64 {
    for st, i in stubs {
        if st.post == post && same_reply(st.reply, reply) && same_ty(st.val, val) { return i; }
    }
    stubs.push(Stub { post: post, reply: reply, val: val });
    return stubs.len - 1;
}

// The decoder of a reply type in the JavaScript module.
fn dec_of(t: const Ty&) -> i64 {
    for d, i in decs { if same_reply(d, t) { return i; } }
    decs.push(t);
    return decs.len - 1;
}

// aw is an `await`: want is the type the result goes into (T_VOID: nowhere). Sets the types of aw and of its call.
// The call is http::get(u), http::post(u, v) or a call of an async function.
fn check_await(aw: i64, want: const Ty&) {
    let line = nodes[aw].line;
    let c = nodes[aw].a;
    if nodes[c].k != E_CALL {
        report(line, "await goes before http::get(u), http::post(u, v) or a call of an async function");
        return;
    }
    if !is_http(c) {
        check_expr(c);
        if nodes[c].ty.t == T_ERR { return; }
        if nodes[c].ref < 0 {
            report(line, "await goes before http::get(u), http::post(u, v) or a call of an async function");
            return;
        }
        if want.t != T_VOID && nodes[c].ty.t == T_VOID { cannot_type(line); return; }
        nodes[aw].ty = nodes[c].ty;
        nodes[aw].c = 1;
        return;
    }
    let post = tok_is(nodes[c].d, "post");
    nodes[c].ref = if post { B_HTTP_POST } else { B_HTTP_GET };
    var a = nodes[c].a;
    var bad = false;
    while a >= 0 {
        check_expr(a);
        if nodes[a].ty.t == T_ERR { bad = true; }
        a = nodes[a].next;
    }
    if bad { return; }
    var what: u8[>..] = [];
    format(what, "http::", tok_name(nodes[c].d));
    let na = args_count(c);
    if na != (if post { 2 } else { 1 }) {
        var m: u8[>..] = [];
        if post { format(m, what, " takes a url and a value: http::post(u, v)"); } else { format(m, what, " takes a url: http::get(u)"); }
        report(line, m);
        return;
    }
    if arg_t(c, 0) != T_STR {
        var m: u8[>..] = [];
        format(m, what, " needs a string url");
        report(line, m);
        return;
    }
    var val = ty(T_VOID);
    if post {
        val = nodes[arg_at(c, 1)].ty;
        if val.t == T_VOID || val.t == T_ERR {
            report(line, "http::post sends an i64, bool, string, struct or array of struct");
            return;
        }
    }
    if want.t == T_ERR { return; }
    if want.t == T_VOID && !post {
        report(line, "http::get needs a place for its reply: x = await http::get(u);");
        return;
    }
    if want.t != T_VOID && !reply_ok(want) {
        var m: u8[>..] = [];
        format(m, "await ", what, " decodes into i64, bool, u8[..N], a struct or S[>..<]");
        report(line, m);
        return;
    }
    nodes[c].ty = want;
    nodes[aw].ty = want;
    nodes[aw].c = 1;
    nodes[c].tv = stub_of(post, want, val);
    if want.t != T_VOID { nodes[c].ref2 = dec_of(want); }
    http_use = http_use | (if post { 2 } else { 1 });
    let u = arg_at(c, 0);
    if nodes[u].k == E_STR {
        let lit = text[toks[nodes[u].tok].s + 1..toks[nodes[u].tok].e - 1];
        if find(lit, "\\") < 0 { format(http_urls_buf, if post { "POST" } else { "GET" }, "\t", line, "\t", lit, "\n"); }
    }
}

fn check_let(n: i64) {
    let a = nodes[n].a;
    if nodes[a].k == E_AWAIT {
        var t = ty(T_ERR);
        if nodes[n].b == 1 { t = nodes[n].ty; }
        let c = nodes[a].a;
        if nodes[n].b != 1 && nodes[c].k == E_CALL && is_http(c) {
            var m: u8[>..] = [];
            format(m, "let ", tok_name(nodes[n].tok), " needs a type: await http::", tok_name(nodes[c].d), "(...) decodes into it");
            report(nodes[n].line, m);
            nodes[n].ref = declare(nodes[n].tok, t);
            return;
        }
        var wt = ty(T_STRUCT);
        if nodes[n].b == 1 { wt = t; }
        check_await(a, wt);
        if nodes[n].b != 1 { t = nodes[a].ty; nodes[n].ty = t; }
        nodes[n].ref = declare(nodes[n].tok, t);
        return;
    }
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
        if nodes[b].k == E_AWAIT {
            if !is_lvalue(a) { cannot_type(line); return; }
            if !tok_is(nodes[n].tok, "=") { report(line, "await goes after = only"); return; }
            check_await(b, nodes[a].ty);
            return;
        }
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
        let e = nodes[n].a;
        if nodes[e].k == E_AWAIT { let none = ty(T_VOID); check_await(e, none); return; }
        check_expr(e);
        return;
    }
}

fn check_fn(fi: i64) {
    if reactive && fns[fi].event { return; }
    begin_fn();
    let f = fns[fi];
    for p in f.first..f.first + f.n {
        params[p].var_id = declare(params[p].tok, params[p].ty);
    }
    if f.body >= 0 { check_block(f.body); }
}

// ---------------------------------------------------------------- reads, writes (Addendum 12, section 2)

// Which reactive name is node n, or -1 (a local, or something else).
fn rdecl_of(n: i64) -> i64 {
    if nodes[n].k == E_NAME { return nodes[n].ref2; }
    return -1;
}

fn rw_read(d: i64) { rw_r = rw_r | rdecls[d].mask; }

fn rw_write(d: i64, line: i64) {
    rw_w = rw_w | rdecls[d].mask;
    if !rw_rep { return; }
    let dc = rdecls[d];
    var m: u8[>..] = [];
    if dc.kind == R_PROP {
        format(m, "@prop ", dc.name, " is const; a component cannot change its props");
        report(line, m);
    } else if dc.kind == R_COMPUTED {
        format(m, "@computed ", dc.name, " is set by the framework; component code cannot assign it");
        report(line, m);
    }
}

// A target: a name, or a field or element inside one. compound: the old value is read too.
recursive fn rw_lvalue(n: i64, compound: bool, line: i64) {
    if n < 0 { return; }
    let k = nodes[n].k;
    if k == E_NAME {
        let d = nodes[n].ref2;
        if d >= 0 {
            if compound { rw_read(d); }
            rw_write(d, line);
        }
        return;
    }
    if k == E_FIELD { rw_lvalue(nodes[n].a, compound, line); return; }
    if k == E_INDEX {
        rw_lvalue(nodes[n].a, compound, line);
        rw_expr(nodes[n].b);
        return;
    }
    rw_expr(n);
}

recursive fn rw_expr(n: i64) {
    if n < 0 { return; }
    let k = nodes[n].k;
    let line = nodes[n].line;
    if k == E_NAME {
        if nodes[n].ref2 >= 0 { rw_read(nodes[n].ref2); }
        else if nodes[n].ref >= 0 && nodes[n].ref < var_r.len { rw_r = rw_r | var_r[nodes[n].ref]; }
        return;
    }
    if k == E_FIELD { rw_expr(nodes[n].a); return; }
    if k == E_INDEX { rw_expr(nodes[n].a); rw_expr(nodes[n].b); return; }
    if k == E_UN { rw_expr(nodes[n].a); return; }
    if k == E_BIN { rw_expr(nodes[n].a); rw_expr(nodes[n].b); return; }
    if k == E_IF { rw_expr(nodes[n].a); rw_expr(nodes[n].b); rw_expr(nodes[n].c); return; }
    if k == E_SLIT {
        var f = nodes[n].a;
        while f >= 0 { rw_expr(nodes[f].a); f = nodes[f].next; }
        return;
    }
    if k == E_AWAIT {
        rw_async = true;
        if rw_rep && rw_noasync.len > 0 && nodes[n].c == 1 {
            var m: u8[>..] = [];
            format(m, rw_noasync, " cannot await");
            report(line, m);
        }
        rw_awaited = nodes[n].a;
        rw_expr(nodes[n].a);
        return;
    }
    if k != E_CALL { return; }
    let r = nodes[n].ref;
    var a = nodes[n].a;
    if r >= 0 && fns[r].is_async {
        rw_async = true;
        if rw_rep {
            var m: u8[>..] = [];
            if rw_noasync.len > 0 { format(m, rw_noasync, " cannot call '", fns[r].name, "', which is async"); }
            else if rw_awaited != n { format(m, "'", fns[r].name, "' is async: write await ", fns[r].name, "()"); }
            if m.len > 0 { report(line, m); }
        }
    } else if r >= 0 && rw_awaited == n && rw_rep {
        var m: u8[>..] = [];
        format(m, "'", fns[r].name, "' is not async: remove await");
        report(line, m);
    }
    if r >= 0 && (fns[r].event || fns[r].emits) {
        rw_emits = true;
        if rw_rep {
            var nm: u8[>..] = [];
            if rw_ctx == 1 { format(nm, "@computed ", rw_ctx_name); }
            else if rw_ctx == 2 { format(nm, "@state ", rw_ctx_name); }
            else if rw_ctx == 3 { nm.append("markup"); }
            else if rw_noasync == "@watch" { nm.append("@watch"); }
            if nm.len > 0 {
                var m: u8[>..] = [];
                format(m, "an @event is sent from a handler, not from ", nm);
                report(line, m);
            }
        }
    }
    if r >= 0 {
        rw_r = rw_r | fns[r].r;
        rw_w = rw_w | fns[r].w;
        if rw_rep && rw_ctx != 0 && fns[r].w != 0 {
            var m: u8[>..] = [];
            if rw_ctx == 1 { format(m, "@computed ", rw_ctx_name, " cannot call '", fns[r].name, "', which changes state"); }
            else if rw_ctx == 2 { format(m, "@state ", rw_ctx_name, " cannot call '", fns[r].name, "', which changes state"); }
            else { format(m, "markup cannot call '", fns[r].name, "', which changes state"); }
            report(line, m);
        }
        var i = 0;
        while a >= 0 {
            if i < fns[r].n && params[fns[r].first + i].mref { rw_lvalue(a, false, line); } else { rw_expr(a); }
            i += 1;
            a = nodes[a].next;
        }
        return;
    }
    if r == B_PUSH || r == B_REMOVE_AT || r == B_CLEAR || r == B_APPEND {
        rw_lvalue(a, false, line);
        if a >= 0 { a = nodes[a].next; }
    }
    while a >= 0 { rw_expr(a); a = nodes[a].next; }
}

recursive fn rw_stmt(n: i64) {
    let k = nodes[n].k;
    let line = nodes[n].line;
    if k == S_LET { rw_expr(nodes[n].a); return; }
    if k == S_ASSIGN {
        rw_expr(nodes[n].b);
        rw_lvalue(nodes[n].a, !tok_is(nodes[n].tok, "="), line);
        return;
    }
    if k == S_INCDEC { rw_lvalue(nodes[n].a, true, line); return; }
    if k == S_IF {
        rw_expr(nodes[n].a);
        rw_block(nodes[n].b);
        let e = nodes[n].c;
        if e >= 0 {
            if nodes[e].k == S_IF { rw_stmt(e); } else { rw_block(e); }
        }
        return;
    }
    if k == S_FOR {
        rw_expr(nodes[n].a);
        rw_expr(nodes[n].b);
        rw_block(nodes[n].c);
        return;
    }
    if k == S_WHILE { rw_expr(nodes[n].a); rw_block(nodes[n].c); return; }
    if k == S_RETURN || k == S_RESULT || k == S_EXPR { rw_expr(nodes[n].a); return; }
}

recursive fn rw_block(n: i64) {
    if n < 0 { return; }
    var s = nodes[n].a;
    while s >= 0 {
        rw_stmt(s);
        s = nodes[s].next;
    }
}

// R and W of every function, to a fixed point over the call graph. No errors.
fn rw_fixpoint() {
    rw_rep = false;
    rw_ctx = 0;
    rw_noasync.clear();
    var changed = true;
    while changed {
        changed = false;
        for i in fns.len {
            if fns[i].body < 0 { continue; }
            rw_r = 0;
            rw_w = 0;
            rw_async = false;
            rw_emits = false;
            rw_block(fns[i].body);
            if rw_r != fns[i].r || rw_w != fns[i].w || rw_async != fns[i].is_async || rw_emits != fns[i].emits {
                fns[i].r = rw_r;
                fns[i].w = rw_w;
                fns[i].is_async = rw_async;
                fns[i].emits = rw_emits;
                changed = true;
            }
        }
    }
}

// The computeds in dependency order into rorder, or the cycle error.
fn order_computeds() {
    rorder.clear();
    var cmask = 0;
    var total = 0;
    for i in rdecls.len {
        if rdecls[i].kind == R_COMPUTED { cmask += rdecls[i].mask; total += 1; }
    }
    var placed = 0;
    while rorder.len < total {
        var progress = false;
        for i in rdecls.len {
            if rdecls[i].kind != R_COMPUTED || (placed & rdecls[i].mask) != 0 { continue; }
            let pending = cmask - placed;
            if (rdecls[i].r & pending) != 0 { continue; }
            rorder.push(i);
            rdecls[i].order = rorder.len - 1;
            placed += rdecls[i].mask;
            progress = true;
        }
        if progress { continue; }
        // A cycle: follow the dependencies from the first computed left until one repeats.
        var cur = -1;
        for i in rdecls.len {
            if cur < 0 && rdecls[i].kind == R_COMPUTED && (placed & rdecls[i].mask) == 0 { cur = i; }
        }
        var seen = 0;
        loop {
            seen = seen | rdecls[cur].mask;
            let deps = rdecls[cur].r & (cmask - placed);
            var nxt = -1;
            for j in rdecls.len {
                if nxt < 0 && (deps & rdecls[j].mask) != 0 { nxt = j; }
            }
            if nxt < 0 { return; }
            if (seen & rdecls[nxt].mask) != 0 {
                var m: u8[>..] = [];
                if nxt == cur { format(m, "@computed ", rdecls[cur].name, " depends on itself"); }
                else {
                    let lo = min(cur, nxt);
                    let hi = max(cur, nxt);
                    format(m, "@computed ", rdecls[lo].name, " and ", rdecls[hi].name, " depend on each other");
                }
                report(rdecls[min(cur, nxt)].line, m);
                return;
            }
            cur = nxt;
        }
    }
}

// After check_fn: initializers, blocks, then R/W and the rules built on them.
fn check_reactive() {
    for i in rdecls.len {
        let init = rdecls[i].init;
        if init < 0 { continue; }
        begin_fn();
        await_ctx.clear();
        format(await_ctx, rmark(rdecls[i].kind), " ", rdecls[i].name);
        check_expr(init);
        await_ctx.clear();
        let got = nodes[init].ty;
        let want = rdecls[i].ty;
        if got.t == T_ERR || want.t == T_ERR { continue; }
        if !same_ty(got, want) {
            var m: u8[>..] = [];
            let mk = rmark(rdecls[i].kind);
            format(m, "the ", if rdecls[i].kind == R_PROP { "default" } else { "initializer" }, " of ", mk, " ", rdecls[i].name, " has the wrong type");
            report(nodes[init].line, m);
        }
    }
    for i in rblocks.len {
        begin_fn();
        check_block(rblocks[i].body);
    }
    rw_fixpoint();
    rw_rep = true;
    for i in fns.len {
        if fns[i].body < 0 { continue; }
        rw_ctx = 0;
        rw_r = 0;
        rw_w = 0;
        rw_async = false;
        rw_noasync.clear();
        rw_block(fns[i].body);
        if fns[i].test && fns[i].is_async {
            var m: u8[>..] = [];
            format(m, "'", fns[i].name, "' is async; a test runs without a network");
            report(fns[i].line, m);
        }
    }
    for i in rblocks.len {
        rw_ctx = 0;
        rw_r = 0;
        rw_w = 0;
        rw_noasync.clear();
        // @mount and @every run through run() like a handler, so they may await; the others may not.
        if rblocks[i].kind == RB_WATCH { rw_noasync.append("@watch"); }
        else if rblocks[i].kind == RB_UNMOUNT { rw_noasync.append("@unmount"); }
        rw_async = false;
        rw_emits = false;
        rw_block(rblocks[i].body);
        rblocks[i].emits = rw_emits;
        rblocks[i].is_async = rw_async;
        rblocks[i].r = rw_r;
        rblocks[i].w = rw_w;
    }
    for i in rdecls.len {
        let init = rdecls[i].init;
        if init < 0 || rdecls[i].kind == R_PROP { continue; }
        rw_ctx = if rdecls[i].kind == R_STATE { 2 } else { 1 };
        rw_ctx_name.clear();
        rw_ctx_name.append(rdecls[i].name);
        rw_noasync.clear();
        format(rw_noasync, rmark(rdecls[i].kind), " ", rdecls[i].name);
        rw_r = 0;
        rw_w = 0;
        rw_expr(init);
        rdecls[i].r = rw_r;
        if rdecls[i].kind != R_STATE { continue; }
        for j in rdecls.len {
            if (rw_r & rdecls[j].mask) == 0 { continue; }
            var m: u8[>..] = [];
            if rdecls[j].kind == R_STATE && j >= i {
                format(m, "@state ", rdecls[i].name, " reads ", rdecls[j].name, ", which is declared after it");
            } else if rdecls[j].kind == R_COMPUTED {
                format(m, "@state ", rdecls[i].name, " reads ", rdecls[j].name, ", which is @computed; initializers read props and earlier @state only");
            }
            if m.len > 0 { report(rdecls[i].line, m); }
        }
    }
    rw_rep = false;
    rw_noasync.clear();
    order_computeds();
}

// A markup expression: its R and W, and the rule that markup does not call a function that writes.
fn rw_mark(n: i64, line: i64, kind: i64) {
    if n < 0 { return; }
    rw_rep = true;
    rw_ctx = 3;
    rw_r = 0;
    rw_w = 0;
    rw_noasync.clear();
    rw_noasync.append("markup");
    rw_expr(n);
    rw_noasync.clear();
    rw_rep = false;
    rmarks.push(RMk { kind: kind, line: line, r: rw_r, w: rw_w });
    mk_r = mk_r | rw_r;
    if pr_open >= 0 { pr_acc = pr_acc | rw_r; }
}

// After the parse: the rules that need every declaration, and the marks on functions.
fn check_rmodel() {
    let si = find_struct("State");
    if si >= 0 { report(structs[si].line, "a component uses either @ declarations or struct State, not both"); }
    let pi = find_struct("Props");
    if pi >= 0 { report(structs[pi].line, "a reactive component cannot declare struct Props; gweb writes it from the @prop lines"); }
    for i in rdecls.len {
        let t = rdecls[i].ty;
        if (t.t == T_STRUCT || t.t == T_ARRAY) && find_struct(t.name) < 0 {
            var m: u8[>..] = [];
            let mk = rmark(rdecls[i].kind);
            format(m, mk, " ", rdecls[i].name, ": '", t.name, "' is not a struct declared in this component");
            report(rdecls[i].line, m);
            rdecls[i].ty = ty(T_ERR);
        }
    }
    for &f in fns {
        f.test = starts_with(f.name, "test_") && f.n == 0 && !f.event;
        f.handler = !f.test && !f.event;
    }
}

// ---------------------------------------------------------------- Goose rewrites (Addendum 12, section 3.1)

fn takes_state(fi: i64) -> bool { (fns[fi].r | fns[fi].w) != 0 }

// The JavaScript of a reactive function: (s, c, ...) when it writes or awaits, (s, ...) when it only reads, (...) else.
fn js_takes_s(fi: i64) -> bool { return takes_state(fi) || fns[fi].is_async || fns[fi].emits; }
fn js_takes_c(fi: i64) -> bool { return fns[fi].w != 0 || fns[fi].is_async || fns[fi].emits; }

// The name of the typed-fetch imports and of reply decoder k, in the output's style.
fn http_name(post: bool) -> u8[..16] {
    var r: u8[..16] = "";
    r.append(if compact { if post { "$p" } else { "$g" } } else { if post { "gw_post" } else { "gw_get" } });
    return r;
}

fn dec_name(k: i64) -> u8[..16] {
    var r: u8[..16] = "";
    format(r, if compact { "$" } else { "gw_d" }, k);
    return r;
}

// One scalar check of a decoder: i int, b bool, s string, o object, a array.
fn dec_check(c: u8) -> u8[..16] {
    var r: u8[..16] = "";
    r.append(if compact { "$" } else { "gw_" });
    r.push(c);
    return r;
}

fn add_edit(at: i64, len: i64, repl: const u8[:]) {
    var e = Edit { at: at, len: len, text: "" };
    e.text.append(repl);
    edits.push(e);
}

// text[s..e] becomes repl. The pieces on later lines become empty, so the line count stays.
fn edit_range(s: i64, e: i64, repl: const u8[:]) {
    var a = s;
    var first = true;
    for p in s..e + 1 {
        if p < e && text[p] != '\n' { continue; }
        if first { add_edit(a, p - a, repl); first = false; }
        else if p > a { add_edit(a, p - a, ""); }
        a = p + 1;
    }
}

// text[s..e] with the edits inside it applied, in the order of their offsets.
fn rewrite(s: i64, e: i64) -> u8[>..] {
    var out: u8[>..] = [];
    var idx: i64[>..] = [];
    for i in edits.len {
        if edits[i].at >= s && edits[i].at + edits[i].len <= e { idx.push(i); }
    }
    // An insertion sort keeps edits at one offset in the order they were recorded.
    var q = 1;
    while q < idx.len {
        let x = idx[q];
        var j = q - 1;
        while j >= 0 && edits[idx[j]].at > edits[x].at {
            idx[j + 1] = idx[j];
            j -= 1;
        }
        idx[j + 1] = x;
        q += 1;
    }
    var cur = s;
    for k in idx.len {
        let ed = edits[idx[k]];
        if ed.at > cur { out.append(text[cur..ed.at]); }
        out.append(ed.text);
        cur = max(cur, ed.at + ed.len);
    }
    out.append(text[cur..e]);
    return out;
}

// The token index of the `;` that ends the declaration holding token t, or -1.
fn semi_after(t: i64) -> i64 {
    var i = t;
    while toks[i].k != K_EOF {
        if tok_is(i, ";") { return i; }
        i += 1;
    }
    return -1;
}

// Names that resolve to a prop or to state get gw_p. or gw_s.; calls of state-taking functions get gw_p, gw_s.
recursive fn rec_expr(n: i64) {
    if n < 0 { return; }
    let k = nodes[n].k;
    if k == E_NAME {
        let d = nodes[n].ref2;
        if d >= 0 { add_edit(toks[nodes[n].tok].s, 0, if rdecls[d].kind == R_PROP { "gw_p." } else { "gw_s." }); }
        return;
    }
    if k == E_FIELD || k == E_UN { rec_expr(nodes[n].a); return; }
    if k == E_INDEX || k == E_BIN { rec_expr(nodes[n].a); rec_expr(nodes[n].b); return; }
    if k == E_IF { rec_expr(nodes[n].a); rec_expr(nodes[n].b); rec_expr(nodes[n].c); return; }
    if k == E_SLIT {
        var f = nodes[n].a;
        while f >= 0 { rec_expr(nodes[f].a); f = nodes[f].next; }
        return;
    }
    if k == E_AWAIT {
        // The Goose side runs nothing asynchronously: the await is dropped.
        edit_range(toks[nodes[n].tok].s, toks[nodes[n].tok].e, "");
        rec_expr(nodes[n].a);
        return;
    }
    if k != E_CALL { return; }
    let r = nodes[n].ref;
    if r == B_HTTP_GET || r == B_HTTP_POST {
        var nm: u8[>..] = [];
        format(nm, if r == B_HTTP_GET { "gw_get_" } else { "gw_post_" }, nodes[n].tv);
        edit_range(toks[nodes[n].tok].s, toks[nodes[n].d].e, nm);
    }
    if r >= 0 && takes_state(r) {
        add_edit(toks[nodes[n].tok + 1].e, 0, if nodes[n].a >= 0 { "gw_p, gw_s, " } else { "gw_p, gw_s" });
    }
    var a = nodes[n].a;
    while a >= 0 { rec_expr(a); a = nodes[a].next; }
}

recursive fn rec_stmt(n: i64) {
    let k = nodes[n].k;
    if k == S_LET || k == S_RETURN || k == S_RESULT || k == S_EXPR { rec_expr(nodes[n].a); return; }
    if k == S_ASSIGN { rec_expr(nodes[n].a); rec_expr(nodes[n].b); return; }
    if k == S_INCDEC { rec_expr(nodes[n].a); return; }
    if k == S_IF {
        rec_expr(nodes[n].a);
        rec_block(nodes[n].b);
        let e = nodes[n].c;
        if e >= 0 {
            if nodes[e].k == S_IF { rec_stmt(e); } else { rec_block(e); }
        }
        return;
    }
    if k == S_FOR {
        rec_expr(nodes[n].a);
        rec_expr(nodes[n].b);
        rec_block(nodes[n].c);
        return;
    }
    if k == S_WHILE { rec_expr(nodes[n].a); rec_block(nodes[n].c); }
}

recursive fn rec_block(n: i64) {
    if n < 0 { return; }
    var s = nodes[n].a;
    while s >= 0 {
        rec_stmt(s);
        s = nodes[s].next;
    }
}

// Has this declaration a Goose function (gw_i_x, gw_c_x) for its initializer?
fn has_init_fn(d: RDecl) -> bool {
    return d.kind != R_PROP && d.ty.t != T_ERR && d.ty.t != T_ARRAY && d.init >= 0;
}

// After check_reactive: the edits of the script lines. Markup edits are recorded as the markup is compiled.
fn rec_script() {
    for i in rdecls.len {
        let d = rdecls[i];
        let semi = semi_after(d.tok);
        if semi < 0 { continue; }
        let from = toks[d.keyword_tok - 2].s;
        if !has_init_fn(d) { edit_range(from, toks[semi].e, ""); continue; }
        var pre: u8[>..] = [];
        format(pre, "fn gw_", if d.kind == R_STATE { "i_" } else { "c_" }, d.name,
               "(gw_p: const Props&, gw_s: const State&) -> ", text[d.ts..d.te], " { return ");
        edit_range(from, span_s(d.init), pre);
        edit_range(span_e(d.init), toks[semi].e, "; }");
        rec_expr(d.init);
    }
    for i in rblocks.len {
        let b = rblocks[i];
        var h: u8[>..] = [];
        format(h, "fn gw_w", i, "(gw_p: const Props&, gw_s: ", if b.w != 0 { "" } else { "const " }, "State&) ");
        edit_range(toks[b.tok - 1].s, toks[b.lb].s, h);
        rec_block(b.body);
    }
    for i in fns.len {
        let f = fns[i];
        if f.event {
            // `@event fn change(v: i64);` becomes `fn change(v: i64) {}`.
            let semi = semi_after(f.tok);
            if semi < 0 { continue; }
            edit_range(toks[f.tok - 3].s, toks[f.tok - 1].s, "");
            edit_range(toks[semi].s, toks[semi].e, " {}");
            continue;
        }
        if f.body < 0 { continue; }
        if takes_state(i) {
            var h: u8[>..] = [];
            h.append(if f.w != 0 { "gw_p: const Props&, gw_s: State&" } else { "gw_p: const Props&, gw_s: const State&" });
            if f.n > 0 { h.append(", "); }
            add_edit(toks[f.tok + 1].e, 0, h);
        }
        rec_block(f.body);
    }
}

// ---------------------------------------------------------------- JavaScript

fn w(s: const u8[:]) { js.append(s); }

fn close_brace() {
    if compact && js.len > 0 && js[js.len - 1] == ';' { js.pop(); }
    w("}");
}

fn w_bool(v: bool) {
    if compact { w(if v { "!0" } else { "!1" }); } else { w(if v { "true" } else { "false" }); }
}

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

// top: the context delimits the expression, so a binary operation needs no parentheses.
recursive fn emit_expr(n: i64, top: bool) {
    let k = nodes[n].k;
    if k == E_INT || k == E_STR { w_tok(nodes[n].tok); return; }
    if k == E_BOOL { w_bool(tok_is(nodes[n].tok, "true")); return; }
    if k == E_NAME {
        // A reactive name is a field of the state object.
        if nodes[n].ref2 >= 0 { w(s_js); w("."); w(rdecls[nodes[n].ref2].name); return; }
        w_var(nodes[n].ref);
        return;
    }
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
    if k == E_AWAIT {
        w("await ");
        emit_expr(nodes[n].a, false);
        return;
    }
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
    if r >= 0 && fns[r].event {
        // c.e("change", [args]): the runtime hands it to the parent's handler.
        w(c_js);
        w(".e(");
        js_str(fns[r].name);
        wo(", [");
        emit_args(n);
        w("])");
        return;
    }
    if r >= 0 {
        w(fns[r].js);
        w("(");
        // A reactive function gets the state, and the change handle when it writes.
        var lead = false;
        if reactive && js_takes_s(r) {
            w(s_js);
            lead = true;
            if js_takes_c(r) { wo(", "); w(c_js); }
        }
        if lead && nodes[n].a >= 0 { wo(", "); }
        emit_args(n);
        w(")");
        return;
    }
    if r == B_HTTP_GET || r == B_HTTP_POST {
        w(http_name(r == B_HTTP_POST));
        w("(");
        emit_expr(arg_at(n, 0), true);
        if r == B_HTTP_POST { wo(", "); emit_expr(arg_at(n, 1), true); }
        if nodes[n].ref2 >= 0 { wo(", "); w(dec_name(nodes[n].ref2)); }
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
    // A decoded reply is fresh and fits; an async function's result is a scalar.
    if nodes[n].k == E_AWAIT { emit_expr(n, true); return; }
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

// The reactive name a target writes: a name, or a field or element inside one; 0 for anything else.
fn lv_mask(n: i64) -> i64 {
    var x = n;
    while x >= 0 {
        let k = nodes[x].k;
        if k == E_NAME { return if nodes[x].ref2 >= 0 { rdecls[nodes[x].ref2].mask } else { 0 }; }
        if k != E_FIELD && k != E_INDEX { return 0; }
        x = nodes[x].a;
    }
    return 0;
}

// The names an expression writes by passing them to a `T&` parameter.
recursive fn call_marks(n: i64) -> i64 {
    if n < 0 { return 0; }
    let k = nodes[n].k;
    if k == E_FIELD || k == E_UN { return call_marks(nodes[n].a); }
    if k == E_INDEX || k == E_BIN { return call_marks(nodes[n].a) | call_marks(nodes[n].b); }
    if k == E_IF { return call_marks(nodes[n].a) | call_marks(nodes[n].b) | call_marks(nodes[n].c); }
    var m = 0;
    if k == E_SLIT {
        var f = nodes[n].a;
        while f >= 0 { m = m | call_marks(nodes[f].a); f = nodes[f].next; }
        return m;
    }
    if k == E_AWAIT { return call_marks(nodes[n].a); }
    if k != E_CALL { return 0; }
    let r = nodes[n].ref;
    var a = nodes[n].a;
    var i = 0;
    while a >= 0 {
        if r >= 0 && i < fns[r].n && params[fns[r].first + i].mref { m = m | lv_mask(a); } else { m = m | call_marks(a); }
        i += 1;
        a = nodes[a].next;
    }
    return m;
}

// The names statement n writes before it runs: its calls with `T&` arguments (the callee cannot mark them).
fn pre_marks(n: i64) -> i64 {
    let k = nodes[n].k;
    if k == S_LET || k == S_RETURN || k == S_RESULT || k == S_IF || k == S_WHILE { return call_marks(nodes[n].a); }
    if k == S_ASSIGN { return call_marks(nodes[n].b); }
    if k == S_FOR { return call_marks(nodes[n].a) | call_marks(nodes[n].b); }
    if k == S_EXPR {
        let e = nodes[n].a;
        if nodes[e].k == E_CALL && nodes[e].ref <= B_PUSH { return call_marks(arg_at(e, 1)); }
        return call_marks(e);
    }
    return 0;
}

// The name statement n writes itself: an assignment, ++, --, push, remove_at, clear or append.
fn stmt_marks(n: i64) -> i64 {
    let k = nodes[n].k;
    if k == S_ASSIGN || k == S_INCDEC { return lv_mask(nodes[n].a); }
    if k == S_EXPR {
        let e = nodes[n].a;
        if nodes[e].k == E_CALL && nodes[e].ref <= B_PUSH { return lv_mask(arg_at(e, 0)); }
    }
    return 0;
}

fn emit_mark(mask: i64) {
    w(c_js);
    w(".m(");
    format(js, mask);
    w(");");
}

// The await a statement starts with (let x: T = await ..., x = await ..., await ...), or -1.
fn await_of(n: i64) -> i64 {
    let k = nodes[n].k;
    var e = -1;
    if k == S_LET || k == S_EXPR { e = nodes[n].a; }
    else if k == S_ASSIGN { e = nodes[n].b; }
    if e >= 0 && nodes[e].k == E_AWAIT { return e; }
    return -1;
}

recursive fn emit_stmt(n: i64) {
    nl();
    if reactive {
        let pm = pre_marks(n);
        if pm != 0 { emit_mark(pm); nl(); }
        // Show what the handler has written so far before it waits.
        if await_of(n) >= 0 { w(c_js); w(".f();"); nl(); }
    }
    emit_stmt_body(n);
    if reactive {
        let sm = stmt_marks(n);
        if sm != 0 {
            if !compact { w(" "); }
            emit_mark(sm);
        }
    }
}

recursive fn emit_stmt_body(n: i64) {
    let k = nodes[n].k;
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

fn emit_line_note(line: i64) {
    if compact { return; }
    js.append("\n// ");
    js.append(src_path);
    format(js, ":", line, "\n");
}

fn emit_js_fn(i: i64) {
    let f = fns[i];
    emit_line_note(f.line);
    if reactive && f.is_async { w("async "); }
    w("function ");
    w(f.js);
    w("(");
    var first = true;
    if reactive && js_takes_s(i) {
        w(s_js);
        first = false;
        if js_takes_c(i) { wo(", "); w(c_js); }
    }
    for p in f.first..f.first + f.n {
        if !first { wo(", "); }
        first = false;
        w_var(params[p].var_id);
    }
    wo(") {");
    emit_block(f.body);
    if !compact { w("\n"); }
}

// Every field at its default, as State { .. } gives it.
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

// Handlers and tests of the def table: `name` or `name: f`, and for a function that does not take the
// change handle, the wrapper (s, c, ...a) => f(s, ...a) the runtime's call needs.
// The def key of lifecycle block bi: gw_m0 (mount), gw_u0 (unmount), gw_e0 (every), numbered per kind.
fn block_key(bi: i64) {
    var n = 0;
    for j in bi { if rblocks[j].kind == rblocks[bi].kind { n += 1; } }
    let k = rblocks[bi].kind;
    w(if k == RB_MOUNT { "gw_m" } else if k == RB_UNMOUNT { "gw_u" } else { "gw_e" });
    format(js, n);
}

fn emit_table(which: i64) {
    wo(": {");
    var first = true;
    for i in fns.len {
        let f = fns[i];
        if f.body < 0 { continue; }
        if (which == 0 && !f.handler) || (which == 1 && !f.test) { continue; }
        if !first { w(","); }
        if !compact { w(" "); }
        first = false;
        js.append(f.name);
        let wrap = which == 0 && (!reactive || !js_takes_c(i));
        if wrap {
            wo(": ");
            w("(");
            w(s_js);
            w(",");
            if !compact { w(" "); }
            w(c_js);
            w(",...");
            w(m_js);
            w(")");
            wo(" => ");
            w(f.js);
            w("(");
            if !reactive || js_takes_s(i) {
                w(s_js);
                w(",");
                if !compact { w(" "); }
            }
            w("...");
            w(m_js);
            w(")");
        } else if f.js != f.name { wo(": "); js.append(f.js); }
    }
    if which == 0 && reactive {
        // @mount, @unmount and @every bodies are handlers under reserved names.
        for bi in rblocks.len {
            let b = rblocks[bi];
            if b.kind == RB_WATCH { continue; }
            if !first { w(","); }
            if !compact { w(" "); }
            first = false;
            block_key(bi);
            wo(": ");
            if b.is_async { w("async "); }
            w("(");
            w(s_js);
            w(",");
            if !compact { w(" "); }
            w(c_js);
            w(")");
            wo(" => {");
            emit_block(b.body);
        }
    }
    if !compact && !first { w(" "); }
    w("}");
}

fn emit_component_call() {
    if !compact { w("\n"); }
    helper(H_COMPONENT);
    w("(\"");
    js.append(isl);
    w("\",");
    wo(" { ");
    if compact { w("render:"); w(render_js); w(",zero:"); w(zero_js); }
    else { w("render, zero"); }
    // u: render, then swap it in.
    wo(", ");
    w("u");
    wo(": ");
    if compact { w(s_js); } else { w("("); w(s_js); w(")"); }
    wo(" => {");
    wo(" ");
    w("const ");
    w(m_js);
    wo(" = ");
    w(render_js);
    w("(");
    w(s_js);
    w(");");
    wo(" ");
    w("return");
    wo(" (");
    w(p_js);
    wo(", ");
    w(root_js);
    wo(", ");
    w(f_js);
    w(")");
    wo(" => ");
    helper(H_SWAP);
    w("(");
    w(root_js);
    wo(", ");
    w(m_js);
    wo(", ");
    w(f_js);
    w(");");
    wo(" ");
    close_brace();
    wo(", ");
    w("h");
    emit_table(0);
    wo(", ");
    w("e");
    wo(": ");
    js_str(ev_types);
    wo(", ");
    w("tests");
    emit_table(1);
    wo(" });");
    if !compact { w("\n"); }
}

// ---------------------------------------------------------------- the reactive module (Addendum 12 section 3.3)

fn emit_zero_val(t: Ty) {
    if t.t == T_INT { w("0"); }
    else if t.t == T_BOOL { w_bool(false); }
    else if t.t == T_STR { w("\"\""); }
    else if t.t == T_ARRAY { w("[]"); }
    else if t.t == T_STRUCT {
        let si = find_struct(t.name);
        if si >= 0 { zero_obj(si, 0); } else { w("{}"); }
    } else { w("0"); }
}

// The decoders of the typed fetches (section 7.3): dK(value, path) returns a fresh checked value or throws the
// path of the first mismatch, which gwh.js turns into `bad reply from URL at PATH`. Structs are rebuilt field
// by field, so extra keys are dropped; a string is checked against its capacity in bytes.
fn dec_field(f: Field) {
    // The check of v.<f>, its path p + ".f".
    var path: u8[>..] = [];
    format(path, "p + \".", f.name, "\"");
    if f.kind == Kind.Int || f.kind == Kind.Bool {
        dec_bits = dec_bits | (if f.kind == Kind.Int { 1 } else { 2 });
        w(dec_check(if f.kind == Kind.Int { 'i' } else { 'b' }));
        w("(v.");
        w(f.name);
        wo(", ");
        wo(path);
        w(")");
    } else if f.kind == Kind.Str {
        dec_bits = dec_bits | 4;
        w(dec_check('s'));
        w("(v.");
        w(f.name);
        wo(", ");
        wo(path);
        wo(", ");
        format(js, f.cap);
        w(")");
    } else {
        var t = ty(if f.kind == Kind.Struct { T_STRUCT } else { T_ARRAY });
        t.name = f.struct_name;
        w(dec_name(dec_of(t)));
        w("(v.");
        w(f.name);
        wo(", ");
        wo(path);
        w(")");
    }
}

fn emit_decoders() {
    if decs.len == 0 { return; }
    dec_bits = 0;
    var k = 0;
    while k < decs.len {
        let t = decs[k];
        if !compact { w("\n"); }
        w("function ");
        w(dec_name(k));
        wo("(v, p) {");
        ind = 1;
        nl();
        if t.t == T_INT { dec_bits = dec_bits | 1; w("return "); w(dec_check('i')); wo("(v, p);"); }
        else if t.t == T_BOOL { dec_bits = dec_bits | 2; w("return "); w(dec_check('b')); wo("(v, p);"); }
        else if t.t == T_STR { dec_bits = dec_bits | 4; w("return "); w(dec_check('s')); wo("(v, p, "); format(js, t.cap); w(");"); }
        else if t.t == T_STRUCT {
            dec_bits = dec_bits | 8;
            w(dec_check('o'));
            wo("(v, p);");
            nl();
            w("return {");
            let si = find_struct(t.name);
            for q in structs[si].n {
                if q > 0 { w(","); }
                if !compact { w(" "); }
                let f = fields[structs[si].first + q];
                w(f.name);
                wo(": ");
                dec_field(f);
            }
            if !compact && structs[si].n > 0 { w(" "); }
            w("};");
        } else {
            dec_bits = dec_bits | 16;
            var et = ty(T_STRUCT);
            et.name = t.name;
            w("return ");
            w(dec_check('a'));
            wo("(v, p).map((x, i) => ");
            w(dec_name(dec_of(et)));
            wo("(x, p + \"[\" + i + \"]\"));");
        }
        ind = 0;
        nl();
        close_brace();
        if !compact { w("\n"); }
        k += 1;
    }
    for c in "ibsoa" {
        let bit = if c == 'i' { 1 } else if c == 'b' { 2 } else if c == 's' { 4 } else if c == 'o' { 8 } else { 16 };
        if (dec_bits & bit) == 0 { continue; }
        w("function ");
        w(dec_check(c));
        wo(if c == 's' { "(v, p, n) {" } else { "(v, p) {" });
        ind = 1;
        nl();
        if c == 'i' { wo("if (!Number.isSafeInteger(v)) throw p; "); w("return v;"); }
        else if c == 'b' { wo("if (typeof v != \"boolean\") throw p; "); w("return v;"); }
        else if c == 's' {
            wo("if (typeof v != \"string\" || ");
            helper(H_BLEN);
            wo("(v) > n) throw p; ");
            w("return v;");
        }
        else if c == 'o' { wo("if (!v || typeof v != \"object\" || Array.isArray(v)) throw p;"); }
        else { wo("if (!Array.isArray(v)) throw p; "); w("return v;"); }
        ind = 0;
        nl();
        close_brace();
        if !compact { w("\n"); }
    }
}

var vbase = 0;

// The name of part i's new value in update.
fn part_name(i: i64) -> u8[..72] {
    var n: u8[..72] = "";
    if compact { n.append(short_name(vbase + i)); return n; }
    format(n, "v", i);
    while name_taken(n) { n.push('$'); }
    return n;
}

// Appends src to dst; each line break is followed by `extra` more levels of indentation.
fn append_indented(dst: u8[>..]&, src: const u8[:], extra: i64) {
    for c in src {
        dst.push(c);
        if c == '\n' { for k in extra { dst.append("  "); } }
    }
}

// Part i's new value, a string expression: the part's own, or an immediately called function running its statements.
fn part_value(i: i64) {
    let pt = parts[i];
    let code = pcode[pt.s..pt.e];
    if pt.simple { js.append(code); return; }
    wo("(() => {");
    ind += 1;
    nl();
    w("let ");
    w(o_js);
    wo(" = ");
    w("\"\";");
    if !compact { nl(); }
    append_indented(js, code, 1);
    nl();
    w("return ");
    w(o_js);
    w(";");
    ind -= 1;
    nl();
    w("})()");
}

// update(s, m): phase 1. The computeds in order, each when a name it reads changed; the new value of each
// part that reads a changed name; the function that writes them.
fn emit_reactive_update() {
    if !compact { w("\n"); }
    w("function ");
    w(u_js);
    w("(");
    w(s_js);
    wo(", ");
    w(m_js);
    wo(") {");
    ind = 1;
    vbase = fcount;
    for k in rorder.len {
        let d = rdecls[rorder[k]];
        if d.r == 0 || !has_init_fn(d) { continue; }
        nl();
        wo("if (");
        w(m_js);
        wo(" & ");
        format(js, d.r);
        wo(") {");
        ind += 1;
        nl();
        w(s_js);
        w(".");
        w(d.name);
        wo(" = ");
        emit_val(d.init, d.ty);
        w(";");
        nl();
        w(m_js);
        wo(" |= ");
        format(js, d.mask);
        w(";");
        ind -= 1;
        nl();
        close_brace();
    }
    var any = false;
    for pt in parts { if pt.r != 0 { any = true; } }
    if any { js.append(letcode); }
    var first = true;
    for i in parts.len {
        let pt = parts[i];
        if pt.r == 0 { continue; }
        if compact { if first { w("const "); } else { w(","); } }
        else { nl(); w("const "); }
        first = false;
        w(part_name(i));
        wo(" = ");
        w(m_js);
        wo(" & ");
        format(js, pt.r);
        wo(" && ");
        part_value(i);
        if !compact { w(";"); }
    }
    if compact && !first { w(";"); }
    nl();
    w("return");
    if first { wo(" () => {}"); }
    else {
        wo(" (");
        w(p_js);
        wo(", ");
        w(root_js);
        wo(", ");
        w(f_js);
        w(")");
        wo(" => {");
        ind += 1;
        for i in parts.len {
            let pt = parts[i];
            if pt.r == 0 { continue; }
            nl();
            w(m_js);
            wo(" & ");
            format(js, pt.r);
            wo(" && ");
            if pt.kind == PK_CHILD {
                child_use = child_use | 2;
                w(gwc_name(2));
            } else {
                // A block that holds child calls reads its children's state before the morph moves their scripts.
                if pt.kind == PK_BLOCK && pt.kids {
                    child_use = child_use | 4;
                    w("(");
                    w(gwc_name(4));
                    w("(");
                    w(p_js);
                    w("[");
                    format(js, i);
                    w("]");
                    wo("), ");
                }
                helper(if pt.kind == PK_TEXT { H_T } else if pt.kind == PK_ATTR { H_A } else { H_B });
            }
            w("(");
            w(p_js);
            w("[");
            format(js, i);
            w("]");
            wo(", ");
            w(part_name(i));
            if pt.kind == PK_ATTR || pt.kind == PK_BLOCK { wo(", "); w(f_js); }
            if pt.kind == PK_BLOCK && pt.kids { w(")"); }
            w(");");
        }
        ind -= 1;
        nl();
        close_brace();
    }
    w(";");
    ind = 0;
    nl();
    close_brace();
    if !compact { w("\n"); }
}

// watch(s, m, c): each @watch body when a name it reads changed. False when there is none.
fn emit_reactive_watch() -> bool {
    var any = false;
    for b in rblocks { if b.kind == RB_WATCH && b.r != 0 { any = true; } }
    if !any { return false; }
    w("function ");
    w(w_js);
    w("(");
    w(s_js);
    wo(", ");
    w(m_js);
    wo(", ");
    w(c_js);
    wo(") {");
    ind = 1;
    for bi in rblocks.len {
        let b = rblocks[bi];
        if b.kind != RB_WATCH || b.r == 0 { continue; }
        nl();
        wo("if (");
        w(m_js);
        wo(" & ");
        format(js, b.r);
        wo(") {");
        emit_block(b.body);
    }
    ind = 0;
    nl();
    close_brace();
    if !compact { w("\n"); }
    return true;
}

// init(p): the whole state from a props object (a missing prop is zero), the initializers in order, the computeds sorted.
fn emit_reactive_init() {
    w("function ");
    w(i_js);
    w("(");
    w(p_js);
    wo(") {");
    ind = 1;
    nl();
    w("const ");
    w(s_js);
    wo(" = {");
    if !compact { w(" "); }
    // The keys come in the order of the Goose gw_json (props, state, computeds, the array), so JSON.stringify of
    // the state is what the server writes (gwc.js's H).
    for pass in 4 {
        for d in rdecls {
            if pass == 0 { if d.kind != R_PROP { continue; } }
            else if !in_state(d, pass - 1) { continue; }
            w(d.name);
            wo(": ");
            emit_zero_val(d.ty);
            w(",");
            if !compact { w(" "); }
        }
    }
    w("...");
    w(p_js);
    if !compact { w(" "); }
    w("};");
    for d in rdecls {
        if d.kind != R_STATE || !has_init_fn(d) { continue; }
        nl();
        w(s_js);
        w(".");
        w(d.name);
        wo(" = ");
        emit_val(d.init, d.ty);
        w(";");
    }
    for k in rorder.len {
        let d = rdecls[rorder[k]];
        if !has_init_fn(d) { continue; }
        nl();
        w(s_js);
        w(".");
        w(d.name);
        wo(" = ");
        emit_val(d.init, d.ty);
        w(";");
    }
    nl();
    w("return ");
    w(s_js);
    w(";");
    ind = 0;
    nl();
    close_brace();
    if !compact { w("\n"); }
}

fn emit_reactive_call(watch: bool) {
    helper(H_COMPONENT);
    w("(\"");
    js.append(isl);
    w("\",");
    wo(" { ");
    w("r");
    wo(": ");
    w(render_js);
    wo(", ");
    w("u");
    wo(": ");
    w(u_js);
    if watch {
        wo(", ");
        w("w");
        wo(": ");
        w(w_js);
    }
    wo(", ");
    w("i");
    wo(": ");
    w(i_js);
    wo(", ");
    w("h");
    emit_table(0);
    wo(", ");
    w("b");
    wo(": {");
    for d, k in rdecls {
        if k > 0 { w(","); }
        if !compact { w(" "); }
        w(d.name);
        wo(": ");
        format(js, d.mask);
    }
    if !compact && rdecls.len > 0 { w(" "); }
    w("}");
    // x: the names each async handler writes, which a failure restores.
    var anyx = false;
    for f in fns { if f.handler && f.is_async && f.body >= 0 { anyx = true; } }
    for b in rblocks { if b.kind != RB_WATCH && b.is_async { anyx = true; } }
    if anyx {
        wo(", ");
        w("x");
        wo(": {");
        var firstx = true;
        for f in fns {
            if !f.handler || !f.is_async || f.body < 0 { continue; }
            if !firstx { w(","); }
            if !compact { w(" "); }
            firstx = false;
            js.append(f.name);
            wo(": ");
            format(js, f.w);
        }
        for bi in rblocks.len {
            if rblocks[bi].kind == RB_WATCH || !rblocks[bi].is_async { continue; }
            if !firstx { w(","); }
            if !compact { w(" "); }
            firstx = false;
            block_key(bi);
            wo(": ");
            format(js, rblocks[bi].w);
        }
        if !compact { w(" "); }
        w("}");
    }
    // l: the lifecycle entries: mount keys, unmount keys, [ms, key] intervals.
    if rblocks.len > 0 {
        var any = false;
        for b in rblocks { if b.kind != RB_WATCH { any = true; } }
        if any {
            wo(", ");
            w("l");
            wo(": {");
            var firstl = true;
            for kind in 1..4 {
                if kind == RB_EVERY { wo(" v: ["); } else if kind == RB_MOUNT { wo(" m: ["); } else { wo(" u: ["); }
                var firstk = true;
                for bi in rblocks.len {
                    if rblocks[bi].kind != kind { continue; }
                    if !firstk { w(","); }
                    firstk = false;
                    if kind == RB_EVERY { w("["); format(js, rblocks[bi].ms); w(","); }
                    w("\"");
                    block_key(bi);
                    w("\"");
                    if kind == RB_EVERY { w("]"); }
                }
                w("]");
                if kind < 3 { w(","); }
            }
            if !compact { w(" "); }
            w("}");
        }
    }
    var pm = 0;
    for d in rdecls { if d.kind == R_PROP { pm = pm | d.mask; } }
    wo(", ");
    w("p");
    wo(": ");
    format(js, pm);
    wo(", ");
    w("e");
    wo(": ");
    js_str(ev_types);
    wo(", ");
    w("t");
    emit_table(1);
    wo(" });");
    if !compact { w("\n"); }
    // A component with any block starts eagerly (Addendum 12, 7.2).
    if rblocks.len > 0 {
        life_use = 1;
        w(if compact { "$l" } else { "life" });
        w("(");
        js_str(isl);
        w(");");
        if !compact { w("\n"); }
    }
}

// ---------------------------------------------------------------- markup

fn mtext(s: const u8[:]) {
    gtext.append(s);
    pend.append(s);
}

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

// A raw piece first in the statement is prefixed with "" so + concatenates.
fn cat_expr(raw: bool) {
    cat_pend();
    cat_start();
    if cat_first && raw { w("\"\""); cat_first = false; }
    cat_plus();
}

// ---------------------------------------------------------------- parts (Addendum 12 section 3.2)

fn is_name_ch(c: u8) -> bool { return is_alpha(c) || is_dig(c) || c == '-' || c == ':'; }

// Does the `on:` attribute at line[from..] pass an argument that names something? A name may read state; a
// literal cannot. (A top-level tag is a part only when its arguments may read state.)
fn on_args_dynamic(line: const u8[:], from: i64) -> bool {
    var q = from + 3;
    while q < line.len && line[q] >= 'a' && line[q] <= 'z' { q += 1; }
    if !(q + 1 < line.len && line[q] == '=' && (line[q + 1] == '"' || line[q + 1] == '\'')) { return false; }
    let qc = line[q + 1];
    var e = q + 2;
    while e < line.len && line[e] != qc { e += 1; }
    var i = q + 2;
    var par = false;
    while i < e {
        let c = line[i];
        if c == '(' { par = true; i += 1; continue; }
        if !par { i += 1; continue; }
        let j = tscan::skip_literal(line, i);
        if j > i { i = j; continue; }
        if is_alpha(c) {
            var k = i;
            while k < e && (is_alpha(line[k]) || is_dig(line[k])) { k += 1; }
            let word = line[i..k];
            if word != "true" && word != "false" { return true; }
            i = k;
            continue;
        }
        i += 1;
    }
    return false;
}

// One pass over the markup before it is compiled: the open tags that are parts (they hold a { }, a bind:, or
// an on: with a name in its arguments), HTML comments, and the content of <textarea>s. Reactive components only.
fn scan_parts(first_line: i64) {
    var st = tscan::MARKUP;
    var in_tag = false;
    var closing = false;
    var quote: u8 = 0;
    var comment = false;
    var comment_s = 0;
    var tag_s = 0;
    var tag_ne = 0;
    var tag_depth = 0;
    var dyn = false;
    var is_ta = false;
    var ta_open = false;
    var ta_s = 0;
    var depth = 0;
    for li in first_line..line_start.len {
        let base = line_start[li];
        var line: u8[>..] = [];
        line.append(text[base..line_end[li]]);
        var p = 0;
        while p < line.len {
            if tscan::is_raw(st) { p = tscan::raw_end(line, p, st); continue; }
            let at = tscan::next(line, p, st, true);
            var i = p;
            while i < at {
                let c = line[i];
                let off = base + i;
                if comment {
                    if c == '-' && starts_with(line[i..at], "-->") {
                        comment = false;
                        pspans.push(PSpan { kind: PS_COMMENT, s: comment_s, ne: comment_s, e: off });
                        i += 3;
                        continue;
                    }
                    i += 1;
                    continue;
                }
                if in_tag {
                    if quote != 0 { if c == quote { quote = 0; } i += 1; continue; }
                    if c == '"' || c == '\'' { quote = c; i += 1; continue; }
                    if c == '>' {
                        in_tag = false;
                        if !closing {
                            if dyn && tag_depth == 0 { pspans.push(PSpan { kind: PS_TAG, s: tag_s, ne: tag_ne, e: off }); }
                            if is_ta { ta_open = true; ta_s = off + 1; }
                        }
                        i += 1;
                        continue;
                    }
                    let ws = i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t';
                    if !closing && ws && starts_with(line[i..at], "bind:") { dyn = true; }
                    if !closing && ws && starts_with(line[i..at], "on:") && on_args_dynamic(line, i) { dyn = true; }
                    i += 1;
                    continue;
                }
                if c != '<' { i += 1; continue; }
                if ta_open {
                    if tscan::starts_nocase(line, i, "</textarea") {
                        pspans.push(PSpan { kind: PS_TEXTAREA, s: ta_s, ne: ta_s, e: off });
                        ta_open = false;
                    } else { i += 1; continue; }
                }
                if starts_with(line[i..at], "<!--") { comment = true; comment_s = off + 4; i += 4; continue; }
                if i + 1 < at && line[i + 1] == '/' {
                    in_tag = true;
                    closing = true;
                    quote = 0;
                    i += 2;
                    continue;
                }
                if i + 1 < at && is_alpha(line[i + 1]) {
                    var j = i + 1;
                    while j < at && is_name_ch(line[j]) { j += 1; }
                    in_tag = true;
                    closing = false;
                    quote = 0;
                    dyn = false;
                    tag_s = off;
                    tag_ne = base + j;
                    tag_depth = depth;
                    is_ta = tscan::starts_nocase(line, i + 1, "textarea") && j == i + 9;
                    i = j;
                    continue;
                }
                i += 1;
            }
            p = at;
            if at == line.len || tscan::is_raw(st) { continue; }
            if line[at] == '}' { p = at + 1; continue; }
            if line[at] == '@' {
                let open = tscan::call_open(line, at);
                let close = tscan::paren_end(line, open);
                if close < 0 { break; }
                p = close + 1;
                continue;
            }
            if starts_with(line[at..], "{{") { break; }
            if starts_with(line[at..], "{--") {
                let e = find(line[at..], "--}");
                if e < 0 { break; }
                p = at + e + 3;
                continue;
            }
            let e = tscan::brace_end(line, at);
            if e < 0 { break; }
            p = e + 1;
            if in_tag && !comment { dyn = true; }
            let inner = trim(line[at + 1..e]);
            if starts_with(inner, "#if ") || starts_with(inner, "#for ") { depth += 1; }
            else if inner == "/if" || inner == "/for" { depth = max(0, depth - 1); }
        }
    }
}

// The kind of span that holds source offset q, or -1.
fn span_kind_at(q: i64) -> i64 {
    for sp in pspans {
        if q >= sp.s && q < sp.e { return sp.kind; }
    }
    return -1;
}

fn next_tag() -> i64 {
    while ptag < pspans.len && pspans[ptag].kind != PS_TAG { ptag += 1; }
    return if ptag < pspans.len { ptag } else { -1 };
}

// The source offset of the next event of the dynamic tags: the `<`, the end of the name, the `>`.
fn next_ev() -> i64 {
    let t = next_tag();
    if t < 0 { return -1; }
    if ptag_phase == 0 { return pspans[t].s; }
    if ptag_phase == 1 { return pspans[t].ne; }
    return pspans[t].e;
}

fn part_begin(kind: i64) -> i64 {
    parts.push(RPart { kind: kind, r: 0, s: 0, e: 0, simple: true, kids: false });
    return parts.len - 1;
}

fn part_end(i: i64, r: i64, code: const u8[:], simple: bool) {
    parts[i].r = r;
    parts[i].s = pcode.len;
    pcode.append(code);
    parts[i].e = pcode.len;
    parts[i].simple = simple;
}

// js[from..] as one string expression: the text pieces `+ a + b` lose their first +.
fn region_expr(from: i64) -> u8[>..] {
    var r: u8[>..] = [];
    var i = from;
    while i < js.len && (js[i] == ' ' || js[i] == '\n') { i += 1; }
    if i < js.len && js[i] == '+' { i += 1; }
    while i < js.len && js[i] == ' ' { i += 1; }
    r.append(js[i..js.len]);
    return r;
}

// js[from..] as statements: a first text piece `+ a` continues the statement that was open, and becomes `o += a`.
fn region_stmts(from: i64) -> u8[>..] {
    var r: u8[>..] = [];
    var i = from;
    while i < js.len && (js[i] == ' ' || js[i] == '\n') { i += 1; }
    if i < js.len && js[i] == '+' {
        r.append(o_js);
        r.append(if compact { "+=" } else { " +=" });
        r.append(js[i + 1..js.len]);
    } else if i < js.len && js[i] == ';' {
        r.append(js[i + 1..js.len]);
    } else {
        r.append(js[i..js.len]);
    }
    return r;
}

fn end_attr_part() {
    let i = pr_open;
    pr_open = -1;
    if i < 0 { return; }
    if n_flow == pr_flow {
        part_end(i, pr_acc, region_expr(pr_ra), true);
    } else {
        var c = region_stmts(pr_ra);
        if cat_open { c.push(';'); }
        part_end(i, pr_acc, c, false);
    }
}

// The closing of a top-level {#if} or {#for}: its code is the statements since pr_ra.
fn end_block_part(i: i64) {
    pr_open = -1;
    part_end(i, pr_acc, region_stmts(pr_ra), false);
    mtext("<!--/g-->");
}

// One event of the next dynamic tag: its marker, the start of its attribute list, its end.
fn fire_one() {
    if next_tag() < 0 { return; }
    if ptag_phase == 0 {
        mtext("<!--g-->");
        pr_open = part_begin(PK_ATTR);
        pr_acc = 0;
        ptag_phase = 1;
    } else if ptag_phase == 1 {
        cat_pend();
        pr_ra = js.len;
        pr_flow = n_flow;
        ptag_phase = 2;
    } else {
        cat_pend();
        end_attr_part();
        ptag_phase = 0;
        ptag += 1;
    }
}

// Fires the events at or before source offset x.
fn fire_to(x: i64) {
    if !reactive { return; }
    loop {
        let ev = next_ev();
        if ev < 0 || ev > x { return; }
        fire_one();
    }
}

// Markup text[a..b]; in a reactive component the events inside it split it.
fn m_chunk(a: i64, b: i64) {
    if !reactive { mtext(text[a..b]); return; }
    var p = a;
    loop {
        fire_to(p);
        let ev = next_ev();
        if ev < 0 || ev >= b { break; }
        mtext(text[p..ev]);
        p = ev;
    }
    mtext(text[p..b]);
}

// Does a tag, a closing tag or a comment start at source offset at?
fn tag_follows(at: i64) -> bool {
    if at + 1 >= text.len || text[at] != '<' { return false; }
    let c = text[at + 1];
    return is_alpha(c) || c == '/' || c == '!';
}

fn set_var_r(v: i64, r: i64) {
    while var_r.len <= v { var_r.push(0); }
    var_r[v] = r;
}

// Expression n as the update function needs it: a string, as a part's new text. It is written to js and taken back.
fn snip_value(n: i64) -> u8[>..] {
    let keep = js.len;
    if nodes[n].ty.t != T_STR { w("\"\""); wo(" + "); }
    emit_expr(n, false);
    var r: u8[>..] = [];
    r.append(js[keep..js.len]);
    js.resize(keep);
    return r;
}

fn add_event(e: const u8[:]) {
    var hay: u8[>..] = [];
    format(hay, " ", ev_types, " ");
    var needle: u8[>..] = [];
    format(needle, " ", e, " ");
    if find(hay, needle) >= 0 { return; }
    if ev_types.len > 0 { ev_types.push(' '); }
    ev_types.append(e);
}

// Tagged with the source line so gweb can map a compiler error back to the markup.
fn chk_line(s: const u8[:], line: i64) {
    chk.append(s);
    format(chk, "   // gw:line ", line, "\n");
}

fn parse_tag_expr(s: i64, e: i64, line: i64) -> i64 {
    pos = tokenize(s, e, line);
    perr = false;
    let n = parse_expr(false);
    if perr { perr = false; return -1; }
    if !at_k(K_EOF) { bad_tok(pos); perr = false; return -1; }
    return n;
}

fn m_expr(s: i64, e: i64, line: i64, raw: bool) {
    // In a reactive component an expression outside every block and open tag is a part: markers around it.
    var part = -1;
    if reactive {
        let sk = span_kind_at(s);
        if sk == PS_TEXTAREA { report(line, "use bind:value on <textarea>"); }
        else if sk < 0 && opens.len == 0 {
            part = part_begin(if raw { PK_BLOCK } else { PK_TEXT });
            mtext("<!--g-->");
        }
    }
    g_flush();
    let n = parse_tag_expr(s, e, line);
    var rbits = 0;
    if n >= 0 {
        check_expr(n);
        if reactive { rw_mark(n, line, if raw { RM_RAW } else { RM_TEXT }); rbits = rw_r; rec_expr(n); }
    }
    format(gline, if raw { "web::raw(out, " } else { "web::put(out, " }, rewrite(s, e), "); ");
    if n < 0 { return; }
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
    if part >= 0 {
        part_end(part, rbits, snip_value(n), true);
        if raw { mtext("<!--/g-->"); }
        else if !tag_follows(mk_after) { mtext("<!---->"); }
    }
}

fn open_tag(kind: u8, line: i64, part: i64) {
    opens.push(Open { kind: kind, line: line, mark: scope.len, part: part });
}

// A top-level {#if} or {#for} of a reactive component is a block part; its marker goes before the open.
fn block_top(s: i64) -> bool {
    if !reactive || opens.len > 0 || span_kind_at(s) >= 0 { return false; }
    mtext("<!--g-->");
    return true;
}

fn block_open(top: bool) -> i64 {
    if !top { return -1; }
    pr_open = part_begin(PK_BLOCK);
    pr_acc = 0;
    pr_ra = js.len;
    return pr_open;
}

// The Goose line and gw_check get the condition as rewritten for reactive names.
fn if_head(s: i64, e: i64, line: i64, else_if: bool) {
    var head: u8[>..] = [];
    format(head, if else_if { "} else if " } else { "if " }, rewrite(s, e), " {");
    gline.append(head);
    gline.push(' ');
    chk_line(head, line);
}

fn m_if(s: i64, e: i64, line: i64, else_if: bool) {
    let top = !else_if && block_top(s);
    g_flush();
    cat_close();
    let part = block_open(top);
    if !else_if { n_flow += 1; }
    if else_if {
        if opens.len == 0 || opens[opens.len - 1].kind != 'i' {
            if_head(s, e, line, else_if);
            report(line, "{#else if} outside {#if}");
            return;
        }
        scope.resize(opens[opens.len - 1].mark);
        ind -= 1;
    } else {
        open_tag('i', line, part);
    }
    nl();
    if else_if { wo("} else if ("); } else { wo("if ("); }
    let n = parse_tag_expr(s, e, line);
    if n >= 0 {
        check_expr(n);
        if reactive { rw_mark(n, line, RM_IF); rec_expr(n); }
        let t = nodes[n].ty.t;
        if t != T_ERR && t != T_BOOL { cannot_type(line); }
        else if t == T_BOOL { emit_expr(n, true); }
    }
    if_head(s, e, line, else_if);
    wo(") {");
    ind += 1;
}

fn m_else(line: i64) {
    g_code("} else { ");
    chk_line("} else {", line);
    cat_close();
    if opens.len == 0 || opens[opens.len - 1].kind != 'i' { report(line, "{#else} outside {#if}"); return; }
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
        report(line, if want == 'i' { "{/if} does not close an open {#if}" } else { "{/for} does not close an open {#for}" });
        return;
    }
    scope.resize(opens[opens.len - 1].mark);
    let part = opens[opens.len - 1].part;
    opens.pop();
    ind -= 1;
    nl();
    close_brace();
    if part >= 0 { end_block_part(part); }
}

fn m_for(s: i64, e: i64, line: i64) {
    let top = block_top(s);
    g_flush();
    cat_close();
    open_tag('f', line, block_open(top));
    n_flow += 1;
    pos = tokenize(s, e, line);
    perr = false;
    let n = new_node(S_FOR, pos);
    var ok = parse_for_head(n);
    if ok && !at_k(K_EOF) { bad_tok(pos); ok = false; }
    perr = false;
    nl();
    if ok {
        check_for_head(n);
        if reactive {
            rw_mark(nodes[n].a, line, RM_FOR);
            rw_mark(nodes[n].b, line, RM_FOR);
            rec_expr(nodes[n].a);
            rec_expr(nodes[n].b);
        }
        emit_for_head(n);
    } else {
        wo("for (;;) {");
    }
    ind += 1;
    var head: u8[>..] = [];
    format(head, "for ", rewrite(s, e), " {");
    gline.append(head);
    gline.push(' ');
    chk_line(head, line);
}

fn m_let(s: i64, e: i64, line: i64) {
    g_flush();
    cat_close();
    pos = tokenize(s, e, line);
    perr = false;
    let n = new_node(S_LET, pos);
    var ok = parse_let_head(n);
    if ok && !at_k(K_EOF) { bad_tok(pos); ok = false; }
    perr = false;
    if ok {
        check_let(n);
        if reactive { rw_mark(nodes[n].a, line, RM_LET); set_var_r(nodes[n].ref, rw_r); rec_expr(nodes[n].a); }
    }
    n_flow += 1;
    var head: u8[>..] = [];
    format(head, "let ", rewrite(s, e), ";");
    gline.append(head);
    gline.push(' ');
    chk_line(head, line);
    if !ok { return; }
    let la = js.len;
    nl();
    w("let ");
    w_var(nodes[n].ref);
    wo(" = ");
    emit_val(nodes[n].a, nodes[n].ty);
    w(";");
    // A top-level {#let} is not a part, but update computes it again for the parts that read it.
    if reactive && opens.len == 0 && span_kind_at(s) < 0 { letcode.append(js[la..js.len]); }
}

// on: in a reactive component: any function of the component whose parameters are i64, bool or const u8[:].
fn m_on_r(event: const u8[:], mods: const u8[:], vs: i64, ve: i64, line: i64) {
    let n = parse_tag_expr(vs, ve, line);
    if n < 0 { return; }
    var name_tok = -1;
    if nodes[n].k == E_NAME { name_tok = nodes[n].tok; }
    else if nodes[n].k == E_CALL && nodes[n].c != 1 && nodes[n].d < 0 { name_tok = nodes[n].tok; }
    var fi = -1;
    if name_tok >= 0 { fi = find_fn(text[toks[name_tok].s..toks[name_tok].e]); }
    let shown = if name_tok >= 0 { text[toks[name_tok].s..toks[name_tok].e] } else { text[vs..ve] };
    var m: u8[>..] = [];
    if fi < 0 || fns[fi].event {
        format(m, "on:", event, " handler '", shown, "' is not a function of this component");
        report(line, m);
        return;
    }
    for p in fns[fi].first..fns[fi].first + fns[fi].n {
        let pt = params[p].ty.t;
        if params[p].mref || (pt != T_INT && pt != T_BOOL && pt != T_STR) {
            format(m, "on:", event, " handler '", shown, "' takes only i64, bool and const u8[:] parameters");
            report(line, m);
            return;
        }
    }
    let na = if nodes[n].k == E_CALL { args_count(n) } else { 0 };
    if na != fns[fi].n {
        format(m, "on:", event, " handler '", shown, "' is called with ", na, " arguments; it takes ", fns[fi].n);
        report(line, m);
        return;
    }
    var t: u8[>..] = [];
    format(t, "data-on-", event, "=\"", shown, mods, "\"");
    mtext(t);
    add_event(event);
    // gw_check calls the handler as the Goose compiler will see it: name(gw_p, gw_w, args) or name(args).
    var call: u8[>..] = [];
    format(call, shown, "(");
    if takes_state(fi) {
        call.append("gw_p, gw_w");
        if na > 0 { call.append(", "); }
    }
    if na > 0 { mtext(" data-args=\"["); }
    var a = nodes[n].a;
    if nodes[n].k != E_CALL { a = -1; }
    var i = 0;
    while a >= 0 {
        check_expr(a);
        rw_mark(a, line, RM_ON);
        rec_expr(a);
        let at = nodes[a].ty.t;
        if at != T_ERR && at != params[fns[fi].first + i].ty.t {
            m.clear();
            format(m, "on:", event, " handler '", shown, "': argument ", i + 1, " has the wrong type");
            report(line, m);
        }
        let src = rewrite(span_s(a), span_e(a));
        if i > 0 { mtext(","); call.append(", "); }
        call.append(src);
        g_flush();
        format(gline, "web::arg(out, ", src, "); ");
        if at != T_ERR {
            cat_expr(false);
            helper(H_ESC);
            w("(");
            if at == T_STR { w("JSON.stringify("); emit_expr(a, true); w(")"); } else { emit_expr(a, true); }
            w(")");
        }
        i += 1;
        a = nodes[a].next;
    }
    if na > 0 { mtext("]\""); }
    call.append(");");
    chk_line(call, line);
}

fn m_on(event: const u8[:], mods: const u8[:], vs: i64, ve: i64, line: i64) {
    if mods.len > 0 { mods_use = 1; }
    if reactive { m_on_r(event, mods, vs, ve, line); return; }
    add_event(event);
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
    format(t, "data-on-", event, "=\"", fname, mods, "\"");
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

// bind: in a reactive component: a @state var of type i64, bool or u8[..N] (bool for checked).
fn m_bind_r(what: const u8[:], vs: i64, ve: i64, line: i64) {
    let field = trim(text[vs..ve]);
    let d = find_rdecl(field);
    var m: u8[>..] = [];
    if d < 0 {
        format(m, "bind:", what, " needs a @state var; '", field, "' is not one");
        report(line, m);
        return;
    }
    if rdecls[d].kind != R_STATE {
        let mk = rmark(rdecls[d].kind);
        format(m, "bind:", what, " needs a @state var; '", field, "' is ", mk);
        report(line, m);
        return;
    }
    let t = rdecls[d].ty;
    if t.t == T_ERR { return; }
    if what == "checked" {
        if t.t != T_BOOL { report(line, "bind:checked needs a @state var of type bool"); return; }
    } else if t.t != T_INT && t.t != T_BOOL && t.t != T_STR {
        format(m, "bind:", what, " needs a @state var of type i64, bool or u8[..N]");
        report(line, m);
        return;
    }
    rmarks.push(RMk { kind: RM_BIND, line: line, r: rdecls[d].mask, w: rdecls[d].mask });
    mk_r = mk_r | rdecls[d].mask;
    if pr_open >= 0 { pr_acc = pr_acc | rdecls[d].mask; }
    var code: u8[>..] = [];
    var tail: u8[>..] = [];
    if what == "value" {
        mtext("value=\"");
        format(code, "web::put(out, gw_s.", field, "); ");
        g_code(code);
        cat_expr(false);
        helper(H_ESC);
        w("(");
        w(s_js);
        w(".");
        w(field);
        w(")");
        format(tail, "\" data-bind=\"", field, "\"");
        if t.t == T_STR { format(tail, " data-cap=\"", t.cap, "\""); }
        mtext(tail);
        return;
    }
    format(code, "if gw_s.", field, " { ");
    g_code(code);
    gtext.append("checked");
    g_code("} ");
    // The same text as a conditional piece, so the attribute list stays one string expression.
    cat_expr(false);
    w("(");
    w(s_js);
    w(".");
    w(field);
    wo(" ? ");
    js_str("checked");
    wo(" : ");
    w("\"\"");
    w(")");
    format(tail, " data-bind=\"", field, "\"");
    mtext(tail);
}

fn m_bind(what: const u8[:], vs: i64, ve: i64, line: i64) {
    if reactive { m_bind_r(what, vs, ve, line); return; }
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

fn next_attr(p: i64, e: i64) -> i64 {
    for i in p..e {
        if i == 0 { continue; }
        let prev = text[i - 1];
        if prev != ' ' && prev != '\t' && prev != '\n' { continue; }
        if starts_with(text[i..e], "on:") || starts_with(text[i..e], "bind:") { return i; }
    }
    return -1;
}

// on:EVENT.MOD.MOD (Addendum 12, 7.2b). mods is "" or ".mod.mod". An unknown event is a warning; a bad modifier an error.
fn on_event_ok(event: const u8[:], mods: const u8[:], line: i64) -> bool {
    if event.len == 0 { report(line, "on: needs an event name"); return false; }
    let known = event == "click" || event == "dblclick" || event == "change" || event == "input" || event == "submit"
        || event == "keydown" || event == "keyup" || event == "focus" || event == "blur";
    if !known {
        var w: u8[>..] = [];
        format(w, "unknown on: event '", event, "'");
        warn_buf("unknown-event", line, w);
    }
    var ok = true;
    var i = 0;
    while i < mods.len {
        var j = i + 1;
        while j < mods.len && mods[j] != '.' { j += 1; }
        let m = mods[i + 1..j];
        i = j;
        var msg: u8[>..] = [];
        if m == "prevent" || m == "stop" { continue; }
        if m.len > 0 && m[0] >= '0' && m[0] <= '9' {
            var n = 0;
            var k = 0;
            while k < m.len && m[k] >= '0' && m[k] <= '9' && n < 100000 { n = n * 10 + (m[k] - '0'); k += 1; }
            if m[k..m.len] != "ms" || n < 1 || n > 10000 {
                report(line, "a debounce is 1ms to 10000ms");
                ok = false;
            }
            continue;
        }
        if m == "enter" || m == "escape" || m == "space" || m == "tab" || m == "up" || m == "down" || m == "left"
            || m == "right" || m == "backspace" || m == "delete" {
            if event != "keydown" && event != "keyup" {
                format(msg, ".", m, " works on on:keydown and on:keyup only");
                report(line, msg);
                ok = false;
            }
            continue;
        }
        format(msg, "unknown modifier .", m, " on on:", event);
        report(line, msg);
        ok = false;
    }
    return ok;
}

// Attribute values take double or single quotes; there is no escape syntax, and output attributes are always double-quoted.
fn m_text(s: i64, e: i64, line: i64) {
    var p = s;
    while p < e {
        let k = next_attr(p, e);
        if k < 0 { m_chunk(p, e); return; }
        m_chunk(p, k);
        let on = text[k] == 'o';
        let name_s = k + (if on { 3 } else { 5 });
        var q = name_s;
        while q < e && text[q] >= 'a' && text[q] <= 'z' { q += 1; }
        let name_e = q;
        if on {
            while q < e && text[q] == '.' {
                q += 1;
                while q < e && ((text[q] >= 'a' && text[q] <= 'z') || (text[q] >= '0' && text[q] <= '9')) { q += 1; }
            }
        }
        let quoted = q + 1 < e && text[q] == '=' && (text[q + 1] == '"' || text[q + 1] == '\'');
        var ve = q + 2;
        if quoted {
            let qc = text[q + 1];
            while ve < e && text[ve] != qc { ve += 1; }
        }
        if !quoted || ve >= e {
            report(line, "on: and bind: take a value in quotes on the same line");
            m_chunk(k, e);
            return;
        }
        let name = text[name_s..name_e];
        if on {
            let mods = text[name_e..q];
            if on_event_ok(name, mods, line) { m_on(name, mods, q + 2, ve, line); }
        } else {
            if name == "value" || name == "checked" { m_bind(name, q + 2, ve, line); }
            else { not_available(line, text[k..q]); }
        }
        p = ve + 1;
    }
}

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

// ---------------------------------------------------------------- child components (Addendum 12 section 7.5)

fn reg_find(name: const u8[:]) -> i64 {
    for i in reg.len { if reg[i].name == name { return i; } }
    return -1;
}

// Field k of a tab-separated line.
fn fld(l: const u8[:], k: i64) -> const u8[:] {
    var s = 0;
    var n = 0;
    for i in l.len + 1 {
        if i == l.len || l[i] == '\t' {
            if n == k { return l[s..i]; }
            n += 1;
            s = i + 1;
        }
    }
    return l[l.len..];
}

// The length of a leading `name:` (one colon, not ::) in arg, or 0.
fn named_len(arg: const u8[:]) -> i64 {
    var i = 0;
    if arg.len == 0 || !tscan::ident_start(arg[0]) { return 0; }
    while i < arg.len && tscan::ident_char(arg[i]) { i += 1; }
    let n = i;
    while i < arg.len && (arg[i] == ' ' || arg[i] == '\t') { i += 1; }
    if i < arg.len && arg[i] == ':' && !(i + 1 < arg.len && arg[i + 1] == ':') { return n; }
    return 0;
}

// The offsets (in text) of each argument of a call: the pieces between its top-level commas.
fn split_args(s: i64, e: i64, starts: i64[>..]&, ends: i64[>..]&) {
    var line: u8[>..] = [];
    line.append(text[s..e]);
    var depth = 0;
    var from = 0;
    var i = 0;
    while i < line.len {
        let c = line[i];
        if c == '"' || c == '\'' {
            let j = tscan::skip_literal(line, i);
            if j > i { i = j; continue; }
        }
        if c == '(' || c == '[' || c == '{' { depth += 1; }
        else if c == ')' || c == ']' || c == '}' { depth -= 1; }
        else if c == ',' && depth == 0 {
            starts.push(s + from);
            ends.push(s + i);
            from = i + 1;
        }
        i += 1;
    }
    starts.push(s + from);
    ends.push(e);
}

// The name of a gwc.js helper in the module: bit 1 H, 2 Q, 4 M.
fn gwc_name(bit: i64) -> u8[..16] {
    var n: u8[..16] = "";
    if compact { n.append(if bit == 1 { "$h" } else if bit == 2 { "$q" } else { "$m" }); }
    else { n.append(if bit == 1 { "gw_child" } else if bit == 2 { "gw_props" } else { "gw_mat" }); }
    return n;
}

// js[keep..] taken back out of the module.
fn grab(keep: i64) -> u8[>..] {
    var r: u8[>..] = [];
    r.append(js[keep..js.len]);
    js.resize(keep);
    return r;
}

// The props object of a child call: the given props (nodes[k] >= 0), and with all also the defaults.
fn child_obj(props: const u8[:][:], np: i64, pn: const i64[:], all: bool) -> u8[>..] {
    let keep = js.len;
    w("{");
    var first = true;
    for k in np {
        let l = props[k];
        if pn[k] < 0 && !all { continue; }
        if !first { w(","); if !compact { w(" "); } }
        first = false;
        js.append(fld(l, 0));
        wo(": ");
        if pn[k] >= 0 {
            var pt = ty(0);
            let tv, ok = parse_int(fld(l, 1));
            pt.t = tv;
            let cv, ok2 = parse_int(fld(l, 2));
            pt.cap = cv;
            emit_val(pn[k], pt);
        } else { js.append(fld(l, 4)); }
    }
    w("}");
    return grab(keep);
}

// The type names of an @event's parameters, from the codes of reg_events: `(i64, bool, const u8[:])`.
fn event_types(codes: const u8[:]) -> u8[>..] {
    var r: u8[>..] = [];
    r.push('(');
    var first = true;
    for c in codes {
        if c == ',' { continue; }
        if !first { r.append(", "); }
        first = false;
        r.append(if c == '1' { "i64" } else if c == '2' { "bool" } else { "const u8[:]" });
    }
    r.push(')');
    return r;
}

// An `on:EVENT="handler"` argument of a child call (text[a0..a1]). False when it is not one (a prop called `on`
// is `on: expr`); true when handled, errors included. A good one adds ` data-emit-EVENT="handler"` to attrs.
fn child_on(ln: i64, name: const u8[:], a0: i64, a1: i64, attrs: u8[>..]&) -> bool {
    if a1 - a0 < 4 || text[a0..a0 + 3] != "on:" || !tscan::ident_start(text[a0 + 3]) { return false; }
    var j = a0 + 3;
    while j < a1 && tscan::ident_char(text[j]) { j += 1; }
    let ev = text[a0 + 3..j];
    var k = j;
    while k < a1 && (text[k] == ' ' || text[k] == '\t') { k += 1; }
    if k >= a1 || text[k] != '=' || (k + 1 < a1 && text[k + 1] == '=') { return false; }
    k += 1;
    while k < a1 && (text[k] == ' ' || text[k] == '\t') { k += 1; }
    var m: u8[>..] = [];
    var ok = a1 - k >= 3 && text[k] == '"' && text[a1 - 1] == '"' && tscan::ident_start(text[k + 1]);
    if ok { for q in k + 1..a1 - 1 { if !tscan::ident_char(text[q]) { ok = false; } } }
    if !ok {
        format(m, "on:", ev, " on a component takes a handler name");
        report(ln, m);
        return true;
    }
    let h = text[k + 1..a1 - 1];
    var codes: u8[>..] = [];
    var have = false;
    for l in split(reg_events, '\n') {
        if l.len > 0 && fld(l, 0) == name && fld(l, 1) == ev { have = true; codes.append(fld(l, 2)); }
    }
    if !have {
        format(m, name, " has no @event ", ev);
        report(ln, m);
        return true;
    }
    let fi = find_fn(h);
    if fi < 0 || fns[fi].event {
        format(m, "on:", ev, " handler '", h, "' is not a function of this component");
        report(ln, m);
        return true;
    }
    var np = 0;
    for c in codes { if c != ',' { np += 1; } }
    var same = fns[fi].n == np;
    var pi = 0;
    for c in codes {
        if c == ',' { continue; }
        let want = if c == '1' { T_INT } else if c == '2' { T_BOOL } else { T_STR };
        if same && (params[fns[fi].first + pi].mref || params[fns[fi].first + pi].ty.t != want) { same = false; }
        pi += 1;
    }
    if !same {
        format(m, "on:", ev, " handler '", h, "' must take ", event_types(codes));
        report(ln, m);
        return true;
    }
    var mark: u8[>..] = [];
    format(mark, " data-emit-", ev, "=");
    if find(attrs, mark) >= 0 {
        format(m, "@", name, " handles on:", ev, " twice");
        report(ln, m);
        return true;
    }
    format(attrs, " data-emit-", ev, "=\"", h, "\"");
    return true;
}

// @Name(a: e, b: e, key: e) in a reactive component's markup. False when Name is not a reactive component of this
// build (the caller says it is not available); true when handled, errors included. The Goose is
// `{ let gw_c = Name::Props { ... }; Name::nest(out, gw_c, KEY); }`; the JavaScript renders the child's server form
// with gwc.js's H, and a call outside every block is a part that writes the props into the live child.
fn child_call(ln: i64, s: i64, e: i64, name: const u8[:]) -> bool {
    let ci = reg_find(name);
    if !reactive || ci < 0 { return false; }
    if name == isl || reg[ci].done == 0 {
        report(ln, "components cannot contain themselves");
        return true;
    }
    if reg[ci].done != 2 { return false; }
    var mine: u8[>..] = [];                 // `prop\tt\tcap\tgoose default\tjs default\n` of the child, in declaration order
    for l in split(reg_props, '\n') {
        if l.len <= name.len + 1 || !starts_with(l, name) || l[name.len] != '\t' { continue; }
        mine.append(l[name.len + 1..]);
        mine.push('\n');
    }
    let props = split(mine, '\n');
    var np = 0;
    for l in props { if l.len > 0 { np += 1; } }
    var pn: i64[>..] = [];                  // the node of each prop's value, or -1
    var vs: i64[>..] = [];                  // its source span
    var ve: i64[>..] = [];
    for k in np { pn.push(-1); vs.push(0); ve.push(0); }
    var starts: i64[>..] = [];
    var ends: i64[>..] = [];
    split_args(s, e, starts, ends);
    let before = nerr;
    var rbits = 0;
    var emit_attrs: u8[>..] = [];           // ` data-emit-change="picked"` for each on:EVENT
    var kx = -1;                            // the node of key: e
    var kx_s = 0;
    var kx_e = 0;
    for k in np {
        let t = fld(props[k], 1);
        if t != "1" && t != "2" && t != "3" {
            var m: u8[>..] = [];
            format(m, "@", name, " has the prop ", fld(props[k], 0), " of a struct or array type; a call from markup passes whole numbers, bool and text only");
            report(ln, m);
            return true;
        }
    }
    for pi in starts.len {
        let a0 = trim_s(starts[pi], ends[pi]);
        let a1 = trim_e(a0, ends[pi]);
        if a1 <= a0 {
            if starts.len > 1 && pi + 1 < starts.len { report(ln, "an empty argument; write @Name(a: 1, b: 2)"); }
            continue;
        }
        if child_on(ln, name, a0, a1, emit_attrs) { continue; }
        let nlen = named_len(text[a0..a1]);
        if nlen == 0 {
            var m: u8[>..] = [];
            var first: u8[>..] = [];
            if np > 0 { first.append(fld(props[0], 0)); } else { first.append("x"); }
            format(m, "@", name, " takes named props: @", name, "(", first, ": 3)");
            report(ln, m);
            return true;
        }
        let pname = text[a0..a0 + nlen];
        var found = -1;
        for k in np { if fld(props[k], 0) == pname { found = k; } }
        var m: u8[>..] = [];
        if found < 0 && pname != "key" {
            format(m, name, " has no prop ", pname);
            report(ln, m);
            continue;
        }
        if (pname == "key" && kx >= 0) || (found >= 0 && pn[found] >= 0) {
            if pname == "key" { format(m, "@", name, " passes key twice"); }
            else { format(m, "@", name, " passes prop ", pname, " twice"); }
            report(ln, m);
            continue;
        }
        var colon = a0 + nlen;
        while text[colon] != ':' { colon += 1; }
        let v0 = trim_s(colon + 1, a1);
        if v0 >= a1 {
            if pname == "key" { format(m, "@", name, " key needs a value"); }
            else { format(m, "@", name, " prop ", pname, " needs a value"); }
            report(ln, m);
            continue;
        }
        let n = parse_tag_expr(v0, a1, ln);
        if n < 0 { continue; }
        check_expr(n);
        rw_mark(n, ln, RM_TEXT);
        if found >= 0 { rbits = rbits | rw_r; }
        rec_expr(n);
        let nt = nodes[n].ty.t;
        if nt == T_ERR { continue; }
        if found >= 0 {
            let want = fld(props[found], 1);
            let wt = if want == "1" { T_INT } else if want == "2" { T_BOOL } else { T_STR };
            if nt != wt {
                format(m, "@", name, " prop ", pname, " is ", if wt == T_INT { "a whole number" } else if wt == T_BOOL { "bool" } else { "text" },
                       ", not ", if nt == T_INT { "a whole number" } else if nt == T_BOOL { "bool" } else if nt == T_STR { "text" } else { "this" });
                report(ln, m);
                continue;
            }
            pn[found] = n;
            vs[found] = v0;
            ve[found] = a1;
        } else {
            if nt != T_INT && nt != T_STR { report(ln, "key: takes a whole number or text"); continue; }
            kx = n;
            kx_s = v0;
            kx_e = a1;
        }
    }
    for k in np {
        if pn[k] < 0 && fld(props[k], 3).len == 0 && nerr == before {
            var m: u8[>..] = [];
            format(m, "@", name, " needs prop ", fld(props[k], 0));
            report(ln, m);
        }
    }
    if kx < 0 {
        var in_for = false;
        for o in opens { if o.kind == 'f' { in_for = true; } }
        if in_for && nerr == before { warn_buf("child-key", ln, "a component in {#for} needs key:"); }
    }
    if nerr != before { return true; }
    // The Goose.
    var call: u8[>..] = [];
    let int_key = kx >= 0 && nodes[kx].ty.t == T_INT;
    if int_key { format(call, "{ var gw_k: u8[>..] = []; format(gw_k, ", rewrite(kx_s, kx_e), "); "); } else { call.append("{ "); }
    format(call, "let gw_c = ", name, "::Props { ");
    for k in np {
        let l = props[k];
        if k > 0 { call.append(", "); }
        if pn[k] >= 0 { format(call, fld(l, 0), ": ", rewrite(vs[k], ve[k])); }
        else { format(call, fld(l, 0), ": ", fld(l, 3)); }
    }
    if np == 0 { call.append(".. "); }
    format(call, "}; ", name, "::nest(out, gw_c, ");
    if int_key { call.append("gw_k"); } else if kx >= 0 { call.append(rewrite(kx_s, kx_e)); } else { call.append("\"\""); }
    call.append(", \"");
    for ch in emit_attrs { if ch == '"' { call.append("\\\""); } else { call.push(ch); } }
    call.append("\"); } ");
    var part = -1;
    if opens.len == 0 && span_kind_at(s) < 0 {
        part = part_begin(PK_CHILD);
        mtext("<!--g-->");
    } else if opens.len > 0 && opens[0].part >= 0 { parts[opens[0].part].kids = true; }
    g_flush();
    g_code(call);
    // The JavaScript.
    let full = child_obj(props, np, pn, true);
    cat_expr(true);
    child_use = child_use | 1;
    w(gwc_name(1));
    w("(");
    js_str(name);
    wo(", ");
    js.append(full);
    if kx >= 0 {
        wo(", ");
        if nodes[kx].ty.t == T_INT { w("\"\""); wo(" + "); }
        emit_expr(kx, true);
    } else if emit_attrs.len > 0 { wo(", "); w("\"\""); }
    if emit_attrs.len > 0 { wo(", "); js_str(emit_attrs); }
    w(")");
    var have = false;
    for k in kids { if k == name { have = true; } }
    if !have { var kn: u8[..64] = ""; kn.append(name); kids.push(kn); }
    if part >= 0 { part_end(part, rbits, child_obj(props, np, pn, false), true); }
    return true;
}

fn markup_line(li: i64, last: bool, goose_out: u8[>..]&) {
    let ln = li + 1;
    let base = line_start[li];
    var line: u8[>..] = [];
    line.append(text[base..line_end[li]]);
    gline.clear();
    gtext.clear();
    var p = 0;
    while p < line.len {
        if tscan::is_raw(raw_st) {
            let e = tscan::raw_end(line, p, raw_st);
            mtext(line[p..e]);
            p = e;
            continue;
        }
        let at = tscan::next(line, p, raw_st, true);
        m_text(base + p, base + at, ln);
        p = at;
        if at == line.len || tscan::is_raw(raw_st) { continue; }
        fire_to(base + at);
        if line[at] == '}' { report(ln, "'}' without '{'; for a literal brace write &#125;"); break; }
        if line[at] == '@' {
            let open = tscan::call_open(line, at);
            let close = tscan::paren_end(line, open);
            if reactive && close >= 0 && find(line[at + 1..open], ":") < 0 && child_call(ln, base + open + 1, base + close, line[at + 1..open]) {
                p = close + 1;
                continue;
            }
            var what: u8[>..] = [];
            format(what, line[at..open], "()");
            not_available(ln, what);
            if close < 0 { break; }
            p = close + 1;
            continue;
        }
        if starts_with(line[at..], "{{") { report(ln, tscan::old_syntax(line[at..])); break; }
        if starts_with(line[at..], "{--") {
            let e = find(line[at..], "--}");
            if e < 0 { report(ln, "{-- needs --} on the same line"); break; }
            p = at + e + 3;
            continue;
        }
        let e = tscan::brace_end(line, at);
        if e < 0 { report(ln, "{ needs } on the same line; for a literal brace write &#123;"); break; }
        let a = trim_s(base + at + 1, base + e);
        let b = trim_e(a, base + e);
        p = e + 1;
        mk_after = base + e + 1;
        let inner = text[a..b];
        if starts_with(inner, "#if ") { m_if(trim_s(a + 4, b), b, ln, false); }
        else if starts_with(inner, "#else if ") { m_if(trim_s(a + 9, b), b, ln, true); }
        else if inner == "#else" { m_else(ln); }
        else if starts_with(inner, "#for ") { m_for(trim_s(a + 5, b), b, ln); }
        else if starts_with(inner, "#let ") { m_let(trim_s(a + 5, b), b, ln); }
        else if inner == "#else if" { report(ln, "{#else if e} needs an expression"); }
        else if inner == "#for" { report(ln, "{#for x in e} or {#for x, i in e}"); }
        else if inner == "#let" { report(ln, "{#let n = e} needs a name and a value"); }
        else if inner == "#raw" || inner == "#if" {
            var m: u8[>..] = [];
            format(m, "{", inner, " e} needs an expression");
            report(ln, m);
        }
        else if starts_with(inner, "#raw ") { m_expr(trim_s(a + 5, b), b, ln, true); }
        else if inner == "/if" { m_close('i', ln); }
        else if inner == "/for" { m_close('f', ln); }
        else if starts_with(inner, "#") || starts_with(inner, "/") {
            var m: u8[>..] = [];
            format(m, "unknown tag {", inner, "}");
            report(ln, m);
        }
        else if a == b { report(ln, "empty { }"); }
        else { m_expr(a, b, ln, false); }
    }
    fire_to(base + line.len);
    if !last { mtext("\n"); }
    g_flush();
    if last { gline.append("}"); }
    goose_out.append(gline);
    goose_out.push('\n');
    // A tag with a part's attribute list stays one statement across its lines.
    if !compact && ptag_phase == 0 { cat_close(); }
}

fn compile_markup(first_line: i64, render_line: i64, goose_out: u8[>..]&) {
    begin_fn();
    var st = ty(T_STRUCT);
    st.name.append("State");
    if compact {
        o_js.clear();
        o_js.append(next_short());
        if !reactive {
            var v = Var { name: "s", ty: st, js: "" };
            v.js.append(next_short());
            vars.push(v);
        }
    } else {
        o_js.clear();
        o_js.append("o");
        used.push("o");
        if !reactive {
            var v = Var { name: "s", ty: st, js: "" };
            v.js = pick_name("s");
            vars.push(v);
        }
    }
    // A reactive component's markup names its state directly: no s.
    if reactive { s_var = -1; } else { s_var = vars.len - 1; scope.push(s_var); }
    emit_line_note(render_line);
    w("function ");
    w(render_js);
    w("(");
    if reactive { w(s_js); } else { w_var(s_var); }
    wo(") {");
    ind = 1;
    nl();
    w("let ");
    w(o_js);
    wo(" = ");
    w("\"\";");
    opens.clear();
    pend.clear();
    raw_st = tscan::MARKUP;
    cat_open = false;
    if reactive { scan_parts(first_line); }
    let nl_count = line_start.len;
    var raw_line = 0;             // the line where the open <script>/<style> began
    for li in first_line..nl_count {
        markup_line(li, li == nl_count - 1, goose_out);
        if raw_st == tscan::MARKUP { raw_line = 0; } else if raw_line == 0 { raw_line = li + 1; }
    }
    if tscan::unclosed(raw_st).len > 0 { report(raw_line, tscan::unclosed(raw_st)); }
    cat_close();
    if opens.len > 0 {
        let o = opens[opens.len - 1];
        report(o.line, if o.kind == 'i' { "{#if} is never closed with {/if}" } else { "{#for} is never closed with {/for}" });
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
        // Reactive components also write a slice of structs (routes, step 6).
        if reactive {
            format(out, "fn gw_json(out: u8[>..]&, v: const ", sd.name, "[:]) { out.push('['); ",
                   "for gw_x, gw_i in v { if gw_i > 0 { out.push(','); } gw_json(out, gw_x); } out.push(']'); }\n");
        }
    }
}

// ---------------------------------------------------------------- the reactive tail (section 3.1)

// A declaration's type as the Goose structs write it: as in the source, with const on u8[:] and S[:] props.
fn decl_type(d: RDecl) -> u8[>..] {
    var r: u8[>..] = [];
    if (d.ty.t == T_STR && d.ty.cap == 0) || (d.ty.t == T_ARRAY && d.ty.cap == RO) { r.append("const "); }
    r.append(text[d.ts..d.te]);
    return r;
}

// State holds @state, then @computed, in declaration order, and the array @state last.
fn in_state(d: RDecl, pass: i64) -> bool {
    if pass == 0 { return d.kind == R_STATE && d.ty.t != T_ARRAY; }
    if pass == 1 { return d.kind == R_COMPUTED; }
    return d.kind == R_STATE && d.ty.t == T_ARRAY;
}

// The writer of one field: owner is "gw_p." or "gw_s.".
fn json_field(out: u8[>..]&, d: RDecl, owner: const u8[:], first: bool) {
    format(out, "out.append(\"", if first { "{" } else { "," }, "\\\"", d.name, "\\\":\"); ");
    let t = d.ty.t;
    if t == T_INT || t == T_BOOL { format(out, "format(out, ", owner, d.name, "); "); }
    else if t == T_STR { format(out, "web::json_text(out, ", owner, d.name, "); "); }
    else if t == T_STRUCT { format(out, "gw_json(out, ", owner, d.name, "); "); }
    else {
        format(out, "out.push('['); for gw_x, gw_i in ", owner, d.name,
               " { if gw_i > 0 { out.push(','); } gw_json(out, gw_x); } out.push(']'); ");
    }
}

// A type as the Goose stubs write it.
fn stub_ty(t: const Ty&) -> u8[>..] {
    var r: u8[>..] = [];
    if t.t == T_INT { r.append("i64"); }
    else if t.t == T_BOOL { r.append("bool"); }
    else if t.t == T_STR { format(r, "u8[..", t.cap, "]"); }
    else if t.t == T_STRUCT { r.append(t.name); }
    else { format(r, t.name, "[>..<]"); }
    return r;
}

// What the stub returns: the type's zero.
fn stub_zero(t: const Ty&) -> u8[>..] {
    var r: u8[>..] = [];
    if t.t == T_INT { r.append("0"); }
    else if t.t == T_BOOL { r.append("false"); }
    else if t.t == T_STR { r.append("\"\""); }
    else if t.t == T_STRUCT { format(r, t.name, " { .. }"); }
    else { r.append("[]"); }
    return r;
}

// gw_get_K(url) -> T and gw_post_K(url, value) [-> T]: the Goose side of http::get and http::post. A handler never
// runs on the server, so the stubs only give the Goose compiler the types.
fn emit_stubs(out: u8[>..]&) {
    for st, i in stubs {
        format(out, "fn gw_", if st.post { "post" } else { "get" }, "_", i, "(gw_u: const u8[:]");
        if st.post {
            out.append(", gw_v: ");
            let v = st.val;
            if v.t == T_STR { out.append("const u8[:]"); }
            else if v.t == T_STRUCT { format(out, "const ", v.name, "&"); }
            else if v.t == T_ARRAY { format(out, "const ", v.name, "[:]"); }
            else { out.append(stub_ty(v)); }
        }
        out.push(')');
        if st.reply.t == T_VOID { out.append(" {}\n"); continue; }
        let rt = stub_ty(st.reply);
        format(out, " -> ", rt, " { var gw_r: ", rt, " = ", stub_zero(st.reply), "; return gw_r; }\n");
    }
}

fn emit_reactive_tail(name: const u8[:], out: u8[>..]&) {
    out.append("struct Props {");
    var first = true;
    for d in rdecls {
        if d.kind != R_PROP { continue; }
        format(out, if first { " " } else { ", " }, d.name, ": ", decl_type(d));
        first = false;
    }
    out.append(if first { "}\n" } else { " }\n" });
    out.append("struct State {");
    first = true;
    for pass in 3 {
        for d in rdecls {
            if !in_state(d, pass) { continue; }
            format(out, if first { " " } else { ", " }, d.name, ": ", decl_type(d));
            first = false;
        }
    }
    out.append(if first { "}\n" } else { " }\n" });
    emit_stubs(out);
    out.append("fn gw_init(gw_p: const Props&) -> State { var gw_s = State { .. }; ");
    for d in rdecls {
        if d.kind == R_STATE && has_init_fn(d) { format(out, "gw_s.", d.name, " = gw_i_", d.name, "(gw_p, gw_s); "); }
    }
    for k in rorder.len {
        let d = rdecls[rorder[k]];
        if has_init_fn(d) { format(out, "gw_s.", d.name, " = gw_c_", d.name, "(gw_p, gw_s); "); }
    }
    out.append("return gw_s; }\n");
    out.append("fn gw_flush(gw_p: const Props&, gw_s: State&) { ");
    for k in rorder.len {
        let d = rdecls[rorder[k]];
        if has_init_fn(d) { format(out, "gw_s.", d.name, " = gw_c_", d.name, "(gw_p, gw_s); "); }
    }
    out.append("}\n");
    out.append("fn gw_check(gw_p: const Props&, gw_s: const State&) { var gw_w = State { .. };\n");
    out.append(chk);
    out.append("}\n");
    emit_json_writer(out);
    out.append("fn gw_json(out: u8[>..]&, gw_p: const Props&, gw_s: const State&) { ");
    first = true;
    for d in rdecls {
        if d.kind != R_PROP { continue; }
        json_field(out, d, "gw_p.", first);
        first = false;
    }
    for pass in 3 {
        for d in rdecls {
            if !in_state(d, pass) { continue; }
            json_field(out, d, "gw_s.", first);
            first = false;
        }
    }
    out.append(if first { "out.append(\"{}\"); }\n" } else { "out.push('}'); }\n" });
    // nest is the child form (a parent's markup calls it with the child's key); component adds the module script.
    format(out, "fn nest(out: u8[>..]&, gw_p: const Props&, gw_k: const u8[:], gw_a: const u8[:]) { let gw_s = gw_init(gw_p); out.append(\"<div data-component=\\\"", name,
           "\\\"\"); if gw_k.len > 0 { out.append(\" gw-key=\\\"\"); web::put(out, gw_k); out.append(\"\\\"\"); } out.append(gw_a); out.append(\">\"); ",
           "render(out, gw_p, gw_s); out.append(\"</div><script type=\\\"application/json\\\">\"); gw_json(out, gw_p, gw_s); out.append(\"</script>\"); }\n");
    format(out, "fn component(out: u8[>..]&, gw_p: const Props&) { nest(out, gw_p, \"\", \"\"); ",
           "out.append(\"<script type=\\\"module\\\" src=\\\"/_gw/", name, ".js\\\"></script>\"); }\n");
}

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

// ---------------------------------------------------------------- warnings

fn id_ch(c: u8) -> bool { return is_alpha(c) || (c >= '0' && c <= '9'); }

// Does code write the array field f other than by push and clear: `.f.remove_at(`, `.f[i] = ...` or `.f = ...`?
fn writes_array(code: const u8[:], f: const u8[:]) -> bool {
    var pat: u8[>..] = [];
    format(pat, ".", f);
    var p = 0;
    while p < code.len {
        let k = find(code[p..], pat);
        if k < 0 { return false; }
        var q = p + k + pat.len;
        p = q;
        if q < code.len && id_ch(code[q]) { continue; }
        if starts_with(code[q..], ".remove_at(") { return true; }
        if q < code.len && code[q] == '[' {
            var depth = 0;
            while q < code.len {
                if code[q] == '[' { depth += 1; }
                if code[q] == ']' { depth -= 1; if depth == 0 { q += 1; break; } }
                q += 1;
            }
        }
        while q < code.len && (code[q] == ' ' || code[q] == '\t') { q += 1; }
        if q < code.len && code[q] == '=' && !(q + 1 < code.len && code[q + 1] == '=') { return true; }
    }
    return false;
}

// Is the first element tag after text[at..] (up to the matching {/for}) without gw-key? Scans at most 12 lines.
fn first_tag_unkeyed(li: i64, at: i64) -> bool {
    var from = at;
    var l = li;
    var tag: u8[>..] = [];
    var open = false;
    var braces = 0;
    while l < line_start.len && l < li + 12 {
        let ln = text[line_start[l]..line_end[l]];
        var i = if l == li { from } else { 0 };
        while i < ln.len {
            let c = ln[i];
            if !open {
                if starts_with(ln[i..], "{/for}") { return false; }
                if c == '<' && i + 1 < ln.len && is_alpha(ln[i + 1]) { open = true; }
            } else {
                if c == '{' { braces += 1; }
                if c == '}' && braces > 0 { braces -= 1; }
                if c == '>' && braces == 0 { return find(tag, "gw-key") < 0; }
                tag.push(c);
            }
            i += 1;
        }
        if open { tag.push(' '); }
        l += 1;
    }
    return false;
}

// unkeyed-for (legacy components): a {#for x in s.F} over the State array whose script writes F other than by
// push and clear, and whose first element tag has no gw-key. A heuristic on the text; it errs towards silence.
fn warn_unkeyed(close: i64, warns: u8[>..]&) {
    let si = find_struct("State");
    if si < 0 { return; }
    var f: u8[>..] = [];
    for k in structs[si].n {
        let fl = fields[structs[si].first + k];
        if fl.kind == Kind.Array { f.append(fl.name); }
    }
    if f.len == 0 || close < 1 { return; }
    if !writes_array(text[line_start[1]..line_start[close]], f) { return; }
    var want: u8[>..] = [];
    format(want, "s.", f);
    let first = close + 1;
    let total = line_start.len;
    for li in first..total {
        let ln = text[line_start[li]..line_end[li]];
        var p = 0;
        while p < ln.len {
            let k = find(ln[p..], "{#for ");
            if k < 0 { break; }
            let a = p + k;
            let e = find(ln[a..], "}");
            if e < 0 { break; }
            p = a + e + 1;
            let head = ln[a + 6..a + e];
            let kin = find(head, " in ");
            if kin < 0 || trim(head[kin + 4..]) != want { continue; }
            if first_tag_unkeyed(li, p) {
                var m: u8[>..] = [];
                format(m, "{#for} over ", want, " needs gw-key on its elements: the list can reorder or lose an item");
                format(warns, "unkeyed-for\t", src_path, ":", li + 1, ": warning: ", m, "\n");
            }
        }
    }
}

// The parity tests of the component compile() last read, one name per line.
fn test_names() -> u8[>..] {
    var r: u8[>..] = [];
    for f in fns { if f.test && f.body >= 0 { r.append(f.name); r.push('\n'); } }
    return r;
}

// The @props of the component compile() last read: `name\tdefault source or empty\n` each.
fn props_of() -> u8[>..] {
    var r: u8[>..] = [];
    r.append(props_buf);
    return r;
}

fn is_reactive() -> bool { return reactive; }

// gweb tells compile() which components exist (registry_add, in any order) and compiles a component after the
// components it calls; compile() records each one's props here, which a caller's arguments are checked against.
fn registry_clear() {
    reg.clear();
    reg_props.clear();
    reg_events.clear();
}

fn registry_add(name: const u8[:]) {
    var c = RegC { name: "", done: 0 };
    c.name.append(name);
    reg.push(c);
}

// 1 when the module calls a child component (and so imports gwc.js).
fn children_used() -> i64 { return if kids.len > 0 { 1 } else { 0 }; }

// The string-literal urls of the http calls compile() last read: `METHOD\tLINE\turl\n` each.
fn http_urls() -> u8[>..] {
    var r: u8[>..] = [];
    r.append(http_urls_buf);
    return r;
}

// 1 when the module uses http::get, 2 http::post (and so imports gwh.js).
fn http_used() -> i64 { return http_use; }

// 1 when the module calls life() (and so imports gwl.js).
fn life_used() -> i64 { return life_use; }
fn mods_used() -> i64 { return mods_use; }

// For each test of test_names, in its order: 1 when it is called test(gw_p, gw_s), 0 when with no arguments.
fn test_args() -> u8[>..] {
    var r: u8[>..] = [];
    for i in fns.len {
        if !fns[i].test || fns[i].body < 0 { continue; }
        r.append(if reactive && takes_state(i) { "1" } else { "0" });
        r.push('\n');
    }
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
    reactive = false;
    rdecls.clear();
    rblocks.clear();
    ruses.clear();
    rorder.clear();
    rmarks.clear();
    mk_r = 0;
    rw_r = 0;
    rw_w = 0;
    rw_rep = false;
    rw_ctx = 0;
    warns_buf.clear();
    edits.clear();
    props_buf.clear();
    parts.clear();
    pcode.clear();
    letcode.clear();
    pspans.clear();
    ptag = 0;
    ptag_phase = 0;
    pr_open = -1;
    pr_acc = 0;
    pr_ra = 0;
    pr_flow = 0;
    n_flow = 0;
    mk_after = 0;
    var_r.clear();
    ev_types.clear();
    stubs.clear();
    decs.clear();
    dec_bits = 0;
    http_urls_buf.clear();
    http_use = 0;
    life_use = 0;
    mods_use = 0;
    await_ctx.clear();
    rw_noasync.clear();
    rw_async = false;
    rw_awaited = -1;
    kids.clear();
    child_use = 0;
}

// Errors go to errs as `path:LINE: error: MSG` lines; false when there were any.
// Warnings go to warns as `code\tpath:LINE: warning: MSG` lines.
// goose_out is written even then, so the Goose compiler can report its own errors.
fn compile(name: const u8[:], path: const u8[:], src: const u8[:], compact_js: bool,
           goose_out: u8[>..]&, js_out: u8[>..]&, errs: u8[>..]&, warns: u8[>..]&) -> bool {
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
    let ri = reg_find(name);
    if ri >= 0 { reg[ri].done = 1; }
    parse_script(1, close);
    // The header: a reactive component imports the components its markup calls (they were compiled before it).
    format(goose_out, "namespace ", name, "; import std; import json; import web; import web.template;");
    if reactive {
        for li in close + 1..nlines {
            let l = text[line_start[li]..line_end[li]];
            for i in l.len {
                if l[i] != '@' { continue; }
                let o = tscan::call_open(l, i);
                if o < 0 { continue; }
                let cn = l[i + 1..o];
                let rj = reg_find(cn);
                if rj < 0 || reg[rj].done != 2 || cn == name { continue; }
                var imp: u8[>..] = [];
                format(imp, " import ", cn, ";");
                if find(goose_out, imp) < 0 { goose_out.append(imp); }
            }
        }
    }
    goose_out.push('\n');
    if reactive { check_rmodel(); } else { check_structs(); }
    for &f in fns {
        if !reactive && f.n > 0 && params[f.first].mref && params[f.first].ty.name == "State" {
            f.test = starts_with(f.name, "test_") && f.n == 1;
            f.handler = !f.test;
        }
    }
    assign_module_names();
    for i in fns.len { check_fn(i); }
    if reactive { check_reactive(); rec_script(); }
    if reactive && ri >= 0 { reg[ri].done = 2; }
    // The script lines, line for line; a reactive component's are rewritten (section 3.1).
    for li in 1..close {
        if reactive { goose_out.append(rewrite(line_start[li], line_end[li])); }
        else { goose_out.append(text[line_start[li]..line_end[li]]); }
        goose_out.push('\n');
    }
    if reactive { goose_out.append("fn render(out: u8[>..]&, gw_p: const Props&, gw_s: const State&) {\n"); }
    else { goose_out.append("fn render(out: u8[>..]&, s: const State&) {\n"); }
    if reactive {
        for d in rdecls {
            if d.kind != R_PROP { continue; }
            format(props_buf, d.name, "\t");
            if d.init >= 0 { props_buf.append(text[span_s(d.init)..span_e(d.init)]); }
            props_buf.push('\n');
            // The registry line for the components that call this one: its type and its default, in Goose and JavaScript.
            format(reg_props, name, "\t", d.name, "\t", d.ty.t, "\t", d.ty.cap, "\t");
            if d.init >= 0 { reg_props.append(text[span_s(d.init)..span_e(d.init)]); }
            reg_props.push('\t');
            if d.init >= 0 && nerr == 0 {
                let keep = js.len;
                emit_expr(d.init, true);
                reg_props.append(js[keep..js.len]);
                js.resize(keep);
            }
            reg_props.push('\n');
        }
    }
    if reactive {
        for f in fns {
            if !f.event { continue; }
            format(reg_events, name, "\t", f.name, "\t");
            for p in f.first..f.first + f.n {
                if p > f.first { reg_events.push(','); }
                format(reg_events, params[p].ty.t);
            }
            reg_events.push('\n');
        }
    }
    if !reactive || nerr == 0 { for i in fns.len { if fns[i].body >= 0 { emit_js_fn(i); } } }
    await_ctx.clear();
    await_ctx.append("markup");
    compile_markup(close + 1, close + 1, goose_out);
    await_ctx.clear();
    if close + 1 >= nlines { goose_out.append("}\n"); }
    if !reactive {
        emit_zero();
        emit_component_call();
    } else if nerr == 0 {
        emit_decoders();
        emit_reactive_update();
        let has_watch = emit_reactive_watch();
        emit_reactive_init();
        emit_reactive_call(has_watch);
    }
    if reactive {
        emit_reactive_tail(name, goose_out);
    } else {
        goose_out.append("fn gw_check(s: const State&) { var gw_w = State { .. };\n");
        goose_out.append(chk);
        goose_out.append("}\n");
        emit_json_writer(goose_out);
        format(goose_out, "fn component(out: u8[>..]&, s: const State&) { out.append(\"<div data-component=\\\"", name,
               "\\\">\"); render(out, s); out.append(\"</div><script type=\\\"application/json\\\">\"); gw_json(out, s); ",
               "out.append(\"</script><script type=\\\"module\\\" src=\\\"/_gw/", name, ".js\\\"></script>\"); }\n");
    }
    if compact {
        js_out.append("import{");
        var first = true;
        for h in HN {
            if !helper_used[h] { continue; }
            if !first { js_out.push(','); }
            first = false;
            format(js_out, HELPERS[h], " as ", helper_js[h]);
        }
        js_out.append("}from\"./gwi.js\";");
        if (http_use & 3) != 0 {
            js_out.append("import{");
            if (http_use & 1) != 0 { js_out.append("get as $g"); }
            if (http_use & 3) == 3 { js_out.push(','); }
            if (http_use & 2) != 0 { js_out.append("post as $p"); }
            js_out.append("}from\"./gwh.js\";");
        }
        if life_use != 0 { js_out.append("import{life as $l}from\"./gwl.js\";"); }
        if mods_use != 0 { js_out.append("import\"./gwm.js\";"); }
        for k in kids { format(js_out, "import\"./", k, ".js\";"); }
        if child_use != 0 {
            js_out.append("import{");
            var firstc = true;
            for bit in [1, 2, 4] {
                if (child_use & bit) == 0 { continue; }
                if !firstc { js_out.push(','); }
                firstc = false;
                format(js_out, if bit == 1 { "H" } else if bit == 2 { "Q" } else { "M" }, " as ", gwc_name(bit));
            }
            js_out.append("}from\"./gwc.js\";");
        }
    } else {
        js_out.append("// Generated by gweb from ");
        js_out.append(path);
        js_out.append(". Do not edit.\nimport { component, esc, at, set, rm, blen, cap, idiv, imod, ");
        js_out.append(if reactive { "T, A, B" } else { "swap" });
        js_out.append(" } from \"./gwi.js\";\n");
        if (http_use & 3) != 0 {
            js_out.append("import { ");
            if (http_use & 1) != 0 { js_out.append("get as gw_get"); }
            if (http_use & 3) == 3 { js_out.append(", "); }
            if (http_use & 2) != 0 { js_out.append("post as gw_post"); }
            js_out.append(" } from \"./gwh.js\";\n");
        }
        if life_use != 0 { js_out.append("import { life } from \"./gwl.js\";\n"); }
        if mods_use != 0 { js_out.append("import \"./gwm.js\";\n"); }
        for k in kids { format(js_out, "import \"./", k, ".js\";\n"); }
        if child_use != 0 {
            js_out.append("import { ");
            var firstc = true;
            for bit in [1, 2, 4] {
                if (child_use & bit) == 0 { continue; }
                if !firstc { js_out.append(", "); }
                firstc = false;
                format(js_out, if bit == 1 { "H" } else if bit == 2 { "Q" } else { "M" }, " as ", gwc_name(bit));
            }
            js_out.append(" } from \"./gwc.js\";\n");
        }
    }
    js_out.append(js);
    errs.append(errs_buf);
    if nerr == 0 {
        warns.append(warns_buf);
        warn_unkeyed(close, warns);
    }
    return nerr == 0;
}
