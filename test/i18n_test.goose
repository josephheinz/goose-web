// i18n runtime (DESIGN-ADDENDUM-17, Decision 4), without sockets.
//   goose build test/i18n_test.goose && test/i18n_test
import gweb from "..";
import net from "../../goose-net";
import net.http;
import gweb.site.i18n;
import std;

var failures = 0;
var checks = 0;

fn check_i(got: i64, want: i64, what: const u8[:]) {
    checks += 1;
    if got != want { failures += 1; print("FAIL ", what, ": got ", got, " want ", want); }
}

fn plural(lang: const u8[:], n: i64, want: i64) {
    let got = gweb::plural_index(lang, n);
    checks += 1;
    if got != want { failures += 1; print("FAIL plural ", lang, " ", n, ": got ", got, " want ", want); }
}

// extra: header lines, each ending in \r\n.
fn pick(extra: const u8[:], tags: const u8[:][:]) -> i64 {
    var raw: u8[>..] = [];
    format(raw, "GET / HTTP/1.1\r\nHost: a\r\n", extra, "\r\n");
    let req, parsed = http::parse_request(raw);
    return gweb::pick_locale(req, tags);
}

fn main() {
    // zero 0, one 1, two 2, few 3, many 4, other 5
    plural("en", 0, 5); plural("en", 1, 1); plural("en", 2, 5);
    plural("fr", 0, 1); plural("fr", 1, 1); plural("fr", 2, 5);
    plural("pt-BR", 0, 1); plural("pt", 1, 1); plural("pt-PT", 0, 5); plural("pt-PT", 1, 1);
    plural("ru", 1, 1); plural("ru", 2, 3); plural("ru", 5, 4); plural("ru", 11, 4);
    plural("ru", 21, 1); plural("ru", 22, 3); plural("ru", 25, 4);
    plural("pl", 1, 1); plural("pl", 2, 3); plural("pl", 5, 4); plural("pl", 22, 3);
    plural("cs", 1, 1); plural("cs", 2, 3); plural("cs", 5, 5);
    plural("ja", 1, 5);
    plural("ar", 0, 0); plural("ar", 1, 1); plural("ar", 2, 2); plural("ar", 3, 3);
    plural("ar", 11, 4); plural("ar", 100, 5);
    plural("he", 1, 1); plural("he", 2, 2); plural("he", 3, 5);
    plural("xx", 1, 1); plural("xx", 2, 5);
    plural("EN-us", 1, 1); plural("RU-RU", 21, 1); plural("en", -1, 1);

    let tags = ["en", "de", "fr-CA", "en-GB"];
    check_i(pick("", tags), 0, "no header");
    check_i(pick("Cookie: locale=de\r\n", tags), 1, "cookie");
    check_i(pick("Cookie: locale=DE\r\n", tags), 1, "cookie case");
    check_i(pick("Cookie: locale=fr\r\nAccept-Language: de\r\n", tags), 1, "cookie not a tag falls to header");
    check_i(pick("Cookie: locale=fr-ca\r\nAccept-Language: de\r\n", tags), 2, "cookie beats header");
    check_i(pick("Accept-Language: de\r\n", tags), 1, "exact tag");
    check_i(pick("accept-language: FR-ca\r\n", tags), 2, "exact tag, case");
    check_i(pick("Accept-Language: de;q=0.5, fr-CA;q=0.9\r\n", tags), 2, "q ordering");
    check_i(pick("Accept-Language: de;q=0.5, fr-CA\r\n", tags), 2, "default q is 1");
    check_i(pick("Accept-Language: fr-CA;q=0.5, de;q=0.5\r\n", tags), 2, "equal q keeps order");
    check_i(pick("Accept-Language: de-AT\r\n", tags), 1, "de-AT takes de");
    check_i(pick("Accept-Language: fr\r\n", tags), 2, "fr takes fr-CA");
    check_i(pick("Accept-Language: en-GB\r\n", ["de", "en-GB", "en"]), 1, "exact before language");
    check_i(pick("Accept-Language: en\r\n", ["de", "en-GB"]), 1, "en takes en-GB");
    check_i(pick("Accept-Language: ja, de;q=0.1\r\n", tags), 1, "unknown entry skipped");
    check_i(pick("Accept-Language: de;q=0, fr\r\n", tags), 2, "q=0 not acceptable");
    check_i(pick("Accept-Language: de;q=0\r\n", tags), 0, "only q=0 gives default");
    check_i(pick("Accept-Language: de;q=abc, fr\r\n", tags), 2, "malformed q skips entry");
    check_i(pick("Accept-Language: de;q=1.5, fr\r\n", tags), 2, "q above 1 skips entry");
    check_i(pick("Accept-Language: *, de;q=0.5\r\n", tags), 1, "* skipped");
    check_i(pick("Accept-Language: *\r\n", tags), 0, "only * gives default");
    check_i(pick("Accept-Language: ;;;, ,,;q=1, =\r\n", tags), 0, "garbage");
    check_i(pick("Accept-Language: \r\n", tags), 0, "empty header");
    check_i(pick("Accept-Language: de ; q = 0.8 , fr-CA;q=0.9\r\n", tags), 2, "spaces around q");

    // More than 16 entries: only the first 16 are read.
    var many: u8[>..] = [];
    for i in 16 { many.append("xx;q=0.1, "); }
    var late: u8[>..] = [];
    format(late, "Accept-Language: ", many, "de\r\n");
    check_i(pick(late, tags), 0, "17th entry ignored");
    var early: u8[>..] = [];
    format(early, "Accept-Language: de, ", many, "fr-CA\r\n");
    check_i(pick(early, tags), 1, "first of many");
    var sixteen: u8[>..] = [];
    for i in 15 { sixteen.append("xx;q=0.1, "); }
    var last: u8[>..] = [];
    format(last, "Accept-Language: ", sixteen, "de\r\n");
    check_i(pick(last, tags), 1, "16th entry read");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
