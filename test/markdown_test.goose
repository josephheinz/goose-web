// gweb::markdown and markdown_text (DESIGN-ADDENDUM-19): the subset, hostile input, limits and speed.
//   goose build test/markdown_test.goose && test/markdown_test
import gweb from "..";
import gweb.site.markdown;
import net from "../../goose-net";
import std;

var failures = 0;
var checks = 0;

fn check(ok: bool, what: const u8[:]) {
    checks += 1;
    if !ok { failures += 1; print("FAIL ", what); }
}

fn md(src: const u8[:], want: const u8[:]) {
    var out: u8[>..] = [];
    gweb::markdown(out, src);
    checks += 1;
    if out != want { failures += 1; print("FAIL md ", src, "\n  got:  ", out, "\n  want: ", want); }
}

fn has(src: const u8[:], needle: const u8[:], want: bool) {
    var out: u8[>..] = [];
    gweb::markdown(out, src);
    checks += 1;
    if (find(out, needle) >= 0) != want { failures += 1; print("FAIL has ", src, " ", needle, "\n  got: ", out); }
}

fn text(src: const u8[:], max: i64, want: const u8[:]) {
    var out: u8[>..] = [];
    gweb::markdown_text(out, src, max);
    checks += 1;
    if out != want { failures += 1; print("FAIL text ", src, "\n  got:  ", out, "\n  want: ", want); }
}

fn repeat(out: u8[>..]&, s: const u8[:], n: i64) { for i in n { out.append(s); } }

