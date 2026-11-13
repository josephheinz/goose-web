// goose-web shared stores (Addendum 12 section 7.7): the module /_gw/Name.js of a store exports store(...).
// client/gws.min.js is this file minified by client/build.sh.
import { defs, run, state } from "./gwi.js";

const J = JSON.stringify, ALL = -1 >>> 1;
// The loaded stores by name, each a writer (gwe.js): w(values) replaces the state values it names.
export const stores = {};

// def: i builds the initial state, u recomputes the computeds, h holds the functions, b the bit of each name.
// key: the localStorage key of @store(local: "key"). The state is built once, when first needed: the page's
// first data-store script (the server's initial state), then what localStorage holds, else def.i().
export function store(name, def, key) {
  let S, subs = [];
  const get = () => S ||= load();
  const load = () => {
    const el = document.querySelector(`script[data-store="${name}"]`), t = { ...def.i(), ...(el && JSON.parse(el.textContent)) };
    try { key && Object.assign(t, JSON.parse(localStorage.getItem(key))); } catch {}
    def.u(t, ALL);
    return t;
  };
  // The store's values of the names in ch go into component state s, under the names s keeps them by; the
  // component's bits for them come back.
  const put = (s, map, ch) => {
    let m = 0;
    for (const n of ch) if (map[n]) (s[`gw_${name}_${n}`] = S[n], m |= map[n]);
    return m;
  };
  const o = {
    i: def.i,
    // A component's start (its mount handler): its root c.r follows the store; map is name -> its bit there.
    sub(s, c, map) {
      get();
      subs.push([c.r, map]);
      c.m(put(s, map, Object.keys(map)));
    },
  };
  // A function called from a component handler (c is its change handle): it runs on the store's state, and every
  // subscriber whose names changed takes the new values; the caller's root through c, the others through run.
  // Runs f on the store's state; every subscriber whose names changed takes the new values (the caller's
  // root through c, the others through run).
  const hit = (c, f) => {
    const t = get(), was = {};
    for (const n in def.b) was[n] = J(t[n]);
    f(t);
    def.u(t, ALL);
    const ch = Object.keys(def.b).filter((n) => J(t[n]) != was[n]);
    if (!ch.length) return;
    try { key && localStorage.setItem(key, J(t)); } catch {}
    subs = subs.filter((x) => x[0].isConnected);
    for (const [r, map] of subs) {
      const m = put(state(r), map, ch);
      m && (r == c.r ? c.m(m) : run(r, defs[r.dataset.component], 0, [], 0, 0, m));
    }
  };
  for (const k in def.h) o[k] = (c, ...a) => hit(c, (t) => def.h[k](t, { m() {} }, ...a));
  stores[name] = (v) => hit({}, (t) => { for (const n in v) n in def.b && (t[n] = v[n]); });
  return o;
}
