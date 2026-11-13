// goose-web typed fetch for components (http::get, http::post), imported by a component module as ./gwh.js.
// client/gwh.min.js is this file minified by client/build.sh.

// d(value, "") returns the checked value or throws the path of the first mismatch; no d ignores the body.
async function go(u, o, d) {
  const r = await fetch(u, o);
  if (!r.ok) throw Error(r.status + " from " + u);
  if (!d) return;
  try { return d(await r.json(), ""); }
  catch (p) { throw Error("bad reply from " + u + " at " + (p instanceof Error ? "" : p)); }
}

export const get = (u, d) => go(u, {}, d);

export const post = (u, v, d) => {
  const t = document.querySelector("input[name=_csrf]")?.value, h = { "Content-Type": "application/json" };
  if (t) h["X-CSRF-Token"] = t;
  return go(u, { method: "POST", headers: h, body: JSON.stringify(v) }, d);
};
