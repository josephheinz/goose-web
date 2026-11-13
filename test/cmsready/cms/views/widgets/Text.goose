import std;
import gweb;

let LABEL = "Text";
let UI = [gweb::FieldUi { field: "body", label: "Body", help: "Markdown.", editor: "markdown" }];
struct Props { body: u8[..600] = "" }
