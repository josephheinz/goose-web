// goose-web event modifiers, imported by components whose markup has on:EVENT.MOD (Addendum 12, 7.2b).
// client/gwm.min.js is this file minified by client/build.sh.
import { hooks } from "./gwi.js";

const tm = new WeakMap();

// m: the modifiers of the element el (null when only a bind matched). A key filter must match e.key; prevent and
// stop apply at once; NNNms defers the handler (per element, restarted on each event) but not a bind.
hooks.m = (e, m, el, bound, go, name) => {
  const f = m.filter((x) => !/^(pr|st|\d)/.test(x)), k = e.key == " " ? "space" : e.key?.toLowerCase().replace("arrow", "");
  if (f.length && !f.includes(k)) el = 0;
  if (!el && !bound) return;
  if (el) {
    m.includes("prevent") && e.preventDefault();
    m.includes("stop") && e.stopPropagation();
  }
  const ms = parseInt(/\d+ms/.exec(m));
  if (!ms) return go(el && name, bound);
  bound && go(0, bound);
  el && (clearTimeout(tm.get(el)), tm.set(el, setTimeout(go, ms, name)));
};
