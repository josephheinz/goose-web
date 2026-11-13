// Part of gweb. Import with `import gweb.forms.valid;`.

namespace gweb;

import std;
import net;
import net.http;
import json;
import gweb;
import forms.form;
import site.template;

// ---------------------------------------------------------------- errors

struct FieldError { field: u8[..64], message: u8[..200] }
const MAX_FIELD_ERRORS = 64;
// The first error per field is kept. The last slot is held for the form-level "too many errors" message.
struct FieldErrors { n: i64, items: FieldError[64], dropped: bool }

fn no_errors() -> FieldErrors {
    FieldErrors { n: 0, items: [FieldError { field: "", message: "" }; 64], dropped: false }
}

fn has_errors(errs: const FieldErrors&) -> bool { return errs.n > 0; }

// "" for none; field "" is the form-level message.
fn error_for(errs: const FieldErrors&, field: const u8[:]) -> const u8[:] {
    for i in errs.n {
        if errs.items[i].field == field { return errs.items[i].message; }
    }
    return "";
}

fn has_error(errs: const FieldErrors&, field: const u8[:]) -> bool {
    for i in errs.n {
        if errs.items[i].field == field { return true; }
    }
    return false;
}

// False, with nothing added, when the field already has an error or the list is full. With 63 field errors held the
// next one sets dropped and adds a form-level error (field "") in the last slot, so a form shows that some are missing.
// A field name is cut at 64 bytes and a message at 200.
fn add_error(errs: FieldErrors&, field: const u8[:], message: const u8[:]) -> bool {
    let f = field[..min(field.len, 64)];
    if has_error(errs, f) { return false; }
    if errs.n >= MAX_FIELD_ERRORS - 1 {
        if !errs.dropped {
            errs.dropped = true;
            if !has_error(errs, "") {
                let i = errs.n;
                errs.items[i].field.clear();
                errs.items[i].message.clear();
                errs.items[i].message.append("Too many errors to show here. Fix these and submit again.");
                errs.n += 1;
            }
        }
        return false;
    }
    let i = errs.n;
    errs.items[i].field.clear();
    errs.items[i].field.append(f);
    errs.items[i].message.clear();
    errs.items[i].message.append(message[..min(message.len, 200)]);
    errs.n += 1;
    return true;
}

// Each check does nothing and returns false when the field already has an error; true when v passes.

fn check_length(errs: FieldErrors&, field: const u8[:], v: const u8[:], min: i64, max: i64) -> bool {
    if has_error(errs, field) { return false; }
    if v.len < min {
        var m: u8[..64] = "";
        format(m, "Use at least ", min, " characters.");
        add_error(errs, field, m);
        return false;
    }
    if v.len > max {
        var m: u8[..64] = "";
        format(m, "Use at most ", max, " characters.");
        add_error(errs, field, m);
        return false;
    }
    return true;
}

fn check_range(errs: FieldErrors&, field: const u8[:], v: i64, min: i64, max: i64) -> bool {
    if has_error(errs, field) { return false; }
    if v < min || v > max {
        var m: u8[..96] = "";
        format(m, "Enter a number from ", min, " to ", max, ".");
        add_error(errs, field, m);
        return false;
    }
    return true;
}

// One @, text on both sides, a dot after it with text on both sides of it, no space.
fn email_ok(v: const u8[:]) -> bool {
    var at = -1;
    for i in v.len {
        if v[i] == ' ' { return false; }
        if v[i] == '@' {
            if at >= 0 { return false; }
            at = i;
        }
    }
    if at < 1 || at >= v.len - 1 { return false; }
    var i = at + 2;
    while i < v.len - 1 {
        if v[i] == '.' { return true; }
        i += 1;
    }
    return false;
}

fn check_email(errs: FieldErrors&, field: const u8[:], v: const u8[:]) -> bool {
    if has_error(errs, field) { return false; }
    if !email_ok(v) { add_error(errs, field, "Enter a valid email address."); return false; }
    return true;
}

fn check_one_of(errs: FieldErrors&, field: const u8[:], v: const u8[:], options: const u8[:][:]) -> bool {
    if has_error(errs, field) { return false; }
    for o in options { if o == v { return true; } }
    add_error(errs, field, "Choose one of the options.");
    return false;
}

