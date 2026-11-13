import std;
let LABEL = "Landing page";
let ICON = "layout";
enum Theme { Light, Dark }
struct Props {
    theme: Theme = Theme.Light,
    intro: u8[..300] = "",
}
