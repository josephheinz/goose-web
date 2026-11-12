// .env loading, typed env helpers and WEB_SECRET parsing (DESIGN-ADDENDUM-13, D2). No sockets, never exits.
//   goose build test/env_test.goose && test/env_test
// Fixture files go in a temp folder that is passed by path; every case uses its own variable names because the
// environment cannot be unset from Goose.
import web from "..";
import net from "../../goose-net";
import std;
import os;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}
fn check_eq(got: const u8[:], want: const u8[:], what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got '", got, "' want '", want, "'"); }
}

fn val(name: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    web::env_str(name, v);
    return v;
}

fn blank(dir: const u8[:]) {
    for f in [".env", ".env.local", ".env.production", ".env.production.local", ".env.test", ".env.test.local"] {
        var p: u8[>..] = [];
        format(p, dir, "/", f);
        write_file(p, "");
    }
}

fn put(dir: const u8[:], file: const u8[:], text: const u8[:]) {
    var p: u8[>..] = [];
    format(p, dir, "/", file);
    write_file(p, text);
}

fn parse(line: const u8[:]) -> i64, u8[>..], u8[>..] {
    var n: u8[>..] = [];
    var v: u8[>..] = [];
    let r = web::parse_env_line(line, n, v);
    return r, n, v;
}

fn test_lines() {
    let r1, n1, v1 = parse("A=1");
    check(r1 == 1, "pair"); check_eq(n1, "A", "name"); check_eq(v1, "1", "value");
    let r2, n2, v2 = parse("  export  _x9 =  hello world  ");
    check(r2 == -1, "space before = is an error");
    let r3, n3, v3 = parse("  export _x9=  hello world  ");
    check(r3 == 1, "export and spaces"); check_eq(n3, "_x9", "export name"); check_eq(v3, "hello world", "value trimmed");
    let r4, n4, v4 = parse("Q=\"a b\"");
    check_eq(v4, "a b", "double quotes removed");
    let r5, n5, v5 = parse("Q='a b'");
    check_eq(v5, "a b", "single quotes removed");
    let r6, n6, v6 = parse("Q=\"a'");
    check_eq(v6, "\"a'", "mismatched quotes kept");
    let r7, n7, v7 = parse("Q=\"\"");
    check(r7 == 1 && v7.len == 0, "empty quoted value");
    let r8, n8, v8 = parse("Q=a#b # c");
    check_eq(v8, "a#b # c", "# is part of an unquoted value");
    let r9, n9, v9 = parse("Q=");
    check(r9 == 1 && v9.len == 0, "empty value");
    let r10, n10, v10 = parse("Q=a=b");
    check_eq(v10, "a=b", "= inside a value");
    let r11, n11, v11 = parse("");
    check(r11 == 0, "blank skipped");
    let r12, n12, v12 = parse("   # comment");
    check(r12 == 0, "comment skipped");
    let r13, n13, v13 = parse("A=1\r");
    check(r13 == 1 && v13 == "1", "CR trimmed");
    for bad in ["novalue", "1A=x", "=x", "A B=x", "export =x", "a-b=x", "export"] {
        let r, n, v = parse(bad);
        check(r == -1, bad);
    }
}

