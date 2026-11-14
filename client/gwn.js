// gweb client navigation (<body gw-boost>), served as /_gw/gwn.js on sites that use it; imports gwi.js.
// client/gwn.min.js is this file minified by client/build.sh.
// A boosted link fetches the page with GW-Nav: 1 and morphs <body> (attributes too), sets the title, imports module
// scripts not loaded yet and pushes history. A component root with the same gw-key and name on both pages is kept
// as it is. Not done: <head> other than the title, and inline non-module scripts in the new body (they do not run).
// A reply that is not ok or not text/html, or a failure, becomes a normal navigation; the last navigation wins.
// A 401 (require_login, for a request that sends GW-Auth: 401) fires a cancelable gw:unauthorized event on window, with
// the reply as detail; unless a listener cancels it, it is a normal navigation, and the server sends it to the login.

import { swap, hooks, oops } from "./gwi.js";
const D = document, mods = (d) => [...d.querySelectorAll("script[type=module][src]")].map((s) => s.src), seen = new Set(mods(D));
let n = 0;

async function go(u, push) {
  const k = ++n;
  try {
    const r = await fetch(u, { headers: { "GW-Nav": "1", "GW-Auth": "401" } });
    if (k != n) return;
    if (!r.ok || !/html/.test(r.headers.get("content-type"))) throw r;
    const d = new DOMParser().parseFromString(await r.text(), "text/html"), b = D.body, p = hooks.c;
    if (k != n) return;
    D.title = d.title;
    for (const { name } of [...b.attributes]) d.body.hasAttribute(name) || b.removeAttribute(name);
    for (const { name, value } of d.body.attributes) b.setAttribute(name, value);
    // A keyed component root that morph has paired with the new page's one stays untouched.
    hooks.c = (o, x) => o.hasAttribute("gw-key") && o.dataset.component == x.dataset.component || p?.(o, x);
    try { swap(b, d.body.innerHTML); } finally { hooks.c = p; }
    for (const s of mods(d)) seen.has(s) || (seen.add(s), import(s).catch(oops));
    push && history.pushState(0, "", r.url || u);
    const h = new URL(u, location.href).hash, t = h && D.getElementById(decodeURIComponent(h.slice(1)));
    t ? t.scrollIntoView() : scrollTo(0, 0);
  } catch (e) {
    (e.status == 401 && !dispatchEvent(new CustomEvent("gw:unauthorized", { cancelable: 1, detail: e }))) || location.assign(u);
  }
}

D.addEventListener("click", (e) => {
  const a = !e.defaultPrevented && !e.button && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) && e.target.closest?.("body[gw-boost] a[href]:not([gw-target],[download])");
  if (!a || (a.target && a.target != "_self")) return;
  const u = new URL(a.href), l = location;
  if (u.origin != l.origin || (u.hash && u.pathname == l.pathname && u.search == l.search)) return;
  e.preventDefault();
  go(u.href, 1);
});
addEventListener("popstate", () => go(location.href));
