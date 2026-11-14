import std;
import gweb;
enum Gap { Narrow, Wide }
let ENUM_LABELS = [gweb::EnumLabel { ty: "Gap", variant: "Wide", label: "Wide gap" }];
let UI = [gweb::FieldUi { field: "gap", editor: "radio" }];
struct Props { gap: Gap = Gap.Narrow, reverse: bool = false }
