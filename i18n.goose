// Part of goose-web. Import with `import web.i18n;`. Runtime of the generated `t` module (DESIGN-ADDENDUM-17, Decision 4).

namespace web;

import std;
import net;
import net.http;
import web;

// The language subtag of a tag: the text before the first '-'.
fn lang_part(tag: const u8[:]) -> const u8[:] {
    var i = 0;
    while i < tag.len && tag[i] != '-' { i += 1; }
    return tag[..i];
}

// The second subtag of a tag ("" when none): the region in "pt-PT".
fn second_part(tag: const u8[:]) -> const u8[:] {
    var i = 0;
    while i < tag.len && tag[i] != '-' { i += 1; }
    if i >= tag.len { return ""; }
    var j = i + 1;
    while j < tag.len && tag[j] != '-' { j += 1; }
    return tag[i + 1..j];
}

fn lang_is(lang: const u8[:], a: const u8[:]) -> bool { return http::eq_nocase(lang, a); }

// The plural category of n for a full tag: 0 zero, 1 one, 2 two, 3 few, 4 many, 5 other (CLDR integer rules).
fn plural_index(lang: const u8[:], n: i64) -> i64 {
    var m = n;
    if m < 0 { m = 0 - m; if m < 0 { m = 0; } }
    let l = lang_part(lang);
    let m10 = m % 10;
    let m100 = m % 100;
    if lang_is(l, "fr") { return if m == 0 || m == 1 { 1 } else { 5 }; }
    if lang_is(l, "pt") {
        if http::eq_nocase(second_part(lang), "PT") { return if m == 1 { 1 } else { 5 }; }
        return if m == 0 || m == 1 { 1 } else { 5 };
    }
    if lang_is(l, "ru") || lang_is(l, "uk") || lang_is(l, "be") {
        if m10 == 1 && m100 != 11 { return 1; }
        if m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14) { return 3; }
        return 4;
    }
    if lang_is(l, "pl") {
        if m == 1 { return 1; }
        if m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14) { return 3; }
        return 4;
    }
    if lang_is(l, "cs") || lang_is(l, "sk") {
        if m == 1 { return 1; }
        if m >= 2 && m <= 4 { return 3; }
        return 5;
    }
    if lang_is(l, "ar") {
        if m == 0 { return 0; }
        if m == 1 { return 1; }
        if m == 2 { return 2; }
        if m100 >= 3 && m100 <= 10 { return 3; }
        if m100 >= 11 && m100 <= 99 { return 4; }
        return 5;
    }
    if lang_is(l, "he") {
        if m == 1 { return 1; }
        if m == 2 { return 2; }
        return 5;
    }
    if lang_is(l, "ja") || lang_is(l, "zh") || lang_is(l, "ko") || lang_is(l, "vi")
       || lang_is(l, "th") || lang_is(l, "id") || lang_is(l, "ms") { return 5; }
    return if m == 1 { 1 } else { 5 };
}

// The index of the tag equal to want, ignoring case; -1 when none.
fn tag_exact(tags: const u8[:][:], want: const u8[:]) -> i64 {
    var i = 0;
    while i < tags.len {
        if http::eq_nocase(tags[i], want) { return i; }
        i += 1;
    }
    return -1;
}

// The first tag whose language subtag equals lang; -1 when none.
fn tag_by_lang(tags: const u8[:][:], lang: const u8[:]) -> i64 {
    var i = 0;
    while i < tags.len {
        if http::eq_nocase(lang_part(tags[i]), lang) { return i; }
        i += 1;
    }
    return -1;
}

// "0", "1", "0.8", "1.000" as thousandths; -1 when malformed.
fn parse_q(s: const u8[:]) -> i64 {
    if s.len == 0 || s.len > 5 { return -1; }
    if s[0] != '0' && s[0] != '1' { return -1; }
    var q = (s[0] - '0') as i64 * 1000;
    if s.len == 1 { return q; }
    if s[1] != '.' || s.len == 2 { return -1; }
    var scale = 100;
    var i = 2;
    while i < s.len {
        if s[i] < '0' || s[i] > '9' { return -1; }
        q += (s[i] - '0') * scale;
        scale = scale / 10;
        i += 1;
    }
    if q > 1000 { return -1; }
    return q;
}

// The index into tags for this request: the `locale` cookie, then Accept-Language, then 0.
fn pick_locale(req: const http::Request&, tags: const u8[:][:]) -> i64 {
    let c, has_c = http::cookie(req, "locale");
    if has_c {
        let k = tag_exact(tags, c);
        if k >= 0 { return k; }
    }
    let line, has = http::header(req, "accept-language");
    if !has { return 0; }

    var etag: const u8[:][16] = [""; 16];
    var eq: i64[16] = [0; 16];
    var n = 0;
    each_split(line, ',') { item =>
        if n < 16 {
            let tag, params, has_params = split_once(item, ';');
            let t = trim(tag);
            var q = 1000;
            var ok = t.len > 0;
            if ok && has_params {
                each_split(params, ';') { p =>
                    let key, value, has_eq = split_once(p, '=');
                    if has_eq && http::eq_nocase(trim(key), "q") { q = parse_q(trim(value)); }
                };
                if q < 0 { ok = false; }
            }
            if ok { etag[n] = t; eq[n] = q; n += 1; }
        }
    };

    // Stable insertion sort of entry indexes by q, descending.
    var order: i64[16] = [0; 16];
    for i in n { order[i] = i; }
    var i = 1;
    while i < n {
        let cur = order[i];
        var j = i;
        while j > 0 && eq[order[j - 1]] < eq[cur] {
            order[j] = order[j - 1];
            j -= 1;
        }
        order[j] = cur;
        i += 1;
    }

    var r = 0;
    while r < n {
        let e = order[r];
        r += 1;
        if eq[e] == 0 || etag[e] == "*" { continue; }
        let k = tag_exact(tags, etag[e]);
        if k >= 0 { return k; }
        let l = lang_part(etag[e]);
        let k2 = tag_exact(tags, l);
        if k2 >= 0 { return k2; }
        let k3 = tag_by_lang(tags, l);
        if k3 >= 0 { return k3; }
    }
    return 0;
}
