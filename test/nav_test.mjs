// Driven by test/runtime.sh. Runs client/gwn.js (client navigation, DESIGN-ADDENDUM-12 item 8) against jsdom
// with a stub fetch, history and location. gwn.js and gwi.js are copied to a temp folder (as ES modules).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><title>A</title><body gw-boost></body>", { url: "http://site.test/a" });
const { window } = dom, document = window.document;
const scrolls = [], pushes = [], assigns = [], calls = [];
let reply = () => ({ ok: true, status: 200, url: "", headers: { get: () => "text/html; charset=utf-8" }, text: async () => "" });
const loc = { href: "http://site.test/a", origin: "http://site.test", pathname: "/a", search: "", assign: (u) => assigns.push(u) };
Object.assign(globalThis, {
  document, CustomEvent: window.CustomEvent, DOMParser: window.DOMParser, URL,
  dispatchEvent: (e) => window.dispatchEvent(e), addEventListener: (t, f) => window.addEventListener(t, f),
  location: loc, scrollTo: (...a) => scrolls.push(a.join()), history: { pushState: (...a) => { pushes.push(a[2]); } },
  fetch: async (u, o) => { calls.push([String(u), o.headers["GW-Nav"]]); return reply(String(u)); },
});
console.error = () => {};
window.Element.prototype.scrollIntoView = function () { scrolls.push("to #" + this.id); };

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "gwn-"));
fs.writeFileSync(tmp + "/package.json", '{"type":"module"}');
for (const f of ["gwi.js", "gwn.js"]) fs.copyFileSync(new URL("../client/" + f, import.meta.url), tmp + "/" + f);
fs.writeFileSync(tmp + "/page.js", "globalThis.pageLoads = (globalThis.pageLoads || 0) + 1;");
const modUrl = pathToFileURL(tmp + "/page.js").href;
const G = await import(pathToFileURL(tmp + "/gwi.js").href);
await import(pathToFileURL(tmp + "/gwn.js").href);

