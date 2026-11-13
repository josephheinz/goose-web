// Driven by test/runtime.sh. Server push (Addendum 12 section 7.9): client/gwe.js against jsdom with a stub EventSource
// that records its instances. The store cases run on the compiled RCart store and RCartBadge/RCartButton components of a
// gweb gen (GW_DIR/_gw, with the real gwi.js, gwl.js and gws.js beside them); gwe.js is copied there from client/.
import fs from "node:fs";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM('<!doctype html><body><div id="feed" gw-sse="/e"><p id="a">one</p><p id="b">two</p></div><i gw-sse="/e"></i><i gw-sse="/f"></i><p id="out">x</p></body>', { url: "http://localhost/" });
const { window } = dom, document = window.document;
const instances = [];
class ES {
  constructor(url) { this.url = url; this.l = {}; instances.push(this); }
  addEventListener(t, f) { (this.l[t] ||= []).push(f); }
  emit(t, data) { (this.l[t] || []).forEach((f) => f({ data })); }
}
Object.assign(globalThis, { document, EventSource: ES, localStorage: window.localStorage, CustomEvent: window.CustomEvent, dispatchEvent: (e) => window.dispatchEvent(e) });
console.error = () => {};
let errors = [];
window.addEventListener("gw:error", (ev) => errors.push(ev.detail));

const dir = process.env.GW_DIR;
if (!dir) { console.log("sse_test: no GW_DIR (no ./gweb), so the store cases are not run"); }
const src = new URL("../client/", import.meta.url);
let base = dir;
if (!dir) {
  base = fs.mkdtempSync((process.env.TMPDIR || "/tmp") + "/gwe-");
  fs.writeFileSync(base + "/package.json", '{"type":"module"}');
  for (const f of ["gwi.js", "gws.js"]) fs.copyFileSync(new URL(f, src), base + "/" + f);
}
fs.copyFileSync(new URL("gwe.js", src), base + "/gwe.js");
const imp = (n) => import(pathToFileURL(`${base}/${n}.js`).href);
const G = await imp("gwi");
await imp("gwe");

const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${JSON.stringify(x)}, want ${JSON.stringify(y)}`); };
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const by = (u) => instances.filter((i) => i.url == u);

test("one EventSource per distinct gw-sse URL", () => {
  eq(instances.length, 2, "instances");
  eq(by("/e").length, 1, "/e once");
  eq(by("/f").length, 1, "/f once");
});

test("a fragment event morphs the target and keeps the unchanged nodes", () => {
  const a = document.getElementById("a"), b = document.getElementById("b");
  by("/e")[0].emit("fragment", 'feed\n<p id="a">one</p><p id="b">TWO</p>');
  eq(document.getElementById("a"), a, "p#a kept");
  eq(document.getElementById("b"), b, "p#b kept");
  eq(b.textContent, "TWO", "p#b updated");
  eq(a.textContent, "one", "p#a unchanged");
  eq(errors.length, 0, "no error");
});

test("a multi-line HTML payload works (lines as the browser joins them)", () => {
  by("/f")[0].emit("fragment", 'feed\n<ul>\n  <li>1</li>\n  <li>2</li>\n</ul>\n');
  eq(document.querySelectorAll("#feed li").length, 2, "two items");
  eq(document.getElementById("a"), null, "old content gone");
});

test("a fragment for a missing id, or an id inside a component, is ignored", () => {
  const before = document.body.innerHTML;
  by("/e")[0].emit("fragment", "nope\n<p>x</p>");
  by("/e")[0].emit("fragment", "feed");
  eq(document.body.innerHTML, before, "missing id");
  document.body.insertAdjacentHTML("beforeend", '<div data-component="C" id="cmp"><b id="deep">k</b></div><script type="application/json">{}<\/script>');
  by("/e")[0].emit("fragment", "cmp\n<b>changed</b>");
  by("/e")[0].emit("fragment", "deep\nchanged");
  eq(document.getElementById("deep").textContent, "k", "inside a component");
  eq(errors.length, 0, "no error");
});

test("unknown events are ignored", () => {
  const before = document.body.innerHTML;
  by("/e")[0].emit("message", "out\nchanged");
  by("/e")[0].emit("ping", "out\nchanged");
  eq(document.body.innerHTML, before, "unchanged");
});

test("a gw-sse element added later through a swap opens its stream once", () => {
  const out = document.getElementById("out");
  G.swap(out.parentNode, document.body.innerHTML.replace('<p id="out">', '<p id="out" gw-sse="/g">'));
  eq(by("/g").length, 1, "/g opened");
  G.swap(document.body, document.body.innerHTML);
  eq(by("/g").length, 1, "/g not opened again");
  eq(instances.length, 3, "three streams");
});

if (dir) {
  const { defs, state } = G;
  const Store = (await imp("RCart")).default;
  await imp("RCartBadge");
  await imp("RCartButton");
  const json = (s) => JSON.stringify(s).replace(/</g, "\\u003c");
  const server = (name) => {
    const def = defs[name], s = def.i({});
    return `<div data-component="${name}">${def.r(s)}</div><script type="application/json">${json(s)}</script>` +
      `<script type="application/json" data-store="RCart">${json(defs.RCart.i())}</script>`;
  };
  const text = (name) => document.querySelector(`[data-component="${name}"]`).textContent.trim();

  test("a store event updates the DOM of two subscribed components, and a store function still does", () => {
    document.body.innerHTML = '<div id="host" gw-sse="/s"></div>';
    errors = [];
    G.swap(document.getElementById("host"), server("RCartBadge") + server("RCartButton"));
    const es = by("/s")[0] || new ES("/s");
    eq(text("RCartBadge"), "items: 0, total 5, twice 0", "badge at start");
    es.emit("store", 'RCart\n{"count":9,"total":95}');
    eq(text("RCartBadge"), "items: 9, total 95, twice 18big cart", "badge");
    eq(text("RCartButton"), "buyclear0 clicks, 9 in cart", "button");
    eq(state(document.querySelector('[data-component="RCartBadge"]')).gw_RCart_count, 9, "the badge's copy");
    eq(JSON.parse(localStorage.getItem("rcart")).count, 9, "stored");
    es.emit("store", 'RCart\n{"count":0}');
    eq(text("RCartBadge"), "items: 0, total 95, twice 0", "only the named value changed");
    Store.add({ m() {} }, 2);
    eq(text("RCartButton"), "buyclear0 clicks, 1 in cart", "a function after a push");
    eq(errors.length, 0, "no error");
  });

  test("a store event for an unknown store, bad JSON or an unknown name is ignored or reported", () => {
    const es = by("/s")[0], before = document.body.innerHTML;
    es.emit("store", 'Nope\n{"count":5}');
    eq(document.body.innerHTML, before, "unknown store");
    es.emit("store", 'RCart\n{"zzz":5,"__proto__":{"count":4}}');
    eq(document.body.innerHTML, before, "unknown name");
    eq(errors.length, 0, "no error yet");
    es.emit("store", "RCart\n{oops");
    eq(errors.length, 1, "bad JSON goes to gw:error");
    eq(document.body.innerHTML, before, "and changes nothing");
  });
}

let pass = 0, fail = 0;
for (const [name, fn] of tests) {
  try { await fn(); pass++; console.log("PASS", name); }
  catch (err) { fail++; console.log("FAIL", name, "\n   ", String(err.stack || err).replaceAll("\n", "\n    ")); }
}
console.log(`\nsse: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
