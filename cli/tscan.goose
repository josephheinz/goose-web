// tscan: finds template tags and calls in one line of markup. Shared by gweb.goose and component.goose.
// Inside <script> and <style> elements nothing is a tag.

namespace tscan;

import std;

let MARKUP = 0;
let SCRIPT_TAG = 1;
let SCRIPT = 2;
let STYLE_TAG = 3;
let STYLE = 4;

fn is_raw(st: i64) -> bool { st == SCRIPT || st == STYLE }

fn unclosed(st: i64) -> const u8[:] {
    if st == SCRIPT_TAG || st == SCRIPT { return "<script> is never closed with </script>"; }
    if st == STYLE_TAG || st == STYLE { return "<style> is never closed with </style>"; }
    return "";
}

fn ident_start(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' }
fn ident_char(c: u8) -> bool { ident_start(c) || (c >= '0' && c <= '9') }

// word must be lower case.
fn starts_nocase(line: const u8[:], at: i64, word: const u8[:]) -> bool {
    if at + word.len > line.len { return false; }
    for i in word.len {
        var c = line[at + i];
        if c >= 'A' && c <= 'Z' { c += 32; }
        if c != word[i] { return false; }
    }
    return true;
}

fn opens_element(line: const u8[:], at: i64, name: const u8[:]) -> bool {
    if line[at] != '<' || !starts_nocase(line, at + 1, name) { return false; }
    let e = at + 1 + name.len;
    return e == line.len || line[e] == ' ' || line[e] == '\t' || line[e] == '>' || line[e] == '/' || line[e] == '\r';
}

fn skip_literal(line: const u8[:], i: i64) -> i64 {
    let n = line.len;
    if line[i] == '"' {
        if i + 2 < n && line[i + 1] == '"' && line[i + 2] == '"' {
            var j = i + 3;
            while j + 2 < n && !(line[j] == '"' && line[j + 1] == '"' && line[j + 2] == '"') { j += 1; }
            return min(j + 3, n);
        }
        var j = i + 1;
        while j < n && line[j] != '"' {
            if line[j] == '\\' { j += 1; }
            j += 1;
        }
        return min(j + 1, n);
    }
    if line[i] == '\'' {
        if i + 2 < n && line[i + 1] != '\\' && line[i + 2] == '\'' { return i + 3; }
        if i + 3 < n && line[i + 1] == '\\' {
            var j = i + 3;
            while j < n && j < i + 6 && line[j] != '\'' { j += 1; }
            if j < n && line[j] == '\'' { return j + 1; }
        }
    }
    return i;
}

fn match_end(line: const u8[:], at: i64, open: u8, close: u8) -> i64 {
    var depth = 0;
    var i = at;
    while i < line.len {
        let c = line[i];
        if c == '"' || c == '\'' {
            let j = skip_literal(line, i);
            if j > i { i = j; continue; }
        }
        if c == open { depth += 1; }
        else if c == close {
            depth -= 1;
            if depth == 0 { return i; }
        }
        i += 1;
    }
    return -1;
}

fn brace_end(line: const u8[:], at: i64) -> i64 { match_end(line, at, '{', '}') }
fn paren_end(line: const u8[:], at: i64) -> i64 { match_end(line, at, '(', ')') }

fn call_open(line: const u8[:], at: i64) -> i64 {
    var i = at + 1;
    loop {
        if i >= line.len || !ident_start(line[i]) { return -1; }
        while i < line.len && ident_char(line[i]) { i += 1; }
        if i + 1 < line.len && line[i] == ':' && line[i + 1] == ':' { i += 2; continue; }
        break;
    }
    if i < line.len && line[i] == '(' { return i; }
    return -1;
}

fn skip_attr(line: const u8[:], i: i64) -> i64 {
    if i == 0 || (line[i - 1] != ' ' && line[i - 1] != '\t') { return i; }
    var q = i;
    if starts_with(line[i..], "on:") { q = i + 3; }
    else if starts_with(line[i..], "bind:") { q = i + 5; }
    else { return i; }
    while q < line.len && line[q] >= 'a' && line[q] <= 'z' { q += 1; }
    if q + 1 >= line.len || line[q] != '=' || (line[q + 1] != '"' && line[q + 1] != '\'') { return i; }
    let qc = line[q + 1];
    var e = q + 2;
    while e < line.len && line[e] != qc { e += 1; }
    if e >= line.len { return i; }
    return e + 1;
}

fn raw_end(line: const u8[:], from: i64, st: i64&) -> i64 {
    let name = if st == SCRIPT { "script" } else { "style" };
    for i in from..line.len {
        if line[i] == '<' && i + 1 < line.len && line[i + 1] == '/' && starts_nocase(line, i + 2, name) {
            st = MARKUP;
            return i;
        }
    }
    return line.len;
}

// When a <script> or <style> start tag closes first, st becomes raw and the index is after its '>'.
fn next(line: const u8[:], from: i64, st: i64&, attrs: bool) -> i64 {
    var i = from;
    while i < line.len {
        let c = line[i];
        if c == '{' || c == '}' { return i; }
        if c == '@' && call_open(line, i) >= 0 { return i; }
        if c == '<' && st == MARKUP {
            if opens_element(line, i, "script") { st = SCRIPT_TAG; }
            else if opens_element(line, i, "style") { st = STYLE_TAG; }
        } else if c == '>' && st != MARKUP {
            st = if st == SCRIPT_TAG { SCRIPT } else { STYLE };
            return i + 1;
        } else if attrs && (c == 'o' || c == 'b') {
            let j = skip_attr(line, i);
            if j > i { i = j; continue; }
        }
        i += 1;
    }
    return line.len;
}

fn old_syntax(rest: const u8[:]) -> const u8[:] {
    if starts_with(rest, "{{{") { return "'{{{ e }}}' is the old syntax: write {#raw e}"; }
    if starts_with(rest, "{{--") { return "'{{-- --}}' is the old syntax: write {-- note --}"; }
    let t = trim(rest[2..]);
    if starts_with(t, ">") { return "'{{> f(a)}}' is the old syntax: write @f(a)"; }
    if starts_with(t, "component ") { return "'{{component Name(e)}}' is the old syntax: write @Name(e)"; }
    if starts_with(t, "slot}}") { return "'{{slot}}' is the old syntax: write @slot()"; }
    if starts_with(t, "#") || starts_with(t, "/") { return "'{{#tag}}' is the old syntax: write it with one brace, as in {#if e} and {/if}"; }
    return "'{{ e }}' is the old syntax: write {e} (escaped) or {#raw e} (not escaped)";
}
