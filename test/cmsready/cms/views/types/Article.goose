import std;
import gweb;
import gweb.forms.valid;

let LABEL = "Article";
let ICON = "file";
let UI = [gweb::FieldUi { field: "intro", label: "Introduction", help: "Shown under the title." }];

enum Theme { Light, Dark }
struct Props {
    title: u8[..80],
    theme: Theme = Theme.Light,
    intro: u8[..300] = "",
}

fn validate(p: const Props&, errs: gweb::FieldErrors&) {
    gweb::check_length(errs, "title", p.title, 2, 80);
}
