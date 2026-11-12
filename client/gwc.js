// goose-web child components, imported by modules that call @Child(...) (Addendum 12 section 7.5).
// client/gwc.min.js is this file minified by client/build.sh.
import { defs, esc, hooks, run, state } from "./gwi.js";

const cn = (n) => n.dataset.component, prev = hooks.c;

// Props p (an object) go into the child root r's live state; the child updates from the bits that changed. The
// write runs as a handler of the child, so a failing update restores its state.
const put = (r, p) => {
  const d = defs[cn(r)], s = state(r), q = Object.keys(p).filter((k) => d.b[k] & d.p && s[k] !== p[k]);
  d.h.$ = (s, c) => q.map((k) => (s[k] = p[k], c.m(d.b[k])));
  q[0] && run(r, d, "$", []);
};

// morph met old root o and new root b of one component: the new props come from b's JSON, and the child keeps
// its own state. The old JSON script may be overwritten afterwards: the live state is in gwi.js. A different
// component at the same place is replaced (its live state is not the new one's).
hooks.c = (o, b) => prev?.(o, b) || (cn(o) != cn(b) ? !o.replaceWith(b) : defs[cn(o)].b && !put(o, JSON.parse(b.nextElementSibling.textContent)));

// Top-level child part: the root after marker a takes props p.
export const Q = (a, p) => put(a.nextSibling, p);

// Before a block morph: every child root below the marker's parent reads its state while its own script is still next to it.
export const M = (a) => a.parentNode.querySelectorAll("[data-component]").forEach(state);

// The server form of child n with props p and key k (text, or none), for a block's HTML (the module script is not needed).
export const H = (n, p, k) => {
  const d = defs[n], s = d.i(p);
  return `<div data-component="${n}"${k ? ` gw-key="${esc(k)}"` : ""}>${d.r(s)}</div><script type="application/json">${JSON.stringify(s).replace(/[<>&]/g, (c) => "\\u00" + c.charCodeAt().toString(16))}</script>`;
};
