// Driven by test/runtime.sh. Runs client/gwt.js (gw-enter / gw-leave, DESIGN-ADDENDUM-12 item 11) with gwi.js's
// morph against jsdom, stubbed timers and getComputedStyle, and dispatched animationend / transitionend events.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><body></body>");
const { window } = dom, document = window.document;
let timers = [], frames = [], dur = "0.3s";
Object.assign(globalThis, {
  document, CustomEvent: window.CustomEvent, dispatchEvent: (e) => window.dispatchEvent(e),
  setTimeout: (f, ms) => { timers.push([f, ms]); return timers.length; },
  requestAnimationFrame: (f) => frames.push(f),
  getComputedStyle: () => ({ animationDuration: dur, transitionDuration: "0s" }),
});
console.error = () => {};
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "gwt-"));
fs.writeFileSync(tmp + "/package.json", '{"type":"module"}');
for (const f of ["gwi.js", "gwt.js"]) fs.copyFileSync(new URL("../client/" + f, import.meta.url), tmp + "/" + f);
const G = await import(pathToFileURL(tmp + "/gwi.js").href);
await import(pathToFileURL(tmp + "/gwt.js").href);

const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${JSON.stringify(x)}, want ${JSON.stringify(y)}`); };
const li = (k, extra = "") => `<li gw-key="${k}" gw-enter="in" gw-leave="out"${extra}>${k}</li>`;
const render = (ul, h) => G.swap(ul, h, 0);
const setup = (h) => { document.body.innerHTML = "<ul></ul>"; timers = []; frames = []; dur = "0.3s"; const ul = document.body.firstChild; ul.innerHTML = h; return ul; };
const ev = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }));
let n = 0;
const test = async (name, f) => { try { await f(); n++; } catch (e) { console.log("FAIL transition: " + name + ": " + e.message); process.exitCode = 1; } };

await test("enter: class added, removed on animationend", () => {
  const ul = setup(li("a"));
  render(ul, li("a") + li("b"));
  const b = ul.children[1];
  eq(b.className, "in", "class on insert");
  eq(ul.children[0].className, "", "existing child untouched");
  ev(b, "animationend");
  eq(b.className, "", "class removed");
  eq(timers.length, 1, "fallback timer armed");
});

await test("enter: a child's end event is ignored; fallback timer removes the class", () => {
  const ul = setup("");
  render(ul, "<li gw-key=a gw-enter=in><b>x</b></li>");
  const a = ul.firstChild;
  ev(a.firstChild, "animationend");
  eq(a.className, "in", "still there");
  timers[0][0]();
  eq(a.className, "", "removed by timer");
  eq(timers[0][1], 1000, "1 s");
});

await test("enter: no running animation removes the class next frame", () => {
  const ul = setup("");
  dur = "0s";
  render(ul, li("a"));
  eq(ul.firstChild.className, "in", "added");
  frames[0]();
  eq(ul.firstChild.className, "", "removed");
});

await test("leave: kept with class and gw-leaving until transitionend", () => {
  const ul = setup(li("a") + li("b"));
  render(ul, li("b"));
  const a = ul.children[0];
  eq(a.textContent, "a", "a kept");
  eq(a.className, "out", "leave class");
  eq(a.hasAttribute("gw-leaving"), true, "gw-leaving");
  eq(ul.children.length, 2, "both present");
  ev(a, "transitionend");
  eq(a.isConnected, false, "gone");
  eq(ul.children.length, 1, "one left");
});

await test("leave: fallback timeout removes it", () => {
  const ul = setup(li("a"));
  render(ul, "");
  const a = ul.firstChild;
  eq(a.isConnected, true, "kept");
  timers[0][0]();
  eq(a.isConnected, false, "removed by timer");
});

await test("leave: nothing animating removes it next frame", () => {
  const ul = setup(li("a"));
  dur = "0s";
  render(ul, "");
  frames[0]();
  eq(ul.children.length, 0, "gone");
});

await test("leave: a re-add of the same key builds a new element; the leaving one still goes", () => {
  const ul = setup(li("a"));
  render(ul, "");
  const old = ul.firstChild;
  render(ul, li("a"));
  const fresh = [...ul.children].filter((c) => c != old);
  eq(fresh.length, 1, "one new element");
  eq(fresh[0].className, "in", "new one enters");
  eq(fresh[0].hasAttribute("gw-leaving"), false, "new one is not leaving");
  eq(old.isConnected, false, "the next morph removes the leaving one at once");
  // Without another morph, the leaving one goes at its end event.
  const ul2 = setup(li("a"));
  render(ul2, "");
  const gone = ul2.firstChild;
  ev(gone, "transitionend");
  eq(gone.isConnected, false, "gone at the end event");
  ev(gone, "transitionend");
});

await test("leave: a second morph removes a leaving node at once", () => {
  const ul = setup(li("a") + li("b"));
  render(ul, li("b"));
  const a = ul.firstChild;
  render(ul, li("b"));
  eq(a.isConnected, false, "removed");
  eq(ul.children.length, 1, "b stays");
});

await test("non-keyed and attribute-less elements are unaffected", () => {
  const ul = setup("<li>x</li>");
  render(ul, "<li>x</li><li gw-enter=in>y</li>");
  eq(ul.children[1].className, "", "unkeyed gw-enter: no hook");
  render(ul, "<li gw-key=k>z</li>");
  eq(ul.children.length, 1, "removed outright");
  eq(ul.firstChild.textContent, "z", "kept new");
  render(ul, "");
  eq(ul.children.length, 0, "keyed without gw-leave is removed at once");
  eq(timers.length, 0, "no timers");
});

fs.rmSync(tmp, { recursive: true, force: true });
if (!process.exitCode) console.log(`transition_test: ${n} passed`);
