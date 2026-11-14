// Part of gweb. Import with `import gweb.site.views;`.
//
// The runtime half of views (DESIGN-ADDENDUM-19): metadata types, the lenient JSON readers and the form controls
// that the generated code of views/<group>/<Name>.goose calls. The generated `views` module is the registry.

namespace gweb;

import std;
import net;
import net.http;
import json;
import gweb;
import forms.form;
import forms.valid;
import site.template;

// ---------------------------------------------------------------- what a view's Goose file may declare

// let UI = [gweb::FieldUi { field: "body", label: "Text", help: "Markdown.", editor: "markdown" }];
// field names a field of Props, or "group.field" for a field inside a nested struct.
struct FieldUi { field: const u8[:], label: const u8[:] = "", help: const u8[:] = "", editor: const u8[:] = "" }

// let RENAMED = [gweb::Renamed { from: "heading", to: "title" }]; a stored key `from` is read as field `to`.
struct Renamed { from: const u8[:], to: const u8[:] }

// let ENUM_LABELS = [gweb::EnumLabel { ty: "Gap", variant: "Wide", label: "Wide gap" }]; the form shows label for the
// variant (1.2). A variant with no label shows its name. The stored JSON keeps the variant name.
struct EnumLabel { ty: const u8[:], variant: const u8[:], label: const u8[:] }

// ---------------------------------------------------------------- metadata (flat, so it can cross threads)

let VIEW_MAX_FIELDS = 32;
let VIEW_MAX_SLOTS = 8;
let VIEW_MAX_REPEAT = 64;

enum FieldKind { Text, Int, Bool, Enum, Group, List, Foreign }

// ty: the enum, struct or foreign type name. cap: bytes of a Text, items of a List. required: no default.
struct FieldMeta { name: u8[..64] = "", label: u8[..64] = "", help: u8[..200] = "", editor: u8[..32] = "",
                   kind: FieldKind = FieldKind.Text, ty: u8[..64] = "", cap: i64 = 0, required: bool = false }
struct SlotMeta { name: u8[..32] = "", allow: u8[..200] = "" }   // allow: space-separated view names; "" means all
struct ViewMeta { name: u8[..64] = "", group: u8[..32] = "", label: u8[..64] = "", icon: u8[..32] = "",
                  fields: FieldMeta[..32] = [], slots: SlotMeta[..8] = [] }

// Used by the generated registry.
fn _vm_field(m: ViewMeta&, name: const u8[:], label: const u8[:], help: const u8[:], editor: const u8[:],
            kind: FieldKind, ty: const u8[:], cap: i64, required: bool) {
    var f = FieldMeta { .. };
    f.name.append(name);
    f.label.append(label);
    f.help.append(help);
    f.editor.append(editor);
    f.kind = kind;
    f.ty.append(ty);
    f.cap = cap;
    f.required = required;
    if m.fields.len < m.fields.cap { m.fields.push(f); }
}

fn _vm_slot(m: ViewMeta&, name: const u8[:], allow: const u8[:]) {
    var s = SlotMeta { .. };
    s.name.append(name);
    s.allow.append(allow);
    if m.slots.len < m.slots.cap { m.slots.push(s); }
}

// True when the allow list is empty or names the view.
fn _slot_allows(s: const SlotMeta&, view: const u8[:]) -> bool {
    if s.allow.len == 0 { return true; }
    for n in ::split(s.allow, ' ') { if n == view { return true; } }
    return false;
}

// ---------------------------------------------------------------- reading stored JSON (lenient)
// Each reader consumes one value. A value of the wrong type is skipped and counted in warn; the field keeps its default.

fn _jr_text<T>(r: json::Reader&, dst: T&, warn: i64&) {
    if json::peek(r) != '"' { json::skip(r); warn += 1; return; }
    var scratch: u8[>..] = [];
    let s = json::read_string(r, scratch);
    var n = s.len;
    if n > dst.cap {
        warn += 1;
        n = dst.cap;
        while n > 0 && (s[n] & 0xC0) == 0x80 { n -= 1; }
    }
    dst.clear();
    dst.append(s[..n]);
}

// An integer token of at most 18 digits; a fraction, an exponent or a longer number is skipped.
fn _jr_int(r: json::Reader&, dst: i64&, warn: i64&) {
    let c = json::peek(r);
    if c != '-' && (c < '0' || c > '9') { json::skip(r); warn += 1; return; }
    var p = r.pos;
    while p < r.text.len && (r.text[p] == ' ' || r.text[p] == '\n' || r.text[p] == '\t' || r.text[p] == '\r') { p += 1; }
    var e = p;
    if e < r.text.len && r.text[e] == '-' { e += 1; }
    let digits_from = e;
    while e < r.text.len && r.text[e] >= '0' && r.text[e] <= '9' { e += 1; }
    let stop = if e < r.text.len { r.text[e] } else { 0 };
    if e - digits_from > 18 || e == digits_from || stop == '.' || stop == 'e' || stop == 'E' { json::skip(r); warn += 1; return; }
    dst = json::read_int(r);
}

