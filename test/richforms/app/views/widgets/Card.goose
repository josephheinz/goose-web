import std;
import gweb;

let ITEM_LABEL = "label";
let UI = [gweb::FieldUi { field: "title", label: "Title", help: "Up to 30 bytes." }];

struct Row { label: u8[..20] = "", n: i64 = 0 }

struct Props {
    title: u8[..30],
    count: i64 = 3,
    on: bool = false,
    rows: Row[..3],
}
