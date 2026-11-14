// gweb as-you-type forms (gw-trigger), served as /_gw/gwq.js on pages that use them, beside gwf.js.
// client/gwq.min.js is this file minified by client/build.sh.
//
// gw-trigger="input 250ms" on a GET form[gw-target]: input in the form submits it once 250 ms pass with no more input
// (50 to 2,000 ms, checked at build time). gwf.js sends it; the last request wins. A submit (Enter) cancels the wait.
const D = document;
D.addEventListener("input", (e) => {
  const f = e.target.form, m = f && /^input (\d+)ms$/.exec(f.getAttribute("gw-trigger"));
  if (m) clearTimeout(f.gwq), f.gwq = setTimeout(() => f.requestSubmit(), m[1]);
});
D.addEventListener("submit", (e) => clearTimeout(e.target.gwq), true);
