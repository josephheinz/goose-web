// goose-web component runtime (DESIGN-ADDENDUM-3, E4). Served as /_gw/gwi.js;
// every /_gw/Name.js imports it. client/gwi.min.js is this file minified by
// client/build.sh, which gweb build and gweb start ship instead.
//
// A component is <div data-component="Name">, its render, then a
// <script type="application/json"> with its state. Four capture listeners on
// document find the component of an event, run the bind or handler on its state,
// render again and morph the DOM to the new HTML.

const D = document;
const defs = {};
const live = new WeakMap();
const E = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const enc = new TextEncoder();

function fail(msg) { throw new RangeError(msg); }
function ix(a, i) { if (!(i >= 0 && i < a.length)) fail("bad index " + i); }
const nz = (b) => b || fail("division by zero");

// The helpers generated component code calls (E3's JS rules).
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

// Makes from's children match to's: walks both lists in parallel, replaces a
// node of another type or tag, updates text, syncs attributes, recurses, then
// syncs value and checked (after the recursion, so a <select> has its new
// options first). The focused control keeps its value unless force is set.
// Extra new nodes are appended and extra old ones removed. No keys (E4 limits).
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
      // Form controls: value unless the user is typing in it, and checked.
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

// One capture listener: the nearest component, the nearest element with a
// handler for this event and (for input and change) the nearest bound one,
// both only when inside the component. Bind, handler and render run in one try:
// on a throw the state goes back to its copy and the DOM is left as it is.
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
    // The focused bound control and its state before the handler (point 3).
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
      // The changes are dropped: the state goes back to its copy, and the DOM
      // already shows that state.
      live.set(root, keep);
      console.error(err);
      dispatchEvent(new CustomEvent("gw:error", { detail: String(err) }));
      return;
    }
    if (k && s[k] !== before) force = 1;
    const tp = D.createElement("template");
    tp.innerHTML = html;
    morph(root, tp.content, force);
  }, true);
}

on("click");
on("change", 1);
on("input", 1);
on("submit");
