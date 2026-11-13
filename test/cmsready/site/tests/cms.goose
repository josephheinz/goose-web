import std;
import net.http;
import gweb;
import gweb.testing;
import cms.store;
import views;

fn reserved(name: const u8[:]) -> bool {
    for r in gweb::reserved_prefixes() { if r == name { return true; } }
    return false;
}

// Views from the git-sourced package and from the host land in one registry.
fn test_registry_has_package_and_host_views(t: gweb::Tester&) {
    gweb::expect(t, views::types_index("Article") >= 0, "the package's page type Article");
    gweb::expect(t, views::sections_index("TwoColumn") >= 0, "the package's section TwoColumn");
    gweb::expect(t, views::widgets_index("Text") >= 0, "the package's widget Text");
    gweb::expect(t, views::widgets_index("Quote") >= 0, "the host's widget Quote");
    gweb::expect(t, views::layouts_index("Site") >= 0, "the host's layout Site");
    gweb::expect(t, views::widgets_count() == 3 && views::layouts_count() == 2, "three widgets and two layouts in all: the host's and the package's in one group");
    gweb::expect(t, views::layouts_index("Plain") >= 0, "the package's layout Plain");
    let a = views::types_meta(views::types_index("Article"));
    gweb::expect(t, a.slots.len == 1 && a.slots[0].name == "main" && a.slots[0].allow == "TwoColumn Text Quote Image", "the slot zone of Article, from its template");
    let tc = views::sections_meta(views::sections_index("TwoColumn"));
    gweb::expect(t, tc.slots.len == 2 && tc.slots[0].name == "left" && tc.slots[1].name == "right", "the zones of TwoColumn");
}

// The mount, the media route and the generated files are all reserved.
fn test_reserved_prefixes_see_the_mount(t: gweb::Tester&) {
    gweb::expect(t, reserved("admin"), "admin (the package mount)");
    gweb::expect(t, reserved("media"), "media (a route of the host)");
    gweb::expect(t, reserved("sitemap.xml") && reserved("robots.txt"), "the generated sitemap and robots");
    gweb::expect(t, reserved("_gw"), "_gw (the runtime)");
    gweb::expect(t, reserved("__gweb"), "__gweb (health, ready and metrics)");
    gweb::expect(t, !reserved("news"), "a plain slug is free");
}

fn test_slug_rules(t: gweb::Tester&) {
    gweb::expect(t, cms::slug_ok("/") && cms::slug_ok("/news") && cms::slug_ok("/news/2026-launch"), "plain slugs");
    gweb::expect(t, !cms::slug_ok("/admin") && !cms::slug_ok("/admin/shop") && !cms::slug_ok("/media/x") && !cms::slug_ok("/_gw") && !cms::slug_ok("/__gweb/id"), "slugs under a reserved prefix");
    gweb::expect(t, !cms::slug_ok("") && !cms::slug_ok("news") && !cms::slug_ok("/news/") && !cms::slug_ok("/a//b") && !cms::slug_ok("/A") && !cms::slug_ok("/a b"), "malformed slugs");
}

// A field of a type that the package's lib defines (cms::Media): its own JSON, form control and parser.
fn test_foreign_field_from_the_package_lib(t: gweb::Tester&) {
    var errs = gweb::no_errors();
    var form: u8[>..] = [];
    gweb::expect(t, views::widgets_form(form, "Image", "{\"media\":{\"key\":\"m7\",\"name\":\"a<b.png\"},\"alt\":\"x\"}", errs, "w."), "the form of Image");
    gweb::expect(t, find(form, "<p class=\"gw-field media-picker\"><label for=\"w.media.key\">File</label> <input id=\"w.media.key\" name=\"w.media.key\" value=\"m7\"> <input name=\"w.media.name\" value=\"a&lt;b.png\"></p>") >= 0, "is drawn by cms::gw_field");
    var raw: u8[>..] = [];
    let body = "w.media.key=m9&w.media.name=z.png&w.alt=Hi%20there";
    format(raw, "POST /f HTTP/1.1\r\nHost: a\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ", body.len, "\r\n\r\n", body);
    let req, parsed = http::parse_request(raw);
    var out: u8[>..] = [];
    gweb::expect(t, views::widgets_parse(req, "Image", "w.", out, errs), "the form parses");
    gweb::expect(t, out == "{\"media\":{\"key\":\"m9\",\"name\":\"z.png\"},\"alt\":\"Hi there\"}", "through cms::gw_parse and gw_write");
}
