import std;
import gweb;
let UI = [gweb::FieldUi { field: "body", label: "Body text", help: "Markdown.", editor: "markdown" }];
struct Props { body: u8[..2000] = "" }