fn _jr_bool(r: json::Reader&, dst: bool&, warn: i64&) {
    let c = json::peek(r);
    if c != 't' && c != 'f' { json::skip(r); warn += 1; return; }
    dst = json::read_bool(r);
}

// The index of the variant named by the string at the cursor, or -1 (the field keeps its default).
fn _jr_enum(r: json::Reader&, names: const u8[:][:], warn: i64&) -> i64 {
    var s: u8[..64] = "";
    var w = 0;
    _jr_text(r, s, w);
    warn += w;
    if w > 0 { return -1; }
    for n, i in names { if n == s { return i; } }
    warn += 1;
    return -1;
}

// ---------------------------------------------------------------- form controls (the admin forms)

fn _vname(out: u8[>..]&, prefix: const u8[:], a: const u8[:]) { out.append(prefix); out.append(a); }

fn _vf_label(out: u8[>..]&, id: const u8[:], label: const u8[:]) {
    out.append("<label for=\""); escape(out, id); out.append("\">"); escape(out, label); out.append("</label> ");
}

// The forms come in two modes. Plain (g_form, form): the 1.0 markup. Rich (g_form_req, form_req): the posted text of a
// field that failed, help text linked to its control, and item buttons in a repeater. rich is false in plain mode,
// and req is then an empty request.

// The text a control shows: what was posted when a rich form is drawn after a failed POST and the field has an error
// (so "12a" is not replaced by the default), else the stored value, as text.
fn _vf_shown(out: u8[>..]&, req: const http::Request&, id: const u8[:], errs: const FieldErrors&, rich: bool, value: const u8[:]) {
    if rich && req.method == http::Method.Post && has_error(errs, id) {
        var v: u8[>..] = [];
        if form(req, id, v) { out.append(v); return; }
    }
    out.append(value);
}

// What goes in a control's start tag: aria-invalid and aria-describedby. Rich mode lists the help id and the error id.
fn _vf_desc(out: u8[>..]&, id: const u8[:], help: const u8[:], errs: const FieldErrors&, rich: bool) {
    if !rich { invalid(out, errs, id); return; }
    let bad = has_error(errs, id);
    if bad { out.append(" aria-invalid=\"true\""); }
    if help.len == 0 && !bad { return; }
    out.append(" aria-describedby=\"");
    if help.len > 0 { escape(out, id); out.append("-help"); }
    if help.len > 0 && bad { out.push(' '); }
    if bad { escape(out, id); out.append("-error"); }
    out.push('"');
}

fn _vf_tail(out: u8[>..]&, id: const u8[:], help: const u8[:], errs: const FieldErrors&, rich: bool) {
    if help.len > 0 {
        out.append(" <small class=\"gw-help\"");
        if rich { out.append(" id=\""); escape(out, id); out.append("-help\""); }
        out.push('>'); escape(out, help); out.append("</small>");
    }
    field_error(out, errs, id);
    out.append("</p>\n");
}

fn _vf_text(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:], editor: const u8[:],
           cap: i64, value: const u8[:], errs: const FieldErrors&, required: bool, req: const http::Request&, rich: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    var shown: u8[>..] = [];
    _vf_shown(shown, req, id, errs, rich, value);
    out.append("<p class=\"gw-field\">");
    _vf_label(out, id, label);
    let area = editor == "textarea" || editor == "markdown" || (editor.len == 0 && cap > 200);
    if area {
        out.append("<textarea id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.push('"');
    } else {
        out.append("<input type=\"");
        escape(out, if editor.len > 0 { editor } else { "text" });
        out.append("\" id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.append("\" value=\""); escape(out, shown); out.push('"');
    }
    out.append(" maxlength=\""); format(out, cap); out.push('"');
    if required { out.append(" required"); }
    if editor.len > 0 { out.append(" data-editor=\""); escape(out, editor); out.push('"'); }
    _vf_desc(out, id, help, errs, rich);
    if area { out.push('>'); escape(out, shown); out.append("</textarea>"); } else { out.push('>'); }
    _vf_tail(out, id, help, errs, rich);
}

