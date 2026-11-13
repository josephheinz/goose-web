// structs: the declaration scanner that form_decoders (gweb.goose) and the views generator (views.goose) share.
// It works on the source lines of one file, finds `struct Name {` or `enum Name {` at the start of a line and
// hands each comma-separated entry of the braces to a block, with the line it starts on (1-based). It knows
// strings, comments and nesting, and nothing about types.

namespace structs;

import std;

// The index of the line that starts `KEYWORD NAME {` (struct or enum, after any white space), or -1.
fn find_decl(lines, keyword: const u8[:], name: const u8[:]) -> i64 {
    for line, k in lines {
        let t = trim_start(line);
        if !starts_with(t, keyword) || t.len <= keyword.len || t[keyword.len] != ' ' { continue; }
        let r = trim_start(t[keyword.len + 1..]);
        if !starts_with(r, name) { continue; }
        let rest = trim_start(r[name.len..]);
        if rest.len > 0 && rest[0] == '{' && (r.len == name.len || r[name.len] == ' ' || r[name.len] == '{') { return k; }
    }
    return -1;
}

// F(text, line) for each entry of the braces that open on lines[k]. Returns the index of the line after the closing
// brace, and whether the brace was closed. Entries are trimmed by the caller; an empty trailing one is skipped.
fn fields<F>(lines, k: i64) -> i64, bool {
    var cur: u8[>..] = [];
    var cur_line = 0;
    var depth = 0;
    var in_str = false;
    var done = false;
    var ln = k;
    var start = find(lines[k], "{") + 1;
    while ln < lines.len && !done {
        let line = lines[ln];
        var ci = start;
        while ci < line.len {
            let c = line[ci];
            if in_str {
                cur.push(c);
                if c == '\\' && ci + 1 < line.len { ci += 1; cur.push(line[ci]); }
                else if c == '"' { in_str = false; }
                ci += 1;
                continue;
            }
            if c == '/' && ci + 1 < line.len && line[ci + 1] == '/' { break; }
            if depth == 0 && c == '}' { done = true; break; }
            if depth == 0 && c == ',' {
                F(cur, cur_line);
                cur.clear();
                cur_line = 0;
                ci += 1;
                continue;
            }
            if c == '"' { in_str = true; }
            if c == '[' || c == '(' || c == '{' { depth += 1; }
            if c == ']' || c == ')' || c == '}' { depth -= 1; }
            if cur_line == 0 && c != ' ' && c != '\t' { cur_line = ln + 1; }
            cur.push(c);
            ci += 1;
        }
        if !done { cur.push(' '); }
        start = 0;
        ln += 1;
    }
    if trim(cur).len > 0 { F(cur, cur_line); }
    return ln, done;
}
