// gweb server push (gw-sse="/url"), served as /_gw/gwe.js on sites that use it; imports gwi.js and gws.js.
// client/gwe.min.js is this file minified by client/build.sh.
// One EventSource per distinct URL, opened on load and for gw-sse elements added later (hooks.a). Events (SSE):
//   event: fragment   data: NAME\nHTML   first line the target id, the rest HTML (may span lines): morphs #NAME
//                                        unless it is missing or inside a component
//   event: store      data: Store\nJSON  the JSON object replaces the store's state values it names
// Other events are ignored. Errors go to oops; EventSource reconnects on its own.

import { swap, hooks, oops } from "./gwi.js";
import { stores } from "./gws.js";
const D = document, seen = new Set(), a = hooks.a;

const open = () => {
  for (const el of D.querySelectorAll("[gw-sse]")) {
    const u = el.getAttribute("gw-sse");
    if (seen.has(u)) continue;
    const s = new EventSource(u), on = (n, f) => s.addEventListener(n, (e) => {
      try { const i = e.data.indexOf("\n"); f(e.data.slice(0, i), e.data.slice(i + 1)); } catch (x) { oops(x); }
    });
    seen.add(u);
    on("fragment", (n, h) => { const b = D.getElementById(n); b && !b.closest("[data-component]") && swap(b, h, 1); });
    on("store", (n, j) => stores[n]?.(JSON.parse(j)));
  }
};
hooks.a = () => (a?.(), open());
open();
