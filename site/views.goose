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
fn vm_field(m: ViewMeta&, name: const u8[:], label: const u8[:], help: const u8[:], editor: const u8[:],
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

fn vm_slot(m: ViewMeta&, name: const u8[:], allow: const u8[:]) {
    var s = SlotMeta { .. };
    s.name.append(name);
    s.allow.append(allow);
    if m.slots.len < m.slots.cap { m.slots.push(s); }
}

// True when the allow list is empty or names the view.
fn slot_allows(s: const SlotMeta&, view: const u8[:]) -> bool {
    if s.allow.len == 0 { return true; }
    for n in ::split(s.allow, ' ') { if n == view { return true; } }
    return false;
}

// ---------------------------------------------------------------- reading stored JSON (lenient)
// Each reader consumes one value. A value of the wrong type is skipped and counted in warn; the field keeps its default.

fn jr_text<T>(r: json::Reader&, dst: T&, warn: i64&) {
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
fn jr_int(r: json::Reader&, dst: i64&, warn: i64&) {
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

fn jr_bool(r: json::Reader&, dst: bool&, warn: i64&) {
    let c = json::peek(r);
    if c != 't' && c != 'f' { json::skip(r); warn += 1; return; }
    dst = json::read_bool(r);
}

// The index of the variant named by the string at the cursor, or -1 (the field keeps its default).
fn jr_enum(r: json::Reader&, names: const u8[:][:], warn: i64&) -> i64 {
    var s: u8[..64] = "";
    var w = 0;
    jr_text(r, s, w);
    warn += w;
    if w > 0 { return -1; }
    for n, i in names { if n == s { return i; } }
    warn += 1;
    return -1;
}

// ---------------------------------------------------------------- form controls (the admin forms)

fn vname(out: u8[>..]&, prefix: const u8[:], a: const u8[:]) { out.append(prefix); out.append(a); }

fn vf_label(out: u8[>..]&, id: const u8[:], label: const u8[:]) {
    out.append("<label for=\""); escape(out, id); out.append("\">"); escape(out, label); out.append("</label> ");
}

fn vf_tail(out: u8[>..]&, id: const u8[:], help: const u8[:], errs: const FieldErrors&) {
    if help.len > 0 { out.append(" <small class=\"gw-help\">"); escape(out, help); out.append("</small>"); }
    field_error(out, errs, id);
    out.append("</p>\n");
}

fn vf_text(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:], editor: const u8[:],
           cap: i64, value: const u8[:], errs: const FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    out.append("<p class=\"gw-field\">");
    vf_label(out, id, label);
    let area = editor == "textarea" || editor == "markdown" || (editor.len == 0 && cap > 200);
    if area {
        out.append("<textarea id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.push('"');
    } else {
        out.append("<input type=\"");
        escape(out, if editor.len > 0 { editor } else { "text" });
        out.append("\" id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.append("\" value=\""); escape(out, value); out.push('"');
    }
    out.append(" maxlength=\""); format(out, cap); out.push('"');
    if required { out.append(" required"); }
    if editor.len > 0 { out.append(" data-editor=\""); escape(out, editor); out.push('"'); }
    invalid(out, errs, id);
    if area { out.push('>'); escape(out, value); out.append("</textarea>"); } else { out.push('>'); }
    vf_tail(out, id, help, errs);
}

fn vf_int(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:], editor: const u8[:],
          value: i64, errs: const FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    out.append("<p class=\"gw-field\">");
    vf_label(out, id, label);
    out.append("<input type=\"");
    escape(out, if editor.len > 0 { editor } else { "number" });
    out.append("\" id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.append("\" value=\""); format(out, value); out.push('"');
    if required { out.append(" required"); }
    invalid(out, errs, id);
    out.push('>');
    vf_tail(out, id, help, errs);
}

fn vf_bool(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:], value: bool,
           errs: const FieldErrors&) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    out.append("<p class=\"gw-field\"><input type=\"checkbox\" id=\""); escape(out, id); out.append("\" name=\""); escape(out, id);
    out.append(if value { "\" checked>" } else { "\">" });
    out.push(' ');
    vf_label(out, id, label);
    vf_tail(out, id, help, errs);
}

fn vf_enum(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], help: const u8[:],
           names: const u8[:][:], current: const u8[:], errs: const FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    out.append("<p class=\"gw-field\">");
    vf_label(out, id, label);
    out.append("<select id=\""); escape(out, id); out.append("\" name=\""); escape(out, id); out.push('"');
    if required { out.append(" required"); }
    invalid(out, errs, id);
    out.push('>');
    for n in names {
        out.append("<option");
        if n == current { out.append(" selected"); }
        out.push('>'); escape(out, n); out.append("</option>");
    }
    out.append("</select>");
    vf_tail(out, id, help, errs);
}

fn vf_group_open(out: u8[>..]&, label: const u8[:]) {
    out.append("<fieldset class=\"gw-group\"><legend>"); escape(out, label); out.append("</legend>\n");
}
fn vf_group_close(out: u8[>..]&) { out.append("</fieldset>\n"); }

fn vf_list_open(out: u8[>..]&, prefix: const u8[:], field: const u8[:], label: const u8[:], count: i64) {
    out.append("<fieldset class=\"gw-list\"><legend>"); escape(out, label); out.append("</legend>\n");
    out.append("<input type=\"hidden\" name=\""); escape(out, prefix); escape(out, field); out.append(".n\" value=\""); format(out, count); out.append("\">\n");
}
fn vf_list_close(out: u8[>..]&) { out.append("</fieldset>\n"); }
fn vf_item_open(out: u8[>..]&, k: i64) { out.append("<fieldset class=\"gw-item\"><legend>#"); format(out, k + 1); out.append("</legend>\n"); }
fn vf_item_close(out: u8[>..]&) { out.append("</fieldset>\n"); }

// ---------------------------------------------------------------- parsing a posted form (the admin forms)
// The field names are prefix + field; a nested struct adds "name.", a repeater item "name.K.".

fn vp_text<T>(req: const http::Request&, prefix: const u8[:], field: const u8[:], dst: T&, errs: FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    form_text(req, id, dst, errs, required);
}

fn vp_int(req: const http::Request&, prefix: const u8[:], field: const u8[:], dst: i64&, errs: FieldErrors&, required: bool) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    form_i64(req, id, dst, errs, required);
}

fn vp_bool(req: const http::Request&, prefix: const u8[:], field: const u8[:], dst: bool&) {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    form_bool(req, id, dst);
}

fn vp_enum(req: const http::Request&, prefix: const u8[:], field: const u8[:], names: const u8[:][:], errs: FieldErrors&, required: bool) -> i64 {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    return form_enum(req, id, names, errs, required);
}

// The posted item count of a repeater, at most cap; 0 when absent.
fn vp_count(req: const http::Request&, prefix: const u8[:], field: const u8[:], cap: i64, errs: FieldErrors&) -> i64 {
    var id: u8[>..] = [];
    vname(id, prefix, field);
    id.append(".n");
    var n: i64 = 0;
    if !form_i64(req, id, n, errs, false) { return 0; }
    if n < 0 { n = 0; }
    if n > cap { add_error(errs, id, "Too many items."); return cap; }
    return n;
}
