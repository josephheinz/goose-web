// html: the HTML attribute lists and the scan that checks the open tags of markup against them
// (Addendum 12, section 8.2). Shared by gweb.goose (page templates) and component.goose. Plain arrays.

namespace html;

import std;
import tscan;

// Allowed on every element.
let GLOBAL = ["accesskey", "anchor", "autocapitalize", "autocorrect", "autofocus", "class", "contenteditable", "dir",
              "draggable", "enterkeyhint", "exportparts", "hidden", "id", "inert", "inputmode", "is", "itemid",
              "itemprop", "itemref", "itemscope", "itemtype", "lang", "nonce", "part", "popover", "role", "slot",
              "spellcheck", "style", "tabindex", "title", "translate", "writingsuggestions"];

// gweb's own attributes.
let GW = ["gw-key", "gw-target", "gw-boost", "gw-enter", "gw-leave", "gw-sse", "gw-loading", "gw-trigger", "gw-url"];

// `tag,tag: attribute attribute ...`. An element that is not listed takes the global attributes only.
let ELEMENTS = [
    "a: href target download rel hreflang type ping referrerpolicy",
    "area: alt coords download href hreflang ping referrerpolicy rel shape target",
    "audio: src controls autoplay loop muted preload crossorigin controlslist disableremoteplayback",
    "video: src controls autoplay loop muted preload crossorigin poster width height playsinline controlslist disablepictureinpicture disableremoteplayback",
    "base: href target",
    "blockquote,q: cite",
    "button: type name value disabled form formaction formenctype formmethod formnovalidate formtarget popovertarget popovertargetaction",
    "canvas: width height",
    "col,colgroup: span",
    "data: value",
    "del,ins: cite datetime",
    "details: open name",
    "dialog: open",
    "embed: src type width height",
    "fieldset: disabled form name",
    "form: action method enctype target novalidate autocomplete accept-charset name rel",
    "html: xmlns",
    "iframe: src srcdoc name sandbox allow allowfullscreen width height loading referrerpolicy",
    "img: src srcset sizes alt width height loading decoding crossorigin usemap ismap referrerpolicy fetchpriority",
    "input: type name value placeholder required disabled readonly checked min max step minlength maxlength pattern size multiple accept autocomplete list form formaction formenctype formmethod formnovalidate formtarget alt src width height capture dirname popovertarget popovertargetaction",
    "label: for form",
    "li: value",
    "link: href rel type media as crossorigin integrity hreflang sizes referrerpolicy fetchpriority imagesrcset imagesizes blocking disabled color",
    "map: name",
    "meta: name content charset http-equiv property media",
    "meter: value min max low high optimum form",
    "object: data type name width height form usemap",
    "ol: reversed start type",
    "optgroup: disabled label",
    "option: value selected disabled label",
    "output: for form name",
    "progress: value max",
    "script: src type async defer crossorigin integrity nomodule referrerpolicy blocking fetchpriority",
    "select: name required disabled multiple size autocomplete form",
    "slot: name",
    "source: src srcset sizes type media width height",
    "style: media type blocking",
    "table: border cellpadding cellspacing",
    "td: colspan rowspan headers",
    "template: shadowrootmode shadowrootdelegatesfocus shadowrootclonable",
    "textarea: name rows cols placeholder required disabled readonly maxlength minlength wrap autocomplete form dirname",
    "th: colspan rowspan headers scope abbr",
    "time: datetime",
    "track: kind src srclang label default"
];

// The events of on:EVENT (Addendum 12, 7.2b); in a component, `onclick=` for one of them is a mistake.
let EVENTS = ["click", "dblclick", "change", "input", "submit", "keydown", "keyup", "focus", "blur"];

fn lower(s: const u8[:]) -> u8[>..] {
    var r: u8[>..] = [];
    for c in s { r.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); }
    return r;
}

