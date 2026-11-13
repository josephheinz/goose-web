// Driven by test/reactive.sh. Shared stores (Addendum 12 section 7.7) through the compiled RCart store and the
// RCartBadge and RCartButton components of a gweb gen (GW_DIR/_gw, with the real gwi.js, gwl.js and gws.js beside
// them), in jsdom with a real localStorage. After each step every root's HTML is what a fresh render of its live
// state gives. The tests run in order and share the one store the modules hold.
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/" });
const { window } = dom, document = window.document;
Object.assign(globalThis, { document, localStorage: window.localStorage, CustomEvent: window.CustomEvent, dispatchEvent: (e) => window.dispatchEvent(e) });
console.error = () => {};
const dir = process.env.GW_DIR;
const imp = (n) => import(pathToFileURL(`${dir}/${n}.js`).href);
const G = await imp("gwi");

// What an earlier visit left in localStorage; the store reads it once, when the first component starts.
localStorage.setItem("rcart", JSON.stringify({ count: 7, total: 75, lines: [{ id: 1, qty: 7 }] }));
const Store = (await imp("RCart")).default;
await imp("RCartBadge");
await imp("RCartButton");
const { defs, state } = G;

let errors = [];
window.addEventListener("gw:error", (ev) => errors.push(ev.detail));
const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${JSON.stringify(x)}, want ${JSON.stringify(y)}`); };
const norm = (html) => {
  const t = document.createElement("div");
  t.innerHTML = html;
  for (const el of t.querySelectorAll("*")) {
    const a = [...el.attributes].map((x) => [x.name, x.value]).sort((p, q) => (p[0] < q[0] ? -1 : 1));
    for (const [k] of a) el.removeAttribute(k);
    for (const [k, v] of a) el.setAttribute(k, v);
  }
  return t.innerHTML;
};
const json = (s) => JSON.stringify(s).replace(/</g, "\\u003c");
const roots = () => [...document.querySelectorAll("[data-component]")];
const synced = (step) => {
  for (const r of roots()) eq(norm(r.innerHTML), norm(defs[r.dataset.component].r(state(r))), `${r.dataset.component}: innerHTML vs r(state) after ${step}`);
};
// The server's component(): the root, its state, and the initial state of the store it uses.
const server = (name) => {
  const def = defs[name], s = def.i({});
  return `<div data-component="${name}">${def.r(s)}</div><script type="application/json">${json(s)}</script>` +
    `<script type="application/json" data-store="RCart">${json(defs.RCart.i())}</script>`;
};
const page = (...names) => {
  document.body.innerHTML = '<div id="host"></div>';
  G.swap(document.getElementById("host"), names.map(server).join(""));
  errors = [];
  return document.getElementById("host");
};
const text = (name) => document.querySelector(`[data-component="${name}"]`).textContent.trim();
const btn = (label) => [...document.querySelectorAll("button")].find((b) => b.textContent === label);
const saved = () => JSON.parse(localStorage.getItem("rcart"));

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("localStorage is restored when the components start, over the server's initial state", () => {
  page("RCartBadge", "RCartButton");
  eq(text("RCartBadge"), "items: 7, total 75, twice 14big cart", "badge");
  eq(text("RCartButton"), "buyclear0 clicks, 7 in cart", "button");
  eq(document.querySelector("b")?.textContent, "big cart", "the {#if} block");
  eq(document.querySelector("p").className, "big", "the attribute part");
  synced("start");
  eq(errors.length, 0, "no error");
});

test("a click in one component updates the other, and localStorage follows", () => {
  const p = page("RCartBadge", "RCartButton");
  const badge = p.querySelector('[data-component="RCartBadge"]'), button = p.querySelector('[data-component="RCartButton"]');
  const mo = new window.MutationObserver(() => {});
  mo.observe(badge, { subtree: true, characterData: true, childList: true, attributes: true });
  btn("buy").click();
  eq(text("RCartBadge"), "items: 8, total 105, twice 16big cart", "badge after one buy");
  eq(text("RCartButton"), "buyclear1 clicks, 8 in cart", "button after one buy");
  eq(state(button).clicks, 1, "the button's own state");
  eq(state(badge).gw_RCart_count, 8, "the badge's copy");
  eq(saved().count, 8, "stored count");
  eq(saved().total, 105, "stored total");
  eq(saved().lines.length, 2, "stored lines (not readable by components, still kept)");
  eq(mo.takeRecords().length > 0, true, "the badge's DOM was written");
  synced("one buy");
  btn("buy").click();
  btn("buy").click();
  eq(text("RCartBadge"), "items: 10, total 165, twice 20big cart", "badge after three buys");
  synced("three buys");
  eq(errors.length, 0, "no error");
});

test("a store function that changes nothing notifies nobody; clear writes every name back", () => {
  const p = page("RCartBadge", "RCartButton");
  const badge = p.querySelector('[data-component="RCartBadge"]');
  btn("clear").click();
  eq(text("RCartBadge"), "items: 0, total 5, twice 0", "badge cleared");
  eq(document.querySelector("b"), null, "the {#if} block left");
  eq(document.querySelector("p").className, "small", "the attribute part followed");
  eq(saved().count, 0, "stored");
  const mo = new window.MutationObserver(() => {});
  mo.observe(badge, { subtree: true, characterData: true, childList: true, attributes: true });
  btn("clear").click();
  eq(mo.takeRecords().length, 0, "clearing an empty cart writes nothing");
  synced("clear");
  eq(errors.length, 0, "no error");
});

test("a component that starts later takes the store's current values; one that left stops following", () => {
  page("RCartButton");
  btn("buy").click();
  eq(saved().count, 1, "one in the store");
  const host = document.getElementById("host");
  G.swap(host, host.innerHTML + server("RCartBadge"));
  eq(text("RCartBadge"), "items: 1, total 35, twice 2", "a new root starts from the store, not from the page's initial state");
  synced("late start");
  host.querySelector('[data-component="RCartBadge"]').remove();
  btn("buy").click();
  eq(text("RCartButton"), "buyclear2 clicks, 2 in cart", "the remaining component");
  const c = { m() {}, r: null };
  Store.add(c, 5);
  eq(state(document.querySelector('[data-component="RCartButton"]')).gw_RCart_count, 3, "a call from outside any component reaches the others");
  synced("after leaving");
  eq(errors.length, 0, "no error");
});

let pass = 0, fail = 0;
for (const [name, fn] of tests) {
  try { await fn(); pass++; console.log("PASS", name); }
  catch (err) { fail++; console.log("FAIL", name, "\n   ", String(err.stack || err).replaceAll("\n", "\n    ")); }
}
console.log(`\nstore_dom: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