const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${JSON.stringify(x)}, want ${JSON.stringify(y)}`); };
const tick = () => new Promise((r) => setTimeout(r, 5));
const page = (title, body, attrs = " gw-boost") => `<!doctype html><title>${title}</title><body${attrs}>${body}</body>`;
const serve = (html, over) => { reply = (u) => ({ ok: true, status: 200, url: u, headers: { get: () => "text/html" }, text: async () => html, ...over }); };
const link = (href, attrs = "") => `<a id=l href="${href}" ${attrs}>go</a>`;
const click = (init) => document.getElementById("l").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true, ...init }));
const reset = (body) => { document.body.innerHTML = body; pushes.length = assigns.length = calls.length = 0; loc.href = "http://site.test/a"; loc.pathname = "/a"; };
let n = 0;
const test = async (name, f) => { try { await f(); n++; } catch (e) { console.log("FAIL nav: " + name + ": " + e.message); process.exitCode = 1; } };

await test("boosted click morphs body, sets title, pushes", async () => {
  reset(link("/b") + "<p id=old>old</p>");
  serve(page("B", link("/c") + "<p id=new>new</p>", " gw-boost class=x"));
  const prevented = !click();
  eq(prevented, true, "click prevented");
  await tick();
  eq(calls.length, 1, "one fetch");
  eq(calls[0][0], "http://site.test/b", "fetched url");
  eq(calls[0][1], "1", "GW-Nav header");
  eq(document.title, "B", "title");
  eq(document.getElementById("new").textContent, "new", "body morphed");
  eq(document.getElementById("old"), null, "old gone");
  eq(document.body.className, "x", "body attributes synced");
  eq(pushes.join(), "http://site.test/b", "pushState");
  eq(assigns.length, 0, "no full navigation");
  eq(scrolls.pop(), "0,0", "scrolled to the top");
});

await test("a #hash target is scrolled to", async () => {
  reset(link("/b#sec"));
  serve(page("B", "<h2 id=sec>s</h2>"));
  click();
  await tick();
  eq(scrolls.pop(), "to #sec", "scrolled to #sec");
});

await test("a keyed component root keeps its node and state", async () => {
  const comp = (k, v) => `<div data-component="C" gw-key="${k}"><b>${v}</b></div><script type="application/json">{"n":${v}}</script>`;
  reset(link("/b") + comp("k1", 0));
  const root = document.querySelector("[data-component]"), s = G.state(root);
  s.n = 7;
  root.firstChild.textContent = "live";
  serve(page("B", link("/c") + comp("k1", 0)));
  click();
  await tick();
  eq(document.querySelector("[data-component]"), root, "root node identity");
  eq(G.state(root), s, "state object identity");
  eq(s.n, 7, "state kept");
  eq(root.firstChild.textContent, "live", "its DOM kept as it is");
  eq(G.hooks.c, undefined, "hooks.c restored");
  // Another key is a different component: replaced.
  serve(page("B", link("/c") + comp("k2", 3)));
  click();
  await tick();
  eq(document.querySelector("[data-component]") == root, false, "different key: new root");
});

await test("modifier, gw-target, download, target and cross-origin links are not intercepted", async () => {
  for (const [html, init] of [[link("/b"), { ctrlKey: true }], [link("/b"), { metaKey: true }], [link("/b"), { shiftKey: true }], [link("/b"), { altKey: true }], [link("/b"), { button: 1 }],
    [link("/b", 'gw-target="x"'), {}], [link("/b", "download"), {}], [link("/b", 'target="_blank"'), {}], [link("http://other.test/b"), {}], [link("mailto:x@y.z"), {}]]) {
    reset(html);
    serve(page("B", "x"));
    eq(click(init), true, "not prevented: " + html + JSON.stringify(init));
    await tick();
    eq(calls.length, 0, "no fetch: " + html);
  }
  // A pure hash change is left to the browser (jsdom would navigate and fire popstate, so cancel after gwn.js looked).
  reset(link("/a#top"));
  let seen;
  const keep = (e) => { seen = e.defaultPrevented; e.preventDefault(); };
  document.addEventListener("click", keep);
  click();
  document.removeEventListener("click", keep);
  await tick();
  eq(seen, false, "hash change not intercepted");
  eq(calls.length, 0, "hash change: no fetch");
  reset(link("/b", 'target="_self"'));
  serve(page("B", "x"));
  eq(click(), false, "target=_self is boosted");
  await tick();
  // Outside a boosted body: the attribute is gone.
  reset(link("/b"));
  document.body.removeAttribute("gw-boost");
  eq(click(), true, "unboosted body");
  document.body.setAttribute("gw-boost", "");
  // A handler that already prevented the default wins.
  reset(link("/b"));
  document.getElementById("l").addEventListener("click", (e) => e.preventDefault());
  click();
  await tick();
  eq(calls.length, 0, "defaultPrevented: no fetch");
});

await test("404 and non-HTML replies and fetch errors fall back to location.assign", async () => {
  reset(link("/b"));
  serve("nope", { ok: false, status: 404 });
  click();
  await tick();
  eq(assigns.join(), "http://site.test/b", "404");
  eq(document.getElementById("l") != null, true, "page untouched");
  assigns.length = 0;
  serve("{}", { headers: { get: () => "application/json" } });
  click();
  await tick();
  eq(assigns.join(), "http://site.test/b", "json");
  assigns.length = 0;
  reply = () => { throw new Error("offline"); };
  click();
  await tick();
  eq(assigns.join(), "http://site.test/b", "fetch error");
  eq(pushes.length, 0, "no push");
});

await test("popstate navigates without pushing", async () => {
  reset("<p>old</p>");
  loc.href = "http://site.test/p";
  loc.pathname = "/p";
  serve(page("P", "<p id=pp>popped</p>"));
  window.dispatchEvent(new window.PopStateEvent("popstate"));
  await tick();
  eq(calls[0][0], "http://site.test/p", "fetched location");
  eq(document.getElementById("pp").textContent, "popped", "morphed");
  eq(document.title, "P", "title");
  eq(pushes.length, 0, "no push");
});

await test("the last navigation wins", async () => {
  reset(link("/b"));
  let slow;
  const html = (t) => ({ ok: true, status: 200, url: "", headers: { get: () => "text/html" }, text: async () => page(t, `<i id=${t}></i>`) });
  reply = (u) => u.endsWith("/b") ? new Promise((r) => { slow = () => r(html("B")); }) : html("C");
  click();
  document.getElementById("l").setAttribute("href", "/c");
  click();
  await tick();
  slow();
  await tick();
  eq(document.title, "C", "newest page shown");
  eq(pushes.length, 1, "one push");
});

await test("a new module script is imported once", async () => {
  globalThis.pageLoads = 0;
  const sc = `<script type="module" src="${modUrl}"></script>`;
  reset(link("/b"));
  serve(page("B", link("/c") + sc));
  click();
  await tick();
  eq(globalThis.pageLoads, 1, "imported");
  serve(page("C", link("/c") + sc));
  click();
  await tick();
  eq(globalThis.pageLoads, 1, "not again");
  // A script already in the page is not imported.
});

fs.rmSync(tmp, { recursive: true, force: true });
if (!process.exitCode) console.log(`nav_test: ${n} passed`);