fn main() {
    // Blocks
    md("", "");
    md("\n\n  \n", "");
    md("hello", "<p>hello</p>\n");
    md("a\nb\n\nc", "<p>a\nb</p>\n<p>c</p>\n");
    md("# One\n## Two\n###### Six\n####### Seven", "<h1>One</h1>\n<h2>Two</h2>\n<h6>Six</h6>\n<p>####### Seven</p>\n");
    md("#NoSpace", "<p>#NoSpace</p>\n");
    md("## Closed ##", "<h2>Closed</h2>\n");
    md("# *em* `c`", "<h1><em>em</em> <code>c</code></h1>\n");
    md("---", "<hr>\n");
    md("a\n\n***\n\n___", "<p>a</p>\n<hr>\n<hr>\n");
    md("- - -", "<hr>\n");
    md("> q1\n> q2\n\n> q3", "<blockquote>\n<p>q1\nq2</p>\n</blockquote>\n<blockquote>\n<p>q3</p>\n</blockquote>\n");
    md("> a\nlazy", "<blockquote>\n<p>a\nlazy</p>\n</blockquote>\n");
    md("> > deep", "<blockquote>\n<blockquote>\n<p>deep</p>\n</blockquote>\n</blockquote>\n");
    md("> # h\n> text", "<blockquote>\n<h1>h</h1>\n<p>text</p>\n</blockquote>\n");
    md("```\n<a>\n```", "<pre><code>&lt;a&gt;\n</code></pre>\n");
    md("```js\nlet a = 1;\n\n  indented\n```\nafter", "<pre><code class=\"language-js\">let a = 1;\n\n  indented\n</code></pre>\n<p>after</p>\n");
    md("~~~\nx\n~~~", "<pre><code>x\n</code></pre>\n");
    md("```\nunclosed\n# not a heading", "<pre><code>unclosed\n# not a heading\n</code></pre>\n");
    md("````\n```\nx\n````", "<pre><code>```\nx\n</code></pre>\n");
    md("```c++ extra\nx\n```", "<pre><code class=\"language-c++\">x\n</code></pre>\n");
    md("```\"><script>\nx\n```", "<pre><code>x\n</code></pre>\n");

    // Lists
    md("- a\n- b\n- c", "<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ul>\n");
    md("* a\n+ b", "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n");
    md("1. a\n2. b", "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n");
    md("3) a\n4) b", "<ol start=\"3\">\n<li>a</li>\n<li>b</li>\n</ol>\n");
    md("- a\n  - b\n    - c\n- d", "<ul>\n<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul>\n</li>\n</ul>\n</li>\n<li>d</li>\n</ul>\n");
    md("- a\n\n  b\n- c", "<ul>\n<li>a\n<p>b</p>\n</li>\n<li>c</li>\n</ul>\n");
    md("- a\n  cont\n- b", "<ul>\n<li>a\ncont</li>\n<li>b</li>\n</ul>\n");
    md("text\n- item", "<p>text</p>\n<ul>\n<li>item</li>\n</ul>\n");
    md("para\n2. not a list", "<p>para\n2. not a list</p>\n");
    md("-\n- b", "<ul>\n<li></li>\n<li>b</li>\n</ul>\n");
    md("- > q", "<ul>\n<li><blockquote>\n<p>q</p>\n</blockquote>\n</li>\n</ul>\n");
    md("> - a\n> - b", "<blockquote>\n<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n</blockquote>\n");
    md("- a\n\npara", "<ul>\n<li>a</li>\n</ul>\n<p>para</p>\n");
    md("- ```\n  x\n  ```", "<ul>\n<li><pre><code>x\n</code></pre>\n</li>\n</ul>\n");
    md("-a", "<p>-a</p>\n");
    md("1.a", "<p>1.a</p>\n");

    // Inline
    md("*em* **strong** ***both***", "<p><em>em</em> <strong>strong</strong> <em><strong>both</strong></em></p>\n");
    md("_em_ __strong__", "<p><em>em</em> <strong>strong</strong></p>\n");
    md("snake_case_name", "<p>snake_case_name</p>\n");
    md("2 * 3 * 4", "<p>2 * 3 * 4</p>\n");
    md("**bold *em* bold**", "<p><strong>bold <em>em</em> bold</strong></p>\n");
    md("*unclosed", "<p>*unclosed</p>\n");
    md("a**b", "<p>a**b</p>\n");
    md("`code <b>` and ``a ` b``", "<p><code>code &lt;b&gt;</code> and <code>a ` b</code></p>\n");
    md("`unclosed", "<p>`unclosed</p>\n");
    md("` a `", "<p><code>a</code></p>\n");
    md("\\*not em\\* \\# \\\\ \\a", "<p>*not em* # \\ \\a</p>\n");
    md("line one  \nline two\\\nline three", "<p>line one<br>\nline two<br>\nline three</p>\n");
    md("a & b < c > d \" e '", "<p>a &amp; b &lt; c &gt; d &quot; e &#39;</p>\n");
    md("&copy; &amp;", "<p>&amp;copy; &amp;amp;</p>\n");
    md("[t](/a/b)", "<p><a href=\"/a/b\">t</a></p>\n");
    md("[t](a/b.html \"Title\")", "<p><a href=\"a/b.html\" title=\"Title\">t</a></p>\n");
    md("[t](#frag) [u](?q=1)", "<p><a href=\"#frag\">t</a> <a href=\"?q=1\">u</a></p>\n");
    md("[t](https://e.com/a_(b))", "<p><a href=\"https://e.com/a_(b)\" rel=\"noopener\">t</a></p>\n");
    md("[t](<https://e.com/x y>)", "<p>[t](&lt;https://e.com/x y&gt;)</p>\n");
    md("[t](mailto:a@b.c) [u](HTTP://E.COM)", "<p><a href=\"mailto:a@b.c\" rel=\"noopener\">t</a> <a href=\"HTTP://E.COM\" rel=\"noopener\">u</a></p>\n");
    md("[t](//cdn.example/x)", "<p><a href=\"//cdn.example/x\" rel=\"noopener\">t</a></p>\n");
    md("[*em*](/x)", "<p><a href=\"/x\"><em>em</em></a></p>\n");
    md("*a [b* c](/x)", "<p>*a <a href=\"/x\">b* c</a></p>\n");
    md("[a [b](/x) c](/y)", "<p><a href=\"/y\">a [b](/x) c</a></p>\n");   // no link inside a link
    md("[no close", "<p>[no close</p>\n");
    md("[t] (/x)", "<p>[t] (/x)</p>\n");
    md("![alt text](/img.png \"T\")", "<p><img src=\"/img.png\" alt=\"alt text\" title=\"T\"></p>\n");
    md("[![a](/i.png)](/x)", "<p><a href=\"/x\"><img src=\"/i.png\" alt=\"a\"></a></p>\n");
    md("<https://e.com/a?b=1&c=2>", "<p><a href=\"https://e.com/a?b=1&amp;c=2\" rel=\"noopener\">https://e.com/a?b=1&amp;c=2</a></p>\n");
    md("<b>raw</b>", "<p>&lt;b&gt;raw&lt;/b&gt;</p>\n");

    // Hostile input
    has("[x](javascript:alert(1))", "<a", false);
    has("[x](javascript:alert(1))", "javascript:alert(1))</p>", true);
    has("[x](JaVaScRiPt:alert(1))", "<a", false);
    has("[x](  javascript:alert(1))", "<a", false);
    has("[x](java\tscript:alert(1))", "<a", false);
    has("[x](java&#x09;script:alert(1))", "href=\"java&amp;#x09;", true);   // a relative URL: the & is escaped, so no entity is decoded
    has("[x](&#106;avascript:alert(1))", "href=\"&amp;#106;", true);
    has("[x](data:text/html;base64,PHNjcmlwdD4=)", "<a", false);
    has("[x](vbscript:msgbox(1))", "<a", false);
    has("[x](file:///etc/passwd)", "<a", false);
    has("[x](\\\\evil.example/a)", "<a", false);
    has("[x](:foo)", "<a", false);
    has("![x](javascript:alert(1))", "<img", false);
    has("![x](data:image/svg+xml;base64,AAAA)", "<img", false);
    has("<javascript:alert(1)>", "<a", false);
    has("<script>alert(1)</script>", "<script", false);
    has("<script>alert(1)</script>", "&lt;script&gt;", true);
    has("<img src=x onerror=alert(1)>", "<img", false);
    has("<div onclick=\"x\">", "<div", false);
    has("[a\"onmouseover=\"x](/ok)", "\"onmouseover", false);
    has("[x](/a\"onmouseover=\"y)", "<a href=\"/a&quot;onmouseover=&quot;y\"", true);
    has("[x](/a \"t\" onclick=x)", "<a", false);
    has("[x](/a \"ti\"tle\")", "onclick", false);
    has("![a\"onerror=\"x](/i.png)", "alt=\"a&quot;onerror=&quot;x\"", true);
    has("```\"><script>x</script>\n```", "<script", false);
    has("# <script>x</script>", "<script", false);
    has("*<script>*", "<script", false);
    has("> <script>", "<script", false);
    has("- <script>", "<script", false);

    // Unclosed and malformed constructs
    md("**", "<p>**</p>\n");
    md("[", "<p>[</p>\n");
    md("![", "<p>![</p>\n");
    md("[a](", "<p>[a](</p>\n");
    md("[a](/x", "<p>[a](/x</p>\n");
    md("[a](/x \"t", "<p>[a](/x &quot;t</p>\n");
    md("<", "<p>&lt;</p>\n");
    md("<https://x", "<p>&lt;https://x</p>\n");
    md("\\", "<p>\\</p>\n");
    md("`", "<p>`</p>\n");
    md(">", "<blockquote>\n</blockquote>\n");
    md("```", "<pre><code></code></pre>\n");
    md("-", "<ul>\n<li></li>\n</ul>\n");
    md("> ```\n> x", "<blockquote>\n<pre><code>x\n</code></pre>\n</blockquote>\n");

    // Depth: 8 containers, deeper markers are text.
    {
        var src: u8[>..] = [];
        repeat(src, ">", 8);
        src.append(" x");
        var out: u8[>..] = [];
        gweb::markdown(out, src);
        var opens = 0;
        var p = 0;
        while true {
            let k = find(out[p..], "<blockquote>");
            if k < 0 { break; }
            opens += 1;
            p += k + 1;
        }
        check(opens == 8, "eight quotes open eight blockquotes");
        var deep: u8[>..] = [];
        repeat(deep, "> ", 200);
        deep.append("x");
        var out2: u8[>..] = [];
        gweb::markdown(out2, deep);
        opens = 0;
        p = 0;
        while true {
            let k = find(out2[p..], "<blockquote>");
            if k < 0 { break; }
            opens += 1;
            p += k + 1;
        }
        check(opens == 8, "200 nested quotes stop at 8 blockquotes");
        check(find(out2, "&gt; &gt;") >= 0 && find(out2, "x</p>") >= 0, "the deeper markers are text");
        var closes = 0;
        p = 0;
        while true {
            let k = find(out2[p..], "</blockquote>");
            if k < 0 { break; }
            closes += 1;
            p += k + 1;
        }
        check(closes == 8, "every opened blockquote is closed");

        var lists: u8[>..] = [];
        for i in 50 { repeat(lists, "  ", i); lists.append("- x\n"); }
        var out3: u8[>..] = [];
        gweb::markdown(out3, lists);
        var uls = 0;
        var ule = 0;
        p = 0;
        while true { let k = find(out3[p..], "<ul>"); if k < 0 { break; } uls += 1; p += k + 1; }
        p = 0;
        while true { let k = find(out3[p..], "</ul>"); if k < 0 { break; } ule += 1; p += k + 1; }
        check(uls == ule && uls <= 8, "nested lists are balanced and at most 8 deep");
    }

    // Many unclosed delimiters finish fast and stay balanced.
    {
        var src: u8[>..] = [];
        repeat(src, "*a ", 20000);
        var out: u8[>..] = [];
        let t0 = clock();
        gweb::markdown(out, src);
        check(clock() - t0 < 1.0, "20000 unclosed * run in under a second");
        var src2: u8[>..] = [];
        repeat(src2, "[a](", 15000);
        out.clear();
        let t1 = clock();
        gweb::markdown(out, src2);
        check(clock() - t1 < 1.0, "15000 unclosed links run in under a second");
        var src3: u8[>..] = [];
        for i in 30 { repeat(src3, "`", i + 1); src3.push(' '); }
        repeat(src3, "`a ", 15000);
        out.clear();
        let t2 = clock();
        gweb::markdown(out, src3);
        check(clock() - t2 < 1.0, "unclosed backtick runs run in under a second");
        var src4: u8[>..] = [];
        repeat(src4, "[", 30000);
        out.clear();
        let t3 = clock();
        gweb::markdown(out, src4);
        check(clock() - t3 < 1.0, "30000 [ run in under a second");
        var src5: u8[>..] = [];
        repeat(src5, "[a](/x \"", 5000);
        out.clear();
        let t4 = clock();
        gweb::markdown(out, src5);
        check(clock() - t4 < 1.0, "5000 unclosed titles run in under a second");
        var src6: u8[>..] = [];
        repeat(src6, "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<", 800);
        out.clear();
        let t5 = clock();
        gweb::markdown(out, src6);
        check(clock() - t5 < 1.0, "many < run in under a second");
    }

    // The input is cut at 64 KiB.
    {
        var src: u8[>..] = [];
        repeat(src, "word ", 20000);
        var out: u8[>..] = [];
        gweb::markdown(out, src);
        check(out.len < 70000 && out.len > 60000, "a long input is cut near 64 KiB");
        var u: u8[>..] = [];
        repeat(u, "a", 65535);
        u.append("\xC3\xA9");
        out.clear();
        gweb::markdown(out, u);
        check(find(out, "\xC3") < 0, "the cut does not split a UTF-8 character");
        // The limit is a parameter: a smaller one cuts sooner, a larger one keeps more.
        out.clear();
        gweb::markdown(out, src, 1000);
        check(out.len < 1200 && out.len > 900, "max_input 1000 cuts near 1000 bytes");
        var big: u8[>..] = [];
        repeat(big, "word ", 30000);
        out.clear();
        gweb::markdown(out, big, 200000);
        check(out.len > 150000, "max_input 200000 keeps a 150000-byte input");
        out.clear();
        gweb::markdown_text(out, src, 100000, 100);
        check(out.len <= 110, "markdown_text passes max_input through");
    }

    // Plain text
    text("# Title\n\nSome *emphasis* and a [link](/x).", 100, "Title Some emphasis and a link.");
    text("a\n\n- b\n- c\n\n> d", 100, "a b c d");
    text("`x < y` & <b>", 100, "x < y & <b>");
    text("![alt](/i.png) text", 100, "text");
    text("one two three four five", 12, "one two\xE2\x80\xA6");
    text("abcdefghijklmnopqrstuvwxyz", 10, "abcdefg\xE2\x80\xA6");
    text("short", 10, "short");
    text("", 10, "");
    text("caf\xC3\xA9 caf\xC3\xA9 caf\xC3\xA9", 11, "caf\xC3\xA9\xE2\x80\xA6");

    // Speed: a 20 KB document (E5).
    {
        var doc: u8[>..] = [];
        for i in 80 {
            doc.append("## Section heading\n\nA paragraph with *emphasis*, **strong text**, `code`, and a [link](https://example.com/page) inside it.\nA second line follows here with more words to fill the line out.\n\n- first item\n- second item with `code`\n  - nested item\n\n> a quote with **bold**\n\n");
        }
        check(doc.len > 18000, "the speed document is about 20 KB");
        var out: u8[>..] = [];
        gweb::markdown(out, doc);
        let t0 = clock();
        let rounds = 200;
        for r in rounds {
            out.clear();
            gweb::markdown(out, doc);
        }
        let per = (clock() - t0) * 1000.0 / rounds;
        print("markdown: ", doc.len, " bytes in ", per, " ms per render");
        check(per < 20.0, "20 KB renders in under 20 ms");
    }

    print("markdown_test: ", checks - failures, " of ", checks, " checks passed");
    exit(if failures == 0 { 0 } else { 1 });
}
