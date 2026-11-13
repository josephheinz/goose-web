import std;
import gweb;
import cms.media;

let LABEL = "Image";
let ICON = "image";
let UI = [gweb::FieldUi { field: "media", label: "File" }];

struct Props { media: cms::Media = cms::Media { .. }, alt: u8[..100] = "" }
