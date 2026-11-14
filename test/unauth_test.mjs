// Driven by test/runtime.sh. A 401 in a fragment request (client/gwf.js) and in a boosted navigation (client/gwn.js):
// both send GW-Auth: 401, fire a cancelable gw:unauthorized event on window with the reply as detail, and fall back to
// a full navigation unless a listener cancels the event. Other statuses keep their old behaviour.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
let bad = 0, total = 0;
const check = (c, m) => { total++; if (!c) { bad++; console.error("FAIL: " + m); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- gwf.js: the frag() code runs in a function with the page's globals, as test/frag_test.mjs does.
const read = (f) => fs.readFileSync(new URL("../client/" + f, import.meta.url), "utf8");
const src = (read("gwi.js") + "\n{\n" + read("gwf.js").replace(/^import .*$/m, "") + "\n}").replace(/^export /gm, "");
function fpage(status, listener) {
  const dom = new JSDOM('<!doctype html><body><div id="b"><p>old</p></div><a id="l" href="/f?x=1" gw-target="b">x</a><form id="f" method="post" action="/p" gw-target="b"></form></body>', { url: "http://x.test/" });
  const w = dom.window, sent = [], assigns = [], events = [];
  w.fetch = async (url, init) => {
    sent.push({ url: String(url), init });
    return { ok: status < 300, status, url: String(url), text: async () => "<p>login page</p>", headers: { get: (k) => (k == "GW-Login" ? "/login?next=%2Ff" : null) } };
  };
  w.console.error = () => {};
  w.addEventListener("gw:unauthorized", (e) => { events.push(e); listener?.(e); });
  const loc = { href: "http://x.test/", assign: (u) => assigns.push(u) };
  new w.Function("document", "location", "CustomEvent", "dispatchEvent", "console", "fetch", "FormData", "URLSearchParams", "URL", "TextEncoder", "structuredClone", "WeakMap", "setTimeout", "clearTimeout",
    src).call(w, w.document, loc, w.CustomEvent, (e) => w.dispatchEvent(e), w.console, w.fetch, w.FormData, w.URLSearchParams, w.URL, w.TextEncoder, w.structuredClone, WeakMap, setTimeout, clearTimeout);
  return { w, d: w.document, sent, assigns, events, box: w.document.getElementById("b") };
}
const click = (w, el) => el.dispatchEvent(new w.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
const submit = (w, f) => f.dispatchEvent(new w.Event("submit", { bubbles: true, cancelable: true }));

{ // 401 on a link: header sent, event fired, navigation to the link, the box untouched
  const p = fpage(401);
  click(p.w, p.d.getElementById("l")); await sleep(30);
  check(p.sent[0]?.init.headers["GW-Auth"] == "401" && p.sent[0]?.init.headers["GW-Fragment"] == "b", "gwf sends GW-Fragment and GW-Auth");
  check(p.events.length == 1 && p.events[0].cancelable && p.events[0].detail.status == 401, "gwf fires a cancelable event with the reply");
  check(p.events[0].detail.headers.get("GW-Login") == "/login?next=%2Ff", "the listener can read GW-Login");
  check(p.assigns.join() == "http://x.test/f?x=1", "gwf falls back to a full navigation: " + p.assigns.join());
  check(p.box.innerHTML == "<p>old</p>", "the box is untouched: " + p.box.innerHTML);
  check(!p.box.hasAttribute("aria-busy"), "aria-busy is cleared");
}
{ // a listener that cancels the event stops the navigation
  const p = fpage(401, (e) => e.preventDefault());
  click(p.w, p.d.getElementById("l")); await sleep(30);
  check(p.events.length == 1 && p.assigns.length == 0, "a canceled event leaves the page where it is");
  check(p.box.innerHTML == "<p>old</p>" && !p.box.hasAttribute("aria-busy"), "and the box is as it was");
}
{ // a form post
  const p = fpage(401);
  submit(p.w, p.d.getElementById("f")); await sleep(30);
  check(p.sent[0]?.init.method == "POST" && p.events.length == 1 && p.assigns.length == 1, "a posted fragment form is handled too");
}
{ // other statuses fire no event
  for (const st of [403, 404, 500]) {
    const p = fpage(st);
    click(p.w, p.d.getElementById("l")); await sleep(30);
    check(p.events.length == 0 && p.assigns.length == 0 && p.box.innerHTML == "<p>old</p>", "status " + st + " fires no gw:unauthorized");
  }
}

// ---- gwn.js: a module, with stub fetch, location and history, as test/nav_test.mjs does.
const dom = new JSDOM("<!doctype html><title>A</title><body gw-boost></body>", { url: "http://site.test/a" });
const { window } = dom, document = window.document;
const assigns = [], calls = [], events = [];
let reply = () => ({}), cancel = false;
const loc = { href: "http://site.test/a", origin: "http://site.test", pathname: "/a", search: "", assign: (u) => assigns.push(u) };
Object.assign(globalThis, {
  document, CustomEvent: window.CustomEvent, DOMParser: window.DOMParser, URL,
  dispatchEvent: (e) => window.dispatchEvent(e), addEventListener: (t, f) => window.addEventListener(t, f),
  location: loc, scrollTo() {}, history: { pushState() {} },
  fetch: async (u, o) => { calls.push([String(u), o.headers]); return reply(String(u)); },
});
window.addEventListener("gw:unauthorized", (e) => { events.push(e); if (cancel) e.preventDefault(); });
console.error = () => {};
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "gwn-unauth-"));
fs.writeFileSync(tmp + "/package.json", '{"type":"module"}');
for (const f of ["gwi.js", "gwn.js"]) fs.copyFileSync(new URL("../client/" + f, import.meta.url), tmp + "/" + f);
await import(pathToFileURL(tmp + "/gwn.js").href);
const nclick = () => document.getElementById("l").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
const nreset = () => { document.body.innerHTML = '<a id="l" href="/b">go</a><p>old</p>'; assigns.length = calls.length = events.length = 0; };
const status = (st) => (reply = (u) => ({ ok: st < 300, status: st, url: u, headers: { get: (k) => (k == "content-type" ? "text/html" : null) }, text: async () => "<p>login</p>" }));

nreset(); status(401); cancel = false;
nclick(); await sleep(20);
check(calls[0]?.[1]["GW-Nav"] == "1" && calls[0]?.[1]["GW-Auth"] == "401", "gwn sends GW-Nav and GW-Auth");
check(events.length == 1 && events[0].cancelable && events[0].detail.status == 401, "gwn fires a cancelable event with the reply");
check(assigns.join() == "http://site.test/b", "gwn falls back to a full navigation: " + assigns.join());
check(document.querySelector("p")?.textContent == "old", "the page is untouched");

nreset(); status(401); cancel = true;
nclick(); await sleep(20);
check(events.length == 1 && assigns.length == 0, "gwn: a canceled event stops the navigation");
cancel = false;

for (const st of [403, 404, 500]) {
  nreset(); status(st);
  nclick(); await sleep(20);
  check(events.length == 0 && assigns.join() == "http://site.test/b", "gwn: status " + st + " fires no event and navigates");
}
nreset(); reply = () => { throw new Error("offline"); };
nclick(); await sleep(20);
check(events.length == 0 && assigns.join() == "http://site.test/b", "gwn: a fetch error fires no event");

fs.rmSync(tmp, { recursive: true, force: true });
if (bad) { console.error(bad + " of " + total + " checks failed"); process.exit(1); }
console.log("unauth_test: " + total + " checks passed");
