// goose-web fragments (gw-target), served as /_gw/gwf.js on pages that use them; imports gwi.js.
// client/gwf.min.js is this file minified by client/build.sh.

import { swap, oops } from "./gwi.js";
const D = document;

// A reply without the GW-Fragment echo (a redirect to another page) becomes a normal navigation;
// the last request for a target wins. A 422 with the echo is morphed like a 200; a multipart form posts FormData;
// after 150 ms a link, or a form with gw-loading, fills the box with its loading template, restored on failure.
function frag(type, sel, attr, form) {
  D.addEventListener(type, async (e) => {
    const el = e.target.closest?.(sel);
    const name = el && el.getAttribute("gw-target"), box = name && D.getElementById(name);
    if (!box || box.closest("[data-component]") || e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey) return;
    e.preventDefault();
    const url = new URL(el.getAttribute(attr) || "", location.href);
    const post = form && /^post$/i.test(el.getAttribute("method")), fd = form && new FormData(el, e.submitter);
    const data = form && (post && el.enctype[0] == "m" ? fd : new URLSearchParams(fd));
    if (data && !post) url.search = data;
    const n = box.gw = -~box.gw;
    box.setAttribute("aria-busy", "true");
    let saved;
    const L = el.getAttribute("gw-loading"), tm = (!form || L != null) && setTimeout(() => {
      const t = D.getElementById(L || "gw-loading");
      if (t && box.gw == n) saved = [...box.childNodes], box.replaceChildren(t.content.cloneNode(true));
    }, 150);
    try {
      const r = await fetch(url, { method: post ? "POST" : "GET", body: post ? data : null, headers: { "GW-Fragment": name } });
      if (!r.ok && !(r.status == 422 && r.headers.get("GW-Fragment") == name)) throw Error("fragment " + name + ": " + r.status + " from " + url.pathname);
      if (r.headers.get("GW-Fragment") != name) return location.assign(r.url);
      const html = await r.text();
      if (box.gw == n) swap(box, html, 1);
    } catch (err) {
      if (saved) box.replaceChildren(...saved);
      oops(err);
    } finally {
      clearTimeout(tm);
      if (box.gw == n) box.removeAttribute("aria-busy");
    }
  });
}

frag("click", "a[gw-target]", "href");
frag("submit", "form[gw-target]", "action", 1);