// 422 {"errors":{"email":"Required.",...}}. The key and string writers are the ones http::json_error uses.
fn errors_json(res: http::Response&, errs: const FieldErrors&) {
    http::json_reply(res, http::Status.UnprocessableEntity);
    res.body.clear();
    res.body.push('{');
    json::format_key(res.body, "errors");
    res.body.push('{');
    for i in errs.n {
        if i > 0 { res.body.push(','); }
        json::format_key(res.body, errs.items[i].field);
        json::format_string(res.body, errs.items[i].message);
    }
    res.body.push('}');
    res.body.push('}');
}

// ---------------------------------------------------------------- template partials

// <span class="gw-error" id="FIELD-error">MSG</span>, or nothing.
fn field_error(out: u8[>..]&, errs: const FieldErrors&, field: const u8[:]) {
    let m = error_for(errs, field);
    if m.len == 0 { return; }
    out.append("<span class=\"gw-error\" id=\"");
    escape(out, field);
    out.append("-error\">");
    escape(out, m);
    out.append("</span>");
}

// Goes inside an input's start tag.
fn invalid(out: u8[>..]&, errs: const FieldErrors&, field: const u8[:]) {
    if !has_error(errs, field) { return; }
    out.append(" aria-invalid=\"true\" aria-describedby=\"");
    escape(out, field);
    out.append("-error\"");
}

// The posted value when the method is POST and the body has the field; else the fallback. Escaped.
fn field_value(out: u8[>..]&, req: const http::Request&, field: const u8[:], fallback: const u8[:]) {
    if req.method == http::Method.Post {
        var v: u8[>..] = [];
        if form(req, field, v) { escape(out, v); return; }
    }
    escape(out, fallback);
}

// ---------------------------------------------------------------- decoders
// Each returns true when the field is fine and false after adding an error.

// out is any u8[>..]& target, so a u8[..N] struct field passes as is; N is out.cap.
// Required and absent or blank (after trim): "Required." Optional and absent or blank: out is left alone.
// Longer than N: "Use at most N characters.", out left alone. The value is stored as typed, not trimmed.
fn form_text<T>(req: const http::Request&, field: const u8[:], out: T&, errs: FieldErrors&, required: bool) -> bool {
    var v: u8[>..] = [];
    let has = form(req, field, v);
    if !has || trim(v).len == 0 {
        if required { add_error(errs, field, "Required."); return false; }
        return true;
    }
    if v.len > out.cap {
        var m: u8[..64] = "";
        format(m, "Use at most ", out.cap, " characters.");
        add_error(errs, field, m);
        return false;
    }
    out.clear();
    out.append(v);
    return true;
}

// Fills an i64 field: parse_int(trim(value)); "Enter a whole number." when it does not parse. Optional absent or blank keeps out.
fn form_i64(req: const http::Request&, field: const u8[:], out: i64&, errs: FieldErrors&, required: bool) -> bool {
    var v: u8[>..] = [];
    let has = form(req, field, v);
    let t = trim(v);
    if !has || t.len == 0 {
        if required { add_error(errs, field, "Required."); return false; }
        return true;
    }
    let n, ok = parse_int(t);
    if !ok { add_error(errs, field, "Enter a whole number."); return false; }
    out = n;
    return true;
}

// True when present and not "", "off", "false" or "0"; absent is false. Never an error.
fn form_bool(req: const http::Request&, field: const u8[:], out: bool&) -> bool {
    var v: u8[>..] = [];
    let has = form(req, field, v);
    out = has && v != "" && v != "off" && v != "false" && v != "0";
    return true;
}

// The index of the posted variant name; -1 when absent and optional (keep the default); -2 after an error.
fn form_enum(req: const http::Request&, field: const u8[:], names: const u8[:][:], errs: FieldErrors&, required: bool) -> i64 {
    var v: u8[>..] = [];
    let has = form(req, field, v);
    let t = trim(v);
    if !has || t.len == 0 {
        if required { add_error(errs, field, "Required."); return -2; }
        return -1;
    }
    for n, i in names { if n == t { return i; } }
    add_error(errs, field, "Choose one of the options.");
    return -2;
}