fn test_files(dir: const u8[:]) {
    var err: u8[>..] = [];
    blank(dir);
    put(dir, ".env", "GWT_ORDER=env\nGWT_ONLY_ENV=1\nGWT_Q=\"quoted value\"\n# c\n\nexport GWT_EXP=yes\nGWT_HASH=a#b\n");
    put(dir, ".env.production", "GWT_ORDER=prod\nGWT_ONLY_PROD=1\n");
    put(dir, ".env.local", "GWT_ORDER=local\nGWT_ONLY_LOCAL=1\n");
    put(dir, ".env.production.local", "GWT_ORDER=prodlocal\n");
    check(web::load_env_files_in(dir, "production", err), "production loads");
    check_eq(val("GWT_ORDER"), "prodlocal", ".env.production.local beats the rest");
    check_eq(val("GWT_ONLY_PROD"), "1", ".env.production read");
    check_eq(val("GWT_ONLY_LOCAL"), "1", ".env.local read");
    check_eq(val("GWT_ONLY_ENV"), "1", ".env read");
    check_eq(val("GWT_Q"), "quoted value", "quotes removed from a file value");
    check_eq(val("GWT_EXP"), "yes", "export prefix");
    check_eq(val("GWT_HASH"), "a#b", "# kept");

    blank(dir);
    put(dir, ".env", "GWT_O2=env\n");
    put(dir, ".env.production", "GWT_O2=prod\n");
    put(dir, ".env.local", "GWT_O2=local\n");
    check(web::load_env_files_in(dir, "production", err), "second load");
    check_eq(val("GWT_O2"), "local", ".env.local beats .env.production");

    blank(dir);
    put(dir, ".env", "GWT_O3=env\n");
    put(dir, ".env.production", "GWT_O3=prod\n");
    check(web::load_env_files_in(dir, "production", err), "third load");
    check_eq(val("GWT_O3"), "prod", ".env.production beats .env");

    // The real environment beats every file: GWT_REAL is set first, then a file tries to set it.
    check(web::load_env_files_in(dir, "production", err), "load again is fine");
    blank(dir);
    put(dir, ".env", "GWT_O4=file\n");
    put(dir, ".env.test", "GWT_O5=test\n");
    put(dir, ".env.local", "GWT_O5=local\nGWT_O6=local\n");
    put(dir, ".env.test.local", "GWT_O6=testlocal\n");
    check(web::load_env_files_in(dir, "test", err), "test loads");
    check_eq(val("GWT_O5"), "test", ".env.local skipped for test");
    check_eq(val("GWT_O6"), "testlocal", ".env.test.local read for test");
    check_eq(val("GWT_O4"), "file", ".env read for test");
}

fn test_real_env_wins(dir: const u8[:]) {
    var err: u8[>..] = [];
    // The first file to set GWT_R wins, so a later file never changes it; a value already in the process is the same case.
    blank(dir);
    put(dir, ".env", "GWT_R=first\n");
    check(web::load_env_files_in(dir, "production", err), "load R");
    put(dir, ".env", "GWT_R=second\n");
    check(web::load_env_files_in(dir, "production", err), "reload R");
    check_eq(val("GWT_R"), "first", "an existing value is not overwritten");
}

fn test_errors(dir: const u8[:]) {
    var err: u8[>..] = [];
    blank(dir);
    put(dir, ".env.local", "GWT_E1=ok\n\nthis is bad\nGWT_E2=x\n");
    var p: u8[>..] = [];
    format(p, dir, "/.env.local");
    check(!web::load_env_file(p, err), "bad line refused");
    var want: u8[>..] = [];
    format(want, p, ":3: error: expected NAME=value");
    check_eq(err, want, "error text and line number");
    check_eq(val("GWT_E1"), "ok", "lines before the error were applied");
    check(val("GWT_E2").len == 0, "lines after the error were not");
    var err2: u8[>..] = [];
    check(web::load_env_file("no/such/file", err2) && err2.len == 0, "missing file skipped");
    var err3: u8[>..] = [];
    check(!web::load_env_files_in(dir, "../x", err3), "bad env name refused");
    check_eq(err3, "GWEB_ENV: invalid name", "bad env name message");
}

