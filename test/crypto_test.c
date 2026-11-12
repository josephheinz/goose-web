/* Published vectors for src/crypto.c.
   Run: cc -O2 -Wall -o "$TMPDIR/ct" test/crypto_test.c src/crypto.c && "$TMPDIR/ct" */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t *data; int64_t len; } gweb_wbytes;
typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;
int32_t gweb_sha256(gweb_wbytes out, gweb_bytes msg);
int32_t gweb_hmac_sha256(gweb_wbytes out, gweb_bytes key, gweb_bytes msg);
int32_t gweb_pbkdf2_sha256(gweb_wbytes out, gweb_bytes pw, gweb_bytes salt, int64_t iter);

static int checks = 0, failures = 0;

static void check(int ok, const char *what) {
    checks++;
    if (!ok) { failures++; printf("FAIL %s\n", what); }
}

static gweb_bytes B(const void *p, size_t n) { gweb_bytes b = { p, (int64_t)n }; return b; }
static gweb_bytes S(const char *s) { return B(s, strlen(s)); }

static void hex(const uint8_t *p, size_t n, char *out) {
    out[0] = 0;
    for (size_t i = 0; i < n; i++) snprintf(out + 2 * i, 3, "%02x", p[i]);
}

/* Compares the first `len` output bytes with the hex string. */
static void check_hex(const uint8_t *got, size_t len, const char *want, const char *what) {
    char h[129];
    hex(got, len, h);
    checks++;
    if (strcmp(h, want) != 0) { failures++; printf("FAIL %s\n  got  %s\n  want %s\n", what, h, want); }
}

static void sha(gweb_bytes m, const char *want, const char *what) {
    uint8_t o[32];
    check(gweb_sha256((gweb_wbytes){ o, 32 }, m) == 1, what);
    check_hex(o, 32, want, what);
}

static void hmac(gweb_bytes k, gweb_bytes m, const char *want, size_t n, const char *what) {
    uint8_t o[32];
    check(gweb_hmac_sha256((gweb_wbytes){ o, 32 }, k, m) == 1, what);
    check_hex(o, n, want, what);
}

static void pbkdf2(const char *pw, const char *salt, int64_t c, size_t dk, const char *want, const char *what) {
    uint8_t o[64];
    check(gweb_pbkdf2_sha256((gweb_wbytes){ o, (int64_t)dk }, S(pw), S(salt), c) == 1, what);
    check_hex(o, dk, want, what);
}

int main(void) {
    sha(S(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha empty");
    sha(S("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha abc");
    sha(S("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha 448 bit");
    uint8_t *million = malloc(1000000);
    memset(million, 'a', 1000000);
    sha(B(million, 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "sha million a");
    free(million);

    /* Padding boundaries: the byte at index i is i mod 251. */
    static const struct { int n; const char *h; } edge[] = {
        { 55, "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59" },
        { 56, "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562" },
        { 63, "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488" },
        { 64, "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108" },
        { 65, "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781" },
        { 119, "da18797ed7c3a777f0847f429724a2d8cd5138e6ed2895c3fa1a6d39d18f7ec6" },
        { 120, "f52b23db1fbb6ded89ef42a23ce0c8922c45f25c50b568a93bf1c075420bbb7c" },
        { 128, "471fb943aa23c511f6f72f8d1652d9c880cfa392ad80503120547703e56a2be5" },
    };
    for (size_t i = 0; i < sizeof edge / sizeof edge[0]; i++) {
        uint8_t m[128];
        for (int j = 0; j < edge[i].n; j++) m[j] = (uint8_t)(j % 251);
        sha(B(m, (size_t)edge[i].n), edge[i].h, "sha padding boundary");
    }

    /* RFC 4231 */
    uint8_t k[131], d[150];
    memset(k, 0x0b, 20);
    hmac(B(k, 20), S("Hi There"), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", 32, "rfc4231 1");
    hmac(S("Jefe"), S("what do ya want for nothing?"),
         "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", 32, "rfc4231 2");
    memset(k, 0xaa, 20); memset(d, 0xdd, 50);
    hmac(B(k, 20), B(d, 50), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe", 32, "rfc4231 3");
    for (int i = 0; i < 25; i++) k[i] = (uint8_t)(i + 1);
    memset(d, 0xcd, 50);
    hmac(B(k, 25), B(d, 50), "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b", 32, "rfc4231 4");
    memset(k, 0x0c, 20);
    hmac(B(k, 20), S("Test With Truncation"), "a3b6167473100ee06e0c796c2955552b", 16, "rfc4231 5 (128 bits)");
    memset(k, 0xaa, 131);
    hmac(B(k, 131), S("Test Using Larger Than Block-Size Key - Hash Key First"),
         "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", 32, "rfc4231 6");
    hmac(B(k, 131), S("This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."),
         "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", 32, "rfc4231 7");
    hmac(B(NULL, 0), S("x"), "4cbc96099a6467ce002461f10549b4898265ebe6188b45efacc44293516e62c4", 32, "hmac empty key");

    pbkdf2("password", "salt", 1, 32, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "pbkdf2 c=1");
    pbkdf2("password", "salt", 2, 32, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", "pbkdf2 c=2");
    pbkdf2("password", "salt", 4096, 32, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", "pbkdf2 c=4096");
    pbkdf2("passwd", "salt", 1, 64,
           "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783",
           "pbkdf2 rfc7914 64 bytes");
    pbkdf2("pass", "salt", 3, 40, "f6894ed57d9dd8af049e92fc99c15263cc9b6e4283d0ddd4fe543fd7773e3d642a5877162acf668b",
           "pbkdf2 partial second block");

    /* Refusals */
    uint8_t o[64];
    check(gweb_sha256((gweb_wbytes){ o, 31 }, S("a")) == 0, "sha out 31");
    check(gweb_sha256((gweb_wbytes){ o, 33 }, S("a")) == 0, "sha out 33");
    check(gweb_hmac_sha256((gweb_wbytes){ o, 31 }, S("k"), S("a")) == 0, "hmac out 31");
    check(gweb_hmac_sha256((gweb_wbytes){ o, 0 }, S("k"), S("a")) == 0, "hmac out 0");
    check(gweb_pbkdf2_sha256((gweb_wbytes){ o, 31 }, S("p"), S("s"), 0) == 0, "pbkdf2 iter 0");
    check(gweb_pbkdf2_sha256((gweb_wbytes){ o, 32 }, S("p"), S("s"), -1) == 0, "pbkdf2 iter -1");
    check(gweb_pbkdf2_sha256((gweb_wbytes){ o, 32 }, S("p"), S("s"), 10000001) == 0, "pbkdf2 iter above max");
    check(gweb_pbkdf2_sha256((gweb_wbytes){ o, 0 }, S("p"), S("s"), 1) == 0, "pbkdf2 out 0");
    check(gweb_pbkdf2_sha256((gweb_wbytes){ o, 65 }, S("p"), S("s"), 1) == 0, "pbkdf2 out 65");

    printf("%d of %d\n", checks - failures, checks);
    return failures ? 1 : 0;
}
