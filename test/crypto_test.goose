// Crypto wrappers (DESIGN-ADDENDUM-13, D1), without sockets. The C vectors live in crypto_test.c.
//   goose build test/crypto_test.goose && test/crypto_test
import gweb from "..";
import gweb.auth.crypto;
import net from "../../goose-net";
import std;

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

let HEX = "0123456789abcdef";

fn hex(out: u8[>..]&, data: const u8[:]) {
    for b in data {
        out.push(HEX[(b >> 4) as i64]);
        out.push(HEX[(b & 15) as i64]);
    }
}

fn sha_hex(msg: const u8[:]) -> u8[>..] {
    var d: u8[..32] = [0; 32];
    check(gweb::sha256(d, msg), "sha256 accepts 32");
    var h: u8[>..] = [];
    hex(h, d);
    return h;
}

fn hmac_hex(key: const u8[:], msg: const u8[:]) -> u8[>..] {
    var d: u8[..32] = [0; 32];
    check(gweb::hmac_sha256(d, key, msg), "hmac accepts 32");
    var h: u8[>..] = [];
    hex(h, d);
    return h;
}

fn enc(data: const u8[:]) -> u8[>..] {
    var o: u8[>..] = [];
    gweb::b64url(o, data);
    return o;
}

fn round_trip(data: const u8[:], what: const u8[:]) {
    let e = enc(data);
    var back: u8[>..] = [];
    check(gweb::b64url_decode(back, e), what);
    check_eq(back, data, what);
}

fn refuses(s: const u8[:], what: const u8[:]) {
    var back: u8[>..] = [];
    check(!gweb::b64url_decode(back, s), what);
}

fn main() {
    check_eq(sha_hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha empty");
    check_eq(sha_hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha abc");
    check_eq(sha_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha 448 bit");

    check_eq(hmac_hex("Jefe", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "hmac rfc4231 2");
    var key: u8[>..] = [];
    for i in 131 { key.push(0xaa); }
    check_eq(hmac_hex(key, "Test Using Larger Than Block-Size Key - Hash Key First"), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "hmac rfc4231 6 (long key)");


    var dk: u8[..32] = [0; 32];
    check(gweb::pbkdf2_sha256(dk, "password", "salt", 2), "pbkdf2 accepts");
    var dkh: u8[>..] = [];
    hex(dkh, dk);
    check_eq(dkh, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", "pbkdf2 c=2");
    check(!gweb::pbkdf2_sha256(dk, "password", "salt", 0), "pbkdf2 refuses iter 0");
    check(!gweb::pbkdf2_sha256(dk, "password", "salt", 10000001), "pbkdf2 refuses iter above max");

    check_eq(enc(""), "", "b64url empty");
    check_eq(enc("f"), "Zg", "b64url f");
    check_eq(enc("fo"), "Zm8", "b64url fo");
    check_eq(enc("foo"), "Zm9v", "b64url foo");
    check_eq(enc("foob"), "Zm9vYg", "b64url foob");
    check_eq(enc("fooba"), "Zm9vYmE", "b64url fooba");
    check_eq(enc("foobar"), "Zm9vYmFy", "b64url foobar");
    var edge: u8[..2] = [0xfb, 0xff];
    check_eq(enc(edge), "-_8", "b64url 0xfb 0xff uses - and _");

    round_trip("", "round trip empty");
    round_trip("f", "round trip f");
    round_trip("fo", "round trip fo");
    round_trip("foo", "round trip foo");
    round_trip("foob", "round trip foob");
    round_trip("fooba", "round trip fooba");
    round_trip("foobar", "round trip foobar");
    round_trip(edge, "round trip 0xfb 0xff");
    var all: u8[>..] = [];
    for i in 256 { all.push(i as u8); }
    round_trip(all, "round trip all byte values");

    refuses("Zg==", "decode refuses =");
    refuses("Zm+v", "decode refuses +");
    refuses("Zm/v", "decode refuses /");
    refuses("Z", "decode refuses length 1");
    refuses("Zm9vY", "decode refuses length 5");
    refuses("Zm 9", "decode refuses a space");

    check(gweb::bytes_equal("abc", "abc"), "bytes_equal same");
    check(!gweb::bytes_equal("abc", "abd"), "bytes_equal last byte differs");
    check(!gweb::bytes_equal("abc", "xbc"), "bytes_equal first byte differs");
    check(!gweb::bytes_equal("abc", "ab"), "bytes_equal shorter");
    check(!gweb::bytes_equal("ab", "abc"), "bytes_equal longer");
    check(gweb::bytes_equal("", ""), "bytes_equal both empty");

    var r1: u8[..16] = [0; 16];
    var r2: u8[..16] = [0; 16];
    check(gweb::random_bytes(r1), "random_bytes 16");
    check(gweb::random_bytes(r2), "random_bytes 16 again");
    check(r1 != r2, "random_bytes differ");
    var big: u8[..257] = [0; 257];
    check(!gweb::random_bytes(big), "random_bytes refuses 257");

    print(checks - failures, " of ", checks, " checks pass");
    if failures > 0 { exit(1); }
}