fn _vf_int(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:], editor: const u8[:],
          value: i64, errs: const FieldErrors&, required: bool, req: const http::Request&, rich: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    var text: u8[>..] = [];
    format(text, value);
    var shown: u8[>..] = [];
    _vf_shown(shown, req, id, errs, rich, text);
    out.append("<p class=\"gw-field\">");
    _vf_label(out, id, label);
    out.append("<input type=\"");
    escape(out, if editor.len > 0 { editor } else { "number" });
    out.append("\" id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.append("\" value=\""); escape(out, shown); out.push('"');
    if required { out.append(" required"); }
    _vf_desc(out, id, help, errs, rich);
    out.push('>');
    _vf_tail(out, id, help, errs, rich);
}

fn _vf_bool(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:], value: bool,
           errs: const FieldErrors&, rich: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    out.append("<p class=\"gw-field\"><input type=\"checkbox\" id=\""); escape(out, id); out.append("\" name=\""); escape(out, id);
    out.push('"');
    if rich { _vf_desc(out, id, help, errs, rich); }
    out.append(if value { " checked>" } else { ">" });
    out.push(' ');
    _vf_label(out, id, label);
    _vf_tail(out, id, help, errs, rich);
}

fn _vf_enum(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:],
           names: const u8[:][:], current: const u8[:], errs: const FieldErrors&, required: bool, rich: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    out.append("<p class=\"gw-field\">");
    _vf_label(out, id, label);
    out.append("<select id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.push('"');
    if required { out.append(" required"); }
    _vf_desc(out, id, help, errs, rich);
    out.push('>');
    for n in names {
        out.append("<option");
        if n == current { out.append(" selected"); }
        out.push('>'); escape(out, n); out.append("</option>");
    }
    out.append("</select>");
    _vf_tail(out, id, help, errs, rich);
}

// An enum field with ENUM_LABELS or editor: "radio" (1.2). names and labels are lines; the Kth label is shown for the
// Kth name, and the value sent is the name.
struct _EnumUi { field: const u8[:], label: const u8[:], help: const u8[:], radio: bool, required: bool,
                 names: const u8[:], labels: const u8[:] }

fn _vf_choice(out: u8[>..]&, prefix: const u8[:], ui: const _EnumUi&, current: const u8[:], errs: const FieldErrors&, rich: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, ui.field);
    let labels = ::split(ui.labels, '\n');
    if !ui.radio {
        out.append("<p class=\"gw-field\">");
        _vf_label(out, id, ui.label);
        out.append("<select id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.push('"');
        if ui.required { out.append(" required"); }
        _vf_desc(out, id, ui.help, errs, rich);
        out.push('>');
        for n, i in ::split(ui.names, '\n') {
            out.append("<option value=\""); escape(out, n); out.push('"');
            if n == current { out.append(" selected"); }
            out.push('>'); escape(out, if i < labels.len { labels[i] } else { n }); out.append("</option>");
        }
        out.append("</select>");
        _vf_tail(out, id, ui.help, errs, rich);
        return;
    }
    // A radio group: a fieldset whose legend is the label; help and error follow the radios.
    out.append("<fieldset class=\"gw-field gw-radio\" id=\""); escape(out, id); out.append("\"><legend>"); escape(out, ui.label); out.append("</legend>");
    for n, i in ::split(ui.names, '\n') {
        out.append("<label><input type=\"radio\" name=\""); escape(out, id); out.append("\" value=\""); escape(out, n); out.push('"');
        if n == current { out.append(" checked"); }
        if ui.required { out.append(" required"); }
        _vf_desc(out, id, ui.help, errs, rich);
        out.append("> "); escape(out, if i < labels.len { labels[i] } else { n }); out.append("</label> ");
    }
    if ui.help.len > 0 {
        out.append("<small class=\"gw-help\"");
        if rich { out.append(" id=\""); escape(out, id); out.append("-help\""); }
        out.push('>'); escape(out, ui.help); out.append("</small>");
    }
    field_error(out, errs, id);
    out.append("</fieldset>\n");
}

fn _vf_group_open(out: u8[>..]&, label: const u8[:]) {
    out.append("<fieldset class=\"gw-group\"><legend>"); escape(out, label); out.append("</legend>\n");
}
fn _vf_group_close(out: u8[>..]&) { out.append("</fieldset>\n"); }

// A repeater. Rich mode starts with a hidden default button, so Enter in a text field redraws the form as a plain Save
// and does not press the first item's button; each item ends with Up, Down and Remove, and the list with Add. They are
// submit buttons named PREFIX+FIELD+".act", with the value add, up:K, down:K or del:K. g_parse applies one.
fn _vf_act_button(out: u8[>..]&, prefix: const u8[:], field: const u8[:], value: const u8[:], k: i64, text: const u8[:], off: bool, what: const u8[:]) {
    out.append("<button type=\"submit\" name=\""); escape(out, prefix); escape(out, field); out.append(".act\" value=\""); out.append(value);
    if k >= 0 { out.push(':'); format(out, k); }
    out.push('"');
    if off { out.append(" disabled"); }
    out.append(" aria-label=\""); out.append(what);
    if k >= 0 { out.push(' '); format(out, k + 1); }
    out.append("\">"); out.append(text); out.append("</button>");
}

