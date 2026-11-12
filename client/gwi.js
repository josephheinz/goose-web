// goose-web component runtime, served as /_gw/gwi.js; every /_gw/Name.js imports it.
// client/gwi.min.js is this file minified by client/build.sh.

const D = document;
const defs = {};
const live = new WeakMap();
const E = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const enc = new TextEncoder();

function fail(msg) { throw new RangeError(msg); }
function ix(a, i) { if (!(i >= 0 && i < a.length)) fail("bad index " + i); }
const nz = (b) => b || fail("division by zero");

export const esc = (v) => typeof v == "string" ? v.replace(/[&<>"']/g, (c) => E[c]) : "" + v;
export const at = (a, i) => (ix(a, i), a[i]);
export const set = (a, i, v) => { ix(a, i); a[i] = v; };
export const rm = (a, i) => (ix(a, i), a.splice(i, 1)[0]);
export const blen = (s) => enc.encode(s).length;
export const cap = (s, n) => blen(s) > n ? fail("string over capacity " + n) : s;
export const idiv = (a, b) => Math.trunc(a / nz(b));
export const imod = (a, b) => {
  const r = a % nz(b);
  return r < 0 ? r + Math.abs(b) : r;
};

export function component(name, def) { defs[name] = def; }

// Makes from's children match to's, without keys. value and checked sync after recursing so a <select>
// has its new options first; the focused control keeps its value unless force is set.
function morph(from, to, force) {
  let a = from.firstChild, b = to.firstChild;
  while (b) {
    const nb = b.nextSibling;
    if (!a) { from.append(b); b = nb; continue; }
    const na = a.nextSibling;
    if (a.nodeName != b.nodeName) a.replaceWith(b);
    else if (a.nodeType != 1) { if (a.data != b.data) a.data = b.data; }
    else {
      for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) a.removeAttribute(name);
      for (const { name, value } of b.attributes) if (a.getAttribute(name) != value) a.setAttribute(name, value);
      morph(a, b, force);
      if ("form" in a) {
        if ((a != D.activeElement || force) && a.value != b.value) a.value = b.value;
        a.checked = b.checked;
      }
    }
    a = na;
    b = nb;
  }
  while (a) { b = a.nextSibling; a.remove(); a = b; }
}

// Logs the error and raises gw:error for gweb dev's overlay.
function oops(err) {
  console.error(err);
  dispatchEvent(new CustomEvent("gw:error", { detail: String(err) }));
}

function swap(root, html, force) {
  const tp = D.createElement("template");
  tp.innerHTML = html;
  morph(root, tp.content, force);
}

// On a throw the state goes back to its copy and the DOM is left as it is.
function on(type, binds) {
  const attr = "data-on-" + type, sel = "[" + attr + "]";
  D.addEventListener(type, (e) => {
    const t = e.target, root = t.closest?.("[data-component]");
    const def = root && defs[root.dataset.component];
    if (!def) return;
    const inside = (n) => n && root.contains(n) ? n : null;
    const el = inside(t.closest(sel)), bound = binds && inside(t.closest("[data-bind]"));
    if (!el && !bound) return;
    let s = live.get(root);
    if (!s) live.set(root, s = JSON.parse(root.nextElementSibling.textContent));
    const keep = structuredClone(s);
    const f = inside(D.activeElement), k = f && f.dataset.bind;
    let force = 0, before, html;
    try {
      if (bound) {
        const k = bound.dataset.bind, v = bound.value;
        if (bound.type == "checkbox") s[k] = bound.checked;
        else if (typeof s[k] == "number") s[k] = Math.trunc(v) || 0;
        else if (!(blen(v) > bound.dataset.cap)) s[k] = v;
        else force = 1;
      }
      before = k && s[k];
      if (el) {
        if (type == "submit") e.preventDefault();
        def.handlers[el.getAttribute(attr)](s, ...JSON.parse(el.dataset.args || "[]"));
      }
      html = def.render(s);
    } catch (err) {
      live.set(root, keep);
      return oops(err);
    }
    if (k && s[k] !== before) force = 1;
    swap(root, html, force);
  }, true);
}

on("click");
on("change", 1);
on("input", 1);
on("submit");

// A reply without the GW-Fragment echo (a redirect to another page) becomes a normal navigation;
// the last request for a target wins.
function frag(type, sel, attr, form) {
  D.addEventListener(type, async (e) => {
    const el = e.target.closest?.(sel);
    const name = el && el.getAttribute("gw-target"), box = name && D.getElementById(name);
    if (!box || box.closest("[data-component]") || e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    const url = new URL(el.getAttribute(attr) || "", location.href);
    const data = form && new URLSearchParams(new FormData(el, e.submitter));
    const post = form && /^post$/i.test(el.getAttribute("method"));
    if (data && !post) url.search = data;
    const n = box.gw = -~box.gw;
    box.setAttribute("aria-busy", "true");
    try {
      const r = await fetch(url, { method: post ? "POST" : "GET", body: post ? data : null, headers: { "GW-Fragment": name } });
      if (!r.ok) throw Error("fragment " + name + ": " + r.status + " from " + url.pathname);
      if (r.headers.get("GW-Fragment") != name) return location.assign(r.url);
      const html = await r.text();
      if (box.gw == n) swap(box, html, 1);
    } catch (err) {
      oops(err);
    } finally {
      if (box.gw == n) box.removeAttribute("aria-busy");
    }
  });
}

frag("click", "a[gw-target]", "href");
frag("submit", "form[gw-target]", "action", 1);
