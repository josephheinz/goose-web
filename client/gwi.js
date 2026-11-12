// goose-web component runtime, served as /_gw/gwi.js; every /_gw/Name.js imports it.
// client/gwi.min.js is this file minified by client/build.sh.

const D = document;
export const defs = {};
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

// Optional modules (lifecycle, child components, transitions, effects) fill this; see Addendum 12 section 5.
export const hooks = {};

export function component(name, def) { defs[name] = def; }

const cn = (n) => n.dataset.component;

// A child's key is its tag plus its gw-key; a tag change under the same gw-key is a different child.
const key = (n, k = n.getAttribute?.("gw-key")) => k && n.nodeName + " " + k;

// Makes from's children match to's, or only those after s and before z (z null: to the end). A child with
// gw-key is matched to the old child with the same key wherever it is; the others are matched in order
// among themselves. A new keyed child is told to hooks.t on insert, an old one before it is removed.
function morph(from, to, force, s, z = null) {
  const want = new Set(), old = new Map();
  for (const n of to.childNodes) {
    const k = key(n);
    if (k) want.has(k) ? oops("duplicate gw-key " + k) : want.add(k);
  }
  const first = s ? s.nextSibling : from.firstChild;
  // Old keyed children that are not wanted leave first, so every keyed child still here is claimed below.
  for (let n = first, nn; n != z; n = nn) {
    nn = n.nextSibling;
    const k = key(n);
    if (k) want.has(k) && !old.has(k) ? old.set(k, n) : hooks.t?.(n, 0) || n.remove();
  }
  let a = s ? s.nextSibling : from.firstChild, b = to.firstChild;
  while (b) {
    const nb = b.nextSibling, k = key(b);
    let o;
    if (k) {
      o = old.get(k);
      old.delete(k);
      if (o && o != a) {
        // A keyed child right before its match is stepped over and placed when its own turn comes;
        // this turns a swap or a move to the end into one move.
        if (a?.nextSibling == o && key(a)) a = o;
        else {
          // insertBefore blurs a focused control inside the moved child.
          const f = D.activeElement;
          from.insertBefore(o, a);
          if (f != D.activeElement) f.focus();
        }
      }
    } else {
      while (a != z && key(a)) a = a.nextSibling;
      o = a != z && a;
    }
    if (!o) { from.insertBefore(b, a); k && hooks.t?.(b, 1); }
    else {
      if (o == a) a = a.nextSibling;
      if (o.nodeName != b.nodeName) o.replaceWith(b);
      else if (o.nodeType != 1) { if (o.data != b.data) o.data = b.data; }
      else if (!(cn(o) && cn(o) == cn(b) && hooks.c?.(o, b))) patch(o, b, force);
    }
    b = nb;
  }
  // A keyed child left here was held back by hooks.t; it is not ours to remove.
  while (a != z) { b = a.nextSibling; key(a) || a.remove(); a = b; }
}

// Element o takes b's attributes, children (unless top) and form state. value and checked sync after
// recursing so a <select> has its new options first; the focused control keeps its value unless force is set.
function patch(o, b, force, top) {
  for (const { name } of [...o.attributes]) if (!b.hasAttribute(name)) o.removeAttribute(name);
  for (const { name, value } of b.attributes) if (o.getAttribute(name) != value) o.setAttribute(name, value);
  top || morph(o, b, force);
  if ("form" in o) {
    if ((o != D.activeElement || force) && o.value != b.value) o.value = b.value;
    o.checked = b.checked;
  }
}

// Logs the error and raises gw:error for gweb dev's overlay.
export function oops(err) {
  console.error(err);
  dispatchEvent(new CustomEvent("gw:error", { detail: String(err) }));
}

export function swap(root, html, force) {
  morph(root, tpl(html), force);
  hooks.a?.();
}

export function state(root) {
  let s = live.get(root);
  if (!s) live.set(root, s = JSON.parse(root.nextElementSibling.textContent));
  return s;
}