fn _vf_list_open(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], count: i64, rich: bool) {
    out.append("<fieldset class=\"gw-list\"><legend>"); escape(out, label); out.append("</legend>\n");
    out.append("<input type=\"hidden\" name=\""); escape(out, prefix); escape(out, field); out.append(".n\" value=\""); format(out, count); out.append("\">\n");
    if rich {
        out.append("<button type=\"submit\" name=\""); escape(out, prefix); escape(out, field); out.append(".act\" value=\"\" hidden tabindex=\"-1\"></button>\n");
    }
}
fn _vf_list_close(out: u8[>..]&, prefix: const u8[:], field: const u8[:], count: i64, cap: i64, rich: bool) {
    if rich {
        out.append("<p class=\"gw-list-actions\">");
        _vf_act_button(out, prefix, field, "add", -1, "Add", count >= cap, "Add an item");
        out.append("</p>\n");
    }
    out.append("</fieldset>\n");
}
// label is the item's ITEM_LABEL field, "" when the view has none; it is shown in rich mode.
fn _vf_item_open(out: u8[>..]&, k: i64, label: const u8[:], rich: bool) {
    out.append("<fieldset class=\"gw-item\"><legend>#"); format(out, k + 1);
    if rich && label.len > 0 { out.append(": "); escape(out, label); }
    out.append("</legend>\n");
}
fn _vf_item_close(out: u8[>..]&, prefix: const u8[:], field: const u8[:], k: i64, count: i64, rich: bool) {
    if rich {
        out.append("<p class=\"gw-item-actions\">");
        _vf_act_button(out, prefix, field, "up", k, "Up", k == 0, "Move up item");
        out.push(' ');
        _vf_act_button(out, prefix, field, "down", k, "Down", k + 1 >= count, "Move down item");
        out.push(' ');
        _vf_act_button(out, prefix, field, "del", k, "Remove", false, "Remove item");
        out.append("</p>\n");
    }
    out.append("</fieldset>\n");
}

// ---------------------------------------------------------------- parsing a posted form (the admin forms)
// The field names are prefix + field; a nested struct adds "name.", a repeater item "name.K.".

fn _vp_text<T>(req: const http::Request&, prefix: const u8[:], field: const u8[:], dst: T&, errs: FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    form_text(req, id, dst, errs, required);
}

fn _vp_int(req: const http::Request&, prefix: const u8[:], field: const u8[:], dst: i64&, errs: FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    form_i64(req, id, dst, errs, required);
}

fn _vp_bool(req: const http::Request&, prefix: const u8[:], field: const u8[:], dst: bool&) {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    form_bool(req, id, dst);
}

fn _vp_enum(req: const http::Request&, prefix: const u8[:], field: const u8[:], names: const u8[:][:], errs: FieldErrors&, required: bool) -> i64 {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    return form_enum(req, id, names, errs, required);
}

// The posted item count of a repeater, at most cap; 0 when absent.
fn _vp_count(req: const http::Request&, prefix: const u8[:], field: const u8[:], cap: i64, errs: FieldErrors&) -> i64 {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    id.append(".n");
    var n: i64 = 0;
    if !form_i64(req, id, n, errs, false) { return 0; }
    if n < 0 { n = 0; }
    if n > cap { add_error(errs, id, "Too many items."); return cap; }
    return n;
}

// The repeater action in a posted form: kind 1 add, 2 del, 3 up, 4 down (with the item index k), 0 for none.
fn _vp_act(req: const http::Request&, prefix: const u8[:], field: const u8[:]) -> i64, i64 {
    var id: u8[>..] = [];
    _vname(id, prefix, field);
    id.append(".act");
    var v: u8[>..] = [];
    if !form(req, id, v) { return 0, 0; }
    let t = trim(v);
    if t == "add" { return 1, 0; }
    var kind = 0;
    if starts_with(t, "del:") { kind = 2; }
    else if starts_with(t, "up:") { kind = 3; }
    else if starts_with(t, "down:") { kind = 4; }
    if kind == 0 { return 0, 0; }
    let n, ok = parse_int(t[find(t, ":") + 1..]);
    if !ok || n < 0 { return 0, 0; }
    return kind, n;
}