fn ws(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

fn name_ch(c: u8) -> bool { return tscan::ident_char(c) || c == '-' || c == ':'; }

fn word_in(words: const u8[:], w: const u8[:]) -> bool {
    for x in split(words, ' ') { if x == w { return true; } }
    return false;
}

fn element_has(tag: const u8[:], name: const u8[:]) -> bool {
    for e in ELEMENTS {
        let colon = find(e, ":");
        if colon < 0 || !word_in(e[colon + 1..], name) { continue; }
        for t in split(e[..colon], ',') { if t == tag { return true; } }
    }
    return false;
}

// `on` and a known event name: onclick.
fn inline_event(name: const u8[:]) -> bool {
    if name.len < 3 || name[0] != 'o' || name[1] != 'n' { return false; }
    for ev in EVENTS { if name[2..] == ev { return true; } }
    return false;
}

// Is name (lower case) an attribute of the element tag? Custom elements and `x:y` names are not checked.
fn accepts(tag: const u8[:], name: const u8[:]) -> bool {
    if find(tag, "-") >= 0 || find(tag, ":") >= 0 { return true; }
    if starts_with(name, "data-") || starts_with(name, "aria-") || starts_with(name, "on:") || starts_with(name, "bind:") { return true; }
    if name.len > 2 && name[0] == 'o' && name[1] == 'n' {
        var letters = true;
        for c in name[2..] { if c < 'a' || c > 'z' { letters = false; } }
        if letters { return true; }
    }
    for g in GLOBAL { if g == name { return true; } }
    for g in GW { if g == name { return true; } }
    return element_has(tag, name);
}

fn line_end_of(src: const u8[:], i: i64) -> i64 {
    var e = i;
    while e < src.len && src[e] != '\n' { e += 1; }
    return e;
}

// The index after the {...} that opens at src[i]; i + 1 when it does not close on its line.
fn skip_brace(src: const u8[:], i: i64) -> i64 {
    let ln = src[i..line_end_of(src, i)];
    let e = tscan::brace_end(ln, 0);
    if e < 0 { return i + 1; }
    return i + e + 1;
}

// The index after the @name(...) call that starts at src[i] (`@asset("/x")`, `@gweb::csrf_field(ctx)`), with
// strings and nested parentheses skipped; -1 when src[i] does not start one that closes.
fn skip_call(src: const u8[:], i: i64) -> i64 {
    if src[i] != '@' { return -1; }
    var j = i + 1;
    while j < src.len && (tscan::ident_char(src[j]) || src[j] == ':') { j += 1; }
    if j == i + 1 || j >= src.len || src[j] != '(' { return -1; }
    var depth = 0;
    while j < src.len {
        let c = src[j];
        if c == '"' || c == '\'' {
            j += 1;
            while j < src.len && src[j] != c { if src[j] == '\\' { j += 1; } j += 1; }
        } else if c == '(' { depth += 1; }
        else if c == ')' { depth -= 1; if depth == 0 { return j + 1; } }
        j += 1;
    }
    return -1;
}

fn count_lines(src: const u8[:], from: i64, to: i64) -> i64 {
    var k = 0;
    for j in from..min(to, src.len) { if src[j] == '\n' { k += 1; } }
    return k;
}

fn report(out: u8[>..]&, line: i64, name: const u8[:], tag: const u8[:], comp: bool) {
    if comp && inline_event(name) {
        format(out, line, "\tuse on:", name[2..], ", not ", name, "\n");
    } else {
        format(out, line, "\tunknown attribute '", name, "' on <", tag, ">\n");
    }
}

// The attributes of the open tag whose name ended at `at`. Returns the index after its `>`. closed: it ends in `/>`.
fn scan_tag(src: const u8[:], at: i64, tag: const u8[:], check_it: bool, comp: bool, line: i64&, closed: bool&,
            out: u8[>..]&) -> i64 {
    let n = src.len;
    var i = at;
    var after_expr = false;
    while i < n {
        let c = src[i];
        if c == '>' { return i + 1; }
        if c == '\n' { line += 1; i += 1; after_expr = false; continue; }
        if ws(c) { i += 1; after_expr = false; continue; }
        if c == '/' { if i + 1 < n && src[i + 1] == '>' { closed = true; } i += 1; continue; }
        if c == '{' { i = skip_brace(src, i); after_expr = true; continue; }
        let call = skip_call(src, i);
        if call > 0 { line += count_lines(src, i, call); i = call; after_expr = true; continue; }
        let s = i;
        while i < n && !ws(src[i]) && src[i] != '>' && src[i] != '=' && src[i] != '/' && src[i] != '{' { i += 1; }
        let name = lower(src[s..i]);
        let partial = after_expr || (i < n && src[i] == '{');
        after_expr = false;
        let at_line = line;
        if i < n && src[i] == '=' {
            i += 1;
            if i < n && (src[i] == '"' || src[i] == '\'') {
                let q = src[i];
                i += 1;
                while i < n && src[i] != q {
                    let call = skip_call(src, i);
                    if call > 0 { line += count_lines(src, i, call); i = call; }
                    else if src[i] == '{' { i = skip_brace(src, i); }
                    else { if src[i] == '\n' { line += 1; } i += 1; }
                }
                if i < n { i += 1; }
            } else {
                while i < n && !ws(src[i]) && src[i] != '>' {
                    if src[i] == '{' { i = skip_brace(src, i); } else { i += 1; }
                }
            }
        }
        if check_it && !partial && name.len > 0 && ((comp && inline_event(name)) || !accepts(tag, name)) {
            report(out, at_line, name, tag, comp);
        }
    }
    return n;
}

// Checks the open tags of src[start..]. line0 is the line number of src[start]. comp: component markup, where
// `onclick=` is a mistake. Appends `LINE\tMESSAGE\n` to out for each attribute that is not accepted. Nothing is
// checked inside <svg> and <math>, or in the text of <script> and <style>.
fn check(src: const u8[:], start: i64, line0: i64, comp: bool, out: u8[>..]&) {
    let n = src.len;
    var i = start;
    var line = line0;
    var foreign = 0;
    while i < n {
        let c = src[i];
        if c == '\n' { line += 1; i += 1; continue; }
        if c == '{' {
            if starts_with(src[i..], "{--") {
                let e = find(src[i..line_end_of(src, i)], "--}");
                i = if e < 0 { i + 3 } else { i + e + 3 };
            } else { i = skip_brace(src, i); }
            continue;
        }
        if c == '@' {
            let ln = src[i..line_end_of(src, i)];
            let open = tscan::call_open(ln, 0);
            let close = if open >= 0 { tscan::paren_end(ln, open) } else { -1 };
            i = if close >= 0 { i + close + 1 } else { i + 1 };
            continue;
        }
        if c != '<' { i += 1; continue; }
        if starts_with(src[i..], "<!--") {
            let e = find(src[i..], "-->");
            let stop = if e < 0 { n } else { i + e + 3 };
            line += count_lines(src, i, stop);
            i = stop;
            continue;
        }
        if i + 1 >= n { break; }
        if src[i + 1] == '/' {
            var j = i + 2;
            while j < n && name_ch(src[j]) { j += 1; }
            let nm = lower(src[i + 2..j]);
            if nm == "svg" || nm == "math" { foreign = max(0, foreign - 1); }
            i = j;
            continue;
        }
        if !tscan::ident_start(src[i + 1]) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while j < n && name_ch(src[j]) { j += 1; }
        let tag = lower(src[i + 1..j]);
        var closed = false;
        let is_foreign = tag == "svg" || tag == "math";
        i = scan_tag(src, j, tag, foreign == 0 && !is_foreign, comp, line, closed, out);
        if is_foreign && !closed { foreign += 1; }
        if (tag == "script" || tag == "style") && !closed {
            var k = i;
            while k < n && !(src[k] == '<' && k + 1 < n && src[k + 1] == '/' && tscan::starts_nocase(src, k + 2, tag)) { k += 1; }
            line += count_lines(src, i, k);
            i = k;
        }
    }
}
