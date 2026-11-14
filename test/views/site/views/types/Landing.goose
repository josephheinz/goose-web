import std;
import gweb;
let LABEL = "Landing page";
let ICON = "layout";
enum Theme { Light, Dark }
let ENUM_LABELS = [gweb::EnumLabel { ty: "Theme", variant: "Dark", label: "Dark & calm" }];
struct Props {
    theme: Theme = Theme.Light,
    intro: u8[..300] = "",
}