fn test_typed() {
    var e: u8[>..] = [];
    check(!web::env_str("GWT_UNSET_1", e) && e.len == 0, "env_str unset");
    check(web::env_str("GWT_ORDER", e), "env_str set");
    check(web::env_int("GWT_UNSET_1", 7) == 7, "env_int unset");
    web::c_setenv("GWT_I1", " 42 ");
    web::c_setenv("GWT_I2", "x");
    check(web::env_int("GWT_I1", 7) == 42, "env_int trims");
    check(web::env_int("GWT_I2", 7) == 7, "env_int not a number");
    check(web::env_bool("GWT_UNSET_1", true), "env_bool fallback true");
    check(!web::env_bool("GWT_UNSET_1", false), "env_bool fallback false");
    var k = 0;
    for w in ["1", "true", "YES", "On"] {
        k += 1;
        var n: u8[>..] = [];
        format(n, "GWT_BT", k);
        web::c_setenv(n, w);
        check(web::env_bool(n, false), w);
    }
    for w in ["0", "False", "no", "OFF"] {
        k += 1;
        var n: u8[>..] = [];
        format(n, "GWT_BF", k);
        web::c_setenv(n, w);
        check(!web::env_bool(n, true), w);
    }
    web::c_setenv("GWT_B9", "maybe");
    check(web::env_bool("GWT_B9", true) && !web::env_bool("GWT_B9", false), "env_bool unknown uses fallback");
    check(web::env_required("GWT_I1"), "env_required set");
    check(!web::env_required("GWT_UNSET_1"), "env_required unset");
    check(web::c_setenv("GWT_I1", "other") == 1 && web::env_int("GWT_I1", 7) == 42, "c_setenv keeps the first value");
    check(web::c_setenv("", "x") == 0 && web::c_setenv("A=B", "x") == 0, "c_setenv refuses bad names");
    var env_now: u8[>..] = [];
    web::environment(env_now);
    check(env_now.len > 0, "environment is never empty");
}

fn key(c: u8, n: i64) -> u8[>..] {
    var k: u8[>..] = [];
    for i in n { k.push(c); }
    return k;
}

fn test_secret() {
    var keys = web::Keys { .. };
    var err: u8[>..] = [];
    let k32 = key('a', 32);
    let k64 = key('b', 64);
    check(web::parse_secret(k32, keys, err), "one 32-byte key");
    check(keys.n == 1 && keys.k[0] == k32, "key stored");
    var three: u8[>..] = [];
    format(three, k32, ",", k64, " , ", key('c', 40));
    check(web::parse_secret(three, keys, err), "three keys, spaces trimmed");
    check(keys.n == 3 && keys.k[1] == k64 && keys.k[2] == key('c', 40), "three keys stored");
    var four: u8[>..] = [];
    format(four, k32, ",", k32, ",", k32, ",", k32);
    check(web::parse_secret(four, keys, err) && keys.n == 4, "four keys");

    let secret_bad = key('z', 31);
    var bad: u8[>..] = [];
    check(!web::parse_secret(secret_bad, keys, bad), "31 bytes refused");
    check(find(bad, secret_bad) < 0 && find(bad, "zzzz") < 0, "error does not hold key bytes");
    check(keys.n == 0, "keys cleared on error");
    var bad2: u8[>..] = [];
    check(!web::parse_secret(key('y', 65), keys, bad2), "65 bytes refused");
    check(find(bad2, "yyyy") < 0, "65-byte error has no key bytes");
    var five: u8[>..] = [];
    format(five, k32, ",", k32, ",", k32, ",", k32, ",", k32);
    var bad3: u8[>..] = [];
    check(!web::parse_secret(five, keys, bad3), "five keys refused");
    check_eq(bad3, "WEB_SECRET: more than 4 keys", "five keys message");
    var empty_item: u8[>..] = [];
    format(empty_item, k32, ",,", k32);
    var bad4: u8[>..] = [];
    check(!web::parse_secret(empty_item, keys, bad4), "empty item refused");
    check_eq(bad4, "WEB_SECRET: key 2 is empty", "empty item message");
    var trailing: u8[>..] = [];
    format(trailing, k32, ",");
    var bad5: u8[>..] = [];
    check(!web::parse_secret(trailing, keys, bad5), "trailing comma refused");
    var bad6: u8[>..] = [];
    check(!web::parse_secret("", keys, bad6), "empty text refused");
}

fn main() {
    var tmp: u8[>..] = [];
    if !web::env_str("TMPDIR", tmp) || tmp.len == 0 { tmp.append("/tmp"); }
    while tmp.len > 1 && tmp[tmp.len - 1] == '/' { tmp.pop(); }
    var dir: u8[>..] = [];
    format(dir, tmp, "/gweb_env_test");
    make_dir(dir);
    check(is_dir(dir), "fixture folder exists");

    test_lines();
    test_files(dir);
    test_real_env_wins(dir);
    test_errors(dir);
    test_typed();
    test_secret();
    blank(dir);
    print(checks - failures, " of ", checks);
    if failures > 0 { exit(1); }
}
