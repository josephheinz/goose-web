// Driven by test/reactive.sh. Loads client/gwi.js into jsdom and runs hand-written defs shaped like
// DESIGN-ADDENDUM-12 section 3.3 (what the compiler will emit): r renders with <!--g--> markers, u(s, m)
// returns the apply closure, h handlers take (s, c, ...args) and call c.m(bit).
import fs from "node:fs";
import { createRequire } from "node:module";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><body></body>");
const { window } = dom, document = window.document;
Object.assign(globalThis, { document, CustomEvent: window.CustomEvent, dispatchEvent: (e) => window.dispatchEvent(e) });
console.error = () => {};
const src = fs.readFileSync(new URL("../client/gwi.js", import.meta.url), "utf8");
const G = await import("data:text/javascript;base64," + Buffer.from(src).toString("base64"));
const { component: C, esc: e, T, A, B, state, swap } = G;

let errors = [];
window.addEventListener("gw:error", (ev) => errors.push(ev.detail));

const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${JSON.stringify(x)}, want ${JSON.stringify(y)}`); };
const tick = () => new Promise((r) => setTimeout(r, 0));
let n = 0;
// Registers def under a fresh name and puts its server render plus the state script on the page.
function mount(def, s) {
  const name = "T" + ++n;
  C(name, def);
  document.body.innerHTML = `<div data-component="${name}">${def.r(s)}</div><script type="application/json">${JSON.stringify(s)}</script>`;
  errors = [];
  return document.body.firstChild;
}
const click = (el) => el.click();
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }));
// Every case ends here: the live DOM is what a fresh render of the live state gives.
const synced = (root, def) => eq(root.innerHTML, def.r(state(root)), "innerHTML vs r(state)");

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("1 counter: only the dirty text node is written", () => {
  const def = {
    r: (s) => `<p><!--g-->${e(s.label)}<!---->: <!--g-->${s.count}<!----></p><button data-on-click="inc">+</button>`,
    u(s, m) {
      const a = m & 1 && "" + s.label, b = m & 2 && "" + s.count;
      return (p) => { m & 1 && T(p[0], a); m & 2 && T(p[1], b); };
    },
    h: { inc(s, c) { s.count++; c.m(2); } },
    b: { label: 1, count: 2 },
  };
  const root = mount(def, { label: "Hits", count: 0 });
  const p = root.firstChild, label = p.childNodes[1], count = p.childNodes[5];
  eq(count.data, "0", "count before");
  const mo = new window.MutationObserver(() => {});
  mo.observe(root, { subtree: true, characterData: true, childList: true, attributes: true });
  click(root.lastChild);
  const rec = mo.takeRecords();
  eq(rec.length, 1, "one mutation");
  eq(rec[0].target, count, "the count node");
  eq(p.childNodes[1], label, "label node identity");
  eq(p.childNodes[5], count, "count node identity");
  eq(count.data, "1", "count after");
  click(root.lastChild);
  eq(count.data, "2", "count again");
  synced(root, def);
});

test("2 attribute parts and the focus rule", () => {
  const def = {
    r: (s) => `<!--g--><div class="${s.on ? "a on" : "a"}"></div><!--g--><input data-bind="q" data-cap="20" value="${e(s.q)}">` +
      `<button data-on-click="touch">t</button><button data-on-click="reset">r</button><button data-on-click="flip">f</button>`,
    u(s, m) {
      const a = m & 1 && `class="${s.on ? "a on" : "a"}"`, b = m & 2 && `data-bind="q" data-cap="20" value="${e(s.q)}"`;
      return (p, r, f) => { m & 1 && A(p[0], a, f); m & 2 && A(p[1], b, f); };
    },
    h: {
      touch(s, c) { c.m(2); },
      reset(s, c) { s.q = "reset"; c.m(2); },
      flip(s, c) { s.on = !s.on; c.m(1); },
    },
    b: { on: 1, q: 2 },
  };
  const root = mount(def, { on: false, q: "" });
  const div = root.children[0], input = root.children[1];
  click(root.children[4]);
  eq(div.className, "a on", "class");
  eq(root.children[0], div, "div identity");
  // A bound input updates state through the listener.
  input.value = "hi";
  fire(input, "input");
  eq(state(root).q, "hi", "bound state");
  eq(root.children[1], input, "input identity");
  // Focused, state did not move after bind: typed text survives a re-render of its part.
  input.focus();
  input.value = "typed";
  click(root.children[2]);
  eq(document.activeElement, input, "still focused");
  eq(input.value, "typed", "typed text kept");
  // State moved after bind: the new value wins.
  click(root.children[3]);
  eq(input.value, "reset", "state moved");
  eq(root.children[1], input, "input identity at end");
  synced(root, def);
});

test("3 block parts: if and keyed for", () => {
  const li = (t) => `<li gw-key="${t.id}">${e(t.t)}</li>`;
  const def = {
    r: (s) => `<!--g-->${s.show ? '<p gw-key="msg">hi</p>' : ""}<!--/g--><ul><!--g-->${s.items.map(li).join("")}<!--/g--></ul>` +
      `<button data-on-click="toggle">t</button><button data-on-click="rev">r</button>`,
    u(s, m) {
      const a = m & 1 && (s.show ? '<p gw-key="msg">hi</p>' : ""), b = m & 2 && s.items.map(li).join("");
      return (p, r, f) => { m & 1 && B(p[0], a, f); m & 2 && B(p[1], b, f); };
    },
    h: {
      toggle(s, c) { s.show = !s.show; c.m(1); },
      rev(s, c) { s.items.reverse(); c.m(2); },
    },
    b: { show: 1, items: 2 },
  };
  const root = mount(def, { show: false, items: [{ id: 1, t: "a" }, { id: 2, t: "b" }, { id: 3, t: "c" }] });
  const ul = root.querySelector("ul"), [a, b, c] = ul.children, [tog, rev] = root.querySelectorAll("button");
  eq(root.querySelector("p"), null, "hidden");
  click(tog);
  const p = root.querySelector("p");
  eq(p && p.textContent, "hi", "shown");
  eq(root.querySelector("ul"), ul, "ul untouched");
  click(rev);
  eq([...ul.children].map((x) => x.textContent).join(""), "cba", "reversed");
  eq(ul.children[0], c, "c identity"); eq(ul.children[1], b, "b identity"); eq(ul.children[2], a, "a identity");
  click(tog);
  eq(root.querySelector("p"), null, "hidden again");
  eq(root.querySelector("button"), tog, "button identity");
  synced(root, def);
});

test("4 phase-1 throw leaves state and DOM alone", () => {
  const def = {
    r: (s) => `<p><!--g-->${s.n}<!----></p><button data-on-click="inc">+</button>`,
    u(s, m) {
      const a = m & 1 && "" + s.n;
      if (s.n >= 2) throw new Error("boom");
      return (p) => { m & 1 && T(p[0], a); };
    },
    h: { inc(s, c) { s.n++; c.m(1); } },
    b: { n: 1 },
  };
  const root = mount(def, { n: 0 });
  click(root.lastChild);
  eq(errors.length, 0, "no error yet");
  const html = root.innerHTML;
  click(root.lastChild);
  eq(state(root).n, 1, "state restored");
  eq(root.innerHTML, html, "DOM unchanged");
  eq(errors.length, 1, "one gw:error");
  synced(root, def);
});

test("5 async rejection restores only the handler's x bits", async () => {
  let reject;
  const def = {
    r: (s) => `<p><!--g-->${s.a}<!----></p><p><!--g-->${s.b}<!----></p><button data-on-click="load">l</button><button data-on-click="bump">b</button>`,
    u(s, m) {
      const a = m & 1 && "" + s.a, b = m & 2 && "" + s.b;
      return (p) => { m & 1 && T(p[0], a); m & 2 && T(p[1], b); };
    },
    h: {
      load(s, c) { s.a = 1; c.m(1); return new Promise((_, rej) => { reject = rej; }); },
      bump(s, c) { s.b++; c.m(2); },
    },
    b: { a: 1, b: 2 },
    x: { load: 1 },
  };
  const root = mount(def, { a: 0, b: 0 });
  const [pa, pb] = root.querySelectorAll("p"), [load, bump] = root.querySelectorAll("button");
  click(load);
  eq(pa.textContent, "1", "a shown");
  click(bump);
  eq(pb.textContent, "1", "b shown");
  reject(new Error("net"));
  await tick();
  eq(state(root).a, 0, "a restored");
  eq(state(root).b, 1, "b kept");
  eq(pa.textContent, "0", "DOM shows the rollback");
  eq(pb.textContent, "1", "b still shown");
  eq(errors.length, 1, "one gw:error");
  synced(root, def);
});

test("5b async resolve flushes once more", async () => {
  let done;
  const def = {
    r: (s) => `<p><!--g-->${s.a}<!----></p><button data-on-click="go">g</button>`,
    u(s, m) { const a = m & 1 && "" + s.a; return (p) => { m & 1 && T(p[0], a); }; },
    h: { go(s, c) { return new Promise((r) => { done = () => { s.a = 5; c.m(1); r(); }; }); } },
    b: { a: 1 },
    x: { go: 1 },
  };
  const root = mount(def, { a: 0 });
  click(root.lastChild);
  done();
  await tick();
  eq(root.firstChild.textContent, "5", "shown after resolve");
  eq(errors.length, 0, "no error");
  synced(root, def);
});

test("6 watches run on their bits; a watch that always marks stops after 8 rounds", () => {
  const seen = [];
  const def = {
    r: (s) => `<p><!--g-->${s.x}<!----></p><button data-on-click="incx">x</button><button data-on-click="incy">y</button><button data-on-click="nop">n</button>`,
    u(s, m) { const a = m & 1 && "" + s.x; return (p) => { m & 1 && T(p[0], a); }; },
    w(s, m) { if (m & 1) seen.push("x"); if (m & 2) seen.push("y"); },
    h: { incx(s, c) { s.x++; c.m(1); }, incy(s, c) { s.y++; c.m(2); }, nop() {} },
    b: { x: 1, y: 2 },
  };
  const root = mount(def, { x: 0, y: 0 });
  const [bx, by, bn] = root.querySelectorAll("button");
  click(bx); click(by); click(bn);
  eq(seen.join(""), "xy", "watch bits");
  synced(root, def);

  let calls = 0;
  const loop = {
    r: (s) => `<p><!--g-->${s.x}<!----></p><button data-on-click="go">g</button>`,
    u(s, m) { const a = m & 1 && "" + s.x; return (p) => { m & 1 && T(p[0], a); }; },
    w(s, m, c) { calls++; s.x++; c.m(1); },
    h: { go(s, c) { c.m(1); } },
    b: { x: 1 },
  };
  const r2 = mount(loop, { x: 0 });
  click(r2.lastChild);
  eq(calls, 8, "rounds");
  eq(errors.length, 1, "one gw:error");
  eq(errors[0], "watch loop in T" + n, "message");
  // The last round's watch write is not flushed: the loop is reported instead, so no sync check here.
});

test("6b a throwing watch reports and keeps the DOM result", () => {
  const def = {
    r: (s) => `<p><!--g-->${s.x}<!----></p><button data-on-click="inc">+</button>`,
    u(s, m) { const a = m & 1 && "" + s.x; return (p) => { m & 1 && T(p[0], a); }; },
    w() { throw new Error("watch"); },
    h: { inc(s, c) { s.x++; c.m(1); } },
    b: { x: 1 },
  };
  const root = mount(def, { x: 0 });
  click(root.lastChild);
  eq(state(root).x, 1, "state kept");
  eq(errors.length, 1, "one gw:error");
  synced(root, def);
});

test("7 legacy def (render, u, h as the compiler emits them) updates through swap", () => {
  const def = {
    r: (s) => `<p>${s.n}</p><button data-on-click="inc" data-args="[2]">+</button>`,
    render: (s) => def.r(s),
    u: (s) => { const m = def.render(s); return (p, r, f) => swap(r, m, f); },
    h: { inc: (s, c, ...a) => def.handlers.inc(s, ...a) },
    handlers: { inc(s, k) { s.n += k; } },
  };
  const root = mount(def, { n: 0 });
  const btn = root.lastChild;
  click(btn);
  eq(root.firstChild.textContent, "2", "text");
  eq(root.lastChild, btn, "button identity");
  eq(errors.length, 0, "no error");
  synced(root, def);
});

test("8 empty text value then non-empty", () => {
  const def = {
    r: (s) => `<p><!--g-->${e(s.t)}<!----></p><button data-on-click="set" data-args="[&quot;hi&quot;]">s</button><button data-on-click="set" data-args="[&quot;&quot;]">c</button>`,
    u(s, m) { const a = m & 1 && "" + s.t; return (p) => { m & 1 && T(p[0], a); }; },
    h: { set(s, c, v) { s.t = v; c.m(1); } },
    b: { t: 1 },
  };
  const root = mount(def, { t: "" });
  const [set, clear] = root.querySelectorAll("button");
  eq(root.firstChild.textContent, "", "empty");
  click(set);
  eq(root.firstChild.textContent, "hi", "inserted");
  synced(root, def);
  click(set);
  click(clear);
  eq(root.firstChild.textContent, "", "cleared");
  synced(root, def);
});

test("8b empty text part last in its element (no end marker)", () => {
  const def = {
    r: (s) => `<p>a <!--g-->${e(s.t)}</p><button data-on-click="set" data-args="[&quot;hi&quot;]">s</button>`,
    u(s, m) { const a = m & 1 && "" + s.t; return (p) => { m & 1 && T(p[0], a); }; },
    h: { set(s, c, v) { s.t = v; c.m(1); } },
    b: { t: 1 },
  };
  const root = mount(def, { t: "" });
  click(root.querySelector("button"));
  eq(errors.length, 0, "no error");
  eq(root.firstChild.textContent, "a hi", "inserted");
  synced(root, def);
});

let pass = 0, fail = 0;
for (const [name, fn] of tests) {
  try { await fn(); pass++; console.log("PASS", name); }
  catch (err) { fail++; console.log("FAIL", name, "\n   ", String(err.stack || err).replaceAll("\n", "\n    ")); }
}
console.log(`\nreactive.sh: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
