// gwt.js: gw-enter / gw-leave transitions (DESIGN-ADDENDUM-12, section 7.10). Fills hooks.t.
import { hooks } from "./gwi.js";
const prev = hooks.t;
let id = 0;
// Adds the classes of attribute a, calls done at the end event, after 1 s, or next frame if nothing animates.
function go(n, a, done) {
  const x = () => { n.removeEventListener("animationend", e); n.removeEventListener("transitionend", e); done(); };
  const e = (v) => v.target == n && x();
  n.classList.add(...n.getAttribute(a).split(/\s+/).filter(Boolean));
  n.addEventListener("animationend", e);
  n.addEventListener("transitionend", e);
  setTimeout(x, 1e3);
  const c = getComputedStyle(n);
  /[1-9]/.test(c.animationDuration + c.transitionDuration) || requestAnimationFrame(x);
}
hooks.t = (n, i) => {
  const a = i ? "gw-enter" : "gw-leave", v = n.getAttribute(a);
  if (!v) return prev?.(n, i);
  if (i) return go(n, a, () => n.classList.remove(...v.split(/\s+/).filter(Boolean)));
  if (n.hasAttribute("gw-leaving")) return false;
  // A new key frees the key for a fresh element; the next morph of the parent removes this one at once.
  n.setAttribute("gw-key", "~" + ++id);
  n.setAttribute("gw-leaving", "");
  go(n, a, () => n.remove());
  return true;
};
