// Part of gweb. Import with `import gweb.auth.crypto;`.

namespace gweb;

import std;
import gweb;

extern fn c_sha256(out: u8[:], msg: const u8[:]) -> i32 = "gweb_sha256";
extern fn c_hmac_sha256(out: u8[:], key: const u8[:], msg: const u8[:]) -> i32 = "gweb_hmac_sha256";
extern fn c_pbkdf2_sha256(out: u8[:], pw: const u8[:], salt: const u8[:], iter: i64) -> i32 = "gweb_pbkdf2_sha256";

// The C side refuses any other output length, so a bad call leaves out unchanged and returns false.
fn sha256(out: u8[..32]&, msg: const u8[:]) -> bool {
    return c_sha256(out, msg) != 0;
}

fn hmac_sha256(out: u8[..32]&, key: const u8[:], msg: const u8[:]) -> bool {
    return c_hmac_sha256(out, key, msg) != 0;
}

// out.len 1..64, iter 1..10,000,000.
fn pbkdf2_sha256(out: u8[:], pw: const u8[:], salt: const u8[:], iter: i64) -> bool {
    return c_pbkdf2_sha256(out, pw, salt, iter) != 0;
}

fn _b64_value(c: u8) -> i64 {
    if c >= 'A' && c <= 'Z' { return c - 'A'; }
    if c >= 'a' && c <= 'z' { return (c - 'a') as i64 + 26; }
    if c >= '0' && c <= '9' { return (c - '0') as i64 + 52; }
    if c == '-' { return 62; }
    if c == '_' { return 63; }
    return -1;
}

// Unpadded base64url; false for a byte outside the alphabet or a length of 1 mod 4. Stray trailing bits are ignored.
fn b64url_decode(out: u8[>..]&, s: const u8[:]) -> bool {
    if s.len % 4 == 1 { return false; }
    for c in s { if _b64_value(c) < 0 { return false; } }
    var i = 0;
    while i < s.len {
        let left = s.len - i;
        let a = _b64_value(s[i]);
        let b = _b64_value(s[i + 1]);
        out.push(((a << 2) | (b >> 4)) as u8);
        if left > 2 {
            let c = _b64_value(s[i + 2]);
            out.push((((b & 15) << 4) | (c >> 2)) as u8);
            if left > 3 {
                let d = _b64_value(s[i + 3]);
                out.push((((c & 3) << 6) | d) as u8);
            }
        }
        i += 4;
    }
    return true;
}

// Different lengths are false at once (lengths are not secret); equal lengths are compared in full.
fn bytes_equal(a: const u8[:], b: const u8[:]) -> bool {
    if a.len != b.len { return false; }
    var diff = 0;
    for i in a.len { diff |= a[i] ^ b[i]; }
    return diff == 0;
}

// At most 256 bytes per call; false when the OS refuses.
fn random_bytes(out: u8[:]) -> bool {
    if out.len > 256 { return false; }
    return c_entropy(out) != 0;
}
