import std;
import gweb;
import gweb.forms.valid;
import lib.link;

let LABEL = "Hero banner";
let ICON = "image";
let UI = [gweb::FieldUi { field: "title", label: "Headline", help: "Up to 60 characters." },
          gweb::FieldUi { field: "badge.text", label: "Badge text" },
          gweb::FieldUi { field: "more", label: "More link" }];
let RENAMED = [gweb::Renamed { from: "heading", to: "title" }, gweb::Renamed { from: "head", to: "title" }];

enum Align { Left, Center, Right }
struct Badge { text: u8[..20] = "", level: i64 = 0 }
struct Cta { label: u8[..30] = "", url: u8[..200] = "/", primary: bool = false, align: Align = Align.Left }

struct Props {
    title: u8[..60],
    count: i64 = 3,
    shout: bool = false,
    badge: Badge = Badge { .. },
    more: link::Link = link::Link { .. },
    ctas: Cta[>..<],
}

fn validate(p: const Props&, errs: gweb::FieldErrors&) {
    gweb::check_length(errs, "title", p.title, 2, 60);
}