const parts = new WeakMap();
// The root's own "g" comments in document order, not those of nested components.
function anchors(root) {
  let p = parts.get(root);
  if (!p) {
    parts.set(root, p = []);
    const w = D.createTreeWalker(root, 128);
    for (let n; n = w.nextNode();) if (n.data == "g" && n.parentNode.closest("[data-component]") == root) p.push(n);
  }
  return p;
}
const tpl = (h) => { const t = D.createElement("template"); t.innerHTML = h; return t.content; };
// Text part: the node after the marker; it is inserted when the server sent an empty value.
export const T = (a, v) => { const n = a.nextSibling; n.nodeType == 3 ? n.data != v && (n.data = v) : a.after(v); };
// Attribute part: the element after the marker takes the attribute list v.
export const A = (a, v, f) => patch(a.nextSibling, tpl("<" + a.nextSibling.nodeName + " " + v + ">").firstChild, f, 1);
// Block part: keyed morph between the marker and its end marker.
export const B = (a, v, f) => { let z = a; do z = z.nextSibling; while (z.data != "/g"); morph(a.parentNode, tpl(v), f, a, z); };

// One dispatch: bind, handler, phase 1 (def.u, may throw), phase 2 (DOM writes), watches. A sync failure
// restores the whole copy and leaves the DOM alone; an async one restores only the keys the handler
// writes (def.x) and shows that rollback.
export function run(root, def, name, args, e, bound) {
  const s = state(root), keep = structuredClone(s);
  const f = D.activeElement, k = root.contains(f) && f.dataset.bind;
  let m = 0, force = 0, before, applied, dead;
  const c = { m: (b) => m |= b, f: () => flush(1), r: root, e: (n, a) => hooks.e?.(root, n, a) };
  // Rounds 1 to 8: a watch that marks bits makes another round.
  const flush = (x) => {
    const b = m;
    m = 0;
    try {
      const go = def.u(s, b);
      applied = 1;
      go(anchors(root), root, force);
    } catch (err) { return fail(err); }
    try { def.w?.(s, b, c); } catch (err) { oops(err); }
    hooks.a?.();
    if (m) x < 8 ? flush(x + 1) : (m = 0, oops("watch loop in " + cn(root)));
  };
  const fail = (err) => {
    if (dead) return oops(err);
    dead = 1;
    if (!applied) Object.assign(s, keep);
    else {
      const x = def.x?.[name] || 0;
      for (const n in def.b) if (def.b[n] & x) { s[n] = keep[n]; m |= def.b[n]; }
      m && flush(1);
    }
    oops(err);
  };
  try {
    if (bound) {
      const k = bound.dataset.bind, v = bound.value;
      if (bound.type == "checkbox") s[k] = bound.checked;
      else if (typeof s[k] == "number") s[k] = Math.trunc(v) || 0;
      else if (!(blen(v) > bound.dataset.cap)) s[k] = v;
      else force = 1;
      m |= def.b?.[k] || 0;
    }
    before = k && s[k];
    if (name) {
      if (e?.type == "submit") e.preventDefault();
      def.h[name](s, c, ...args)?.then?.(() => dead || flush(1), fail);
    }
  } catch (err) { return fail(err); }
  if (k && s[k] !== before) force = 1;
  flush(1);
}

function on(type, binds) {
  const attr = "data-on-" + type, sel = "[" + attr + "]";
  D.addEventListener(type, (e) => {
    const t = e.target, root = t.closest?.("[data-component]");
    const def = root && defs[cn(root)];
    if (!def) return;
    const inside = (n) => n && root.contains(n) ? n : null;
    const el = inside(t.closest(sel)), bound = binds && inside(t.closest("[data-bind]"));
    if (el || bound) run(root, def, el && el.getAttribute(attr), JSON.parse(el?.dataset.args || "[]"), e, bound);
  }, true);
}

on("click");
on("change", 1);
on("input", 1);
on("submit");
