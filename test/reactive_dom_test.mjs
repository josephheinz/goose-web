// Driven by test/reactive.sh. Loads the compiled R*.gshtml modules of a gweb gen (GW_DIR/_gw, with the real
// gwi.js beside them) into jsdom, mounts each as the server writes it, dispatches real events through
// gwi.js, and after every step checks that the root's HTML is what a fresh render of the live state gives
// (compared as the HTML parser sees them, so entity spellings do not matter).
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><body></body>");
const { window } = dom, document = window.document;
Object.assign(globalThis, { document, CustomEvent: window.CustomEvent, dispatchEvent: (e) => window.dispatchEvent(e) });
console.error = () => {};
const dir = process.env.GW_DIR;
const G = await import(pathToFileURL(dir + "/gwi.js").href);
const { defs, state, hooks } = G;
for (const n of ["RCounter", "RParts", "RComputed", "RWatch", "RStruct", "RFetch", "RClock", "RClockAsync", "REvents", "RNestChild", "RNest", "RNestEventChild", "RNestEvent"]) await import(pathToFileURL(`${dir}/${n}.js`).href);

let errors = [];
window.addEventListener("gw:error", (ev) => errors.push(ev.detail));

const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${JSON.stringify(x)}, want ${JSON.stringify(y)}`); };
// The HTML as the parser sees it, with each element's attributes in name order (patching keeps the old order).
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
const synced = (root, name, step) => eq(norm(root.innerHTML), norm(defs[name].r(state(root))), `${name}: innerHTML vs r(state) after ${step}`);
const json = (s) => JSON.stringify(s).replace(/</g, "\\u003c");

// The page as the server writes it: the root, its render, the state as JSON.
function mount(name, props) {
  const def = defs[name], s = def.i(props);
  document.body.innerHTML = `<div data-component="${name}">${def.r(s)}</div><script type="application/json">${json(s)}</script>`;
  errors = [];
  const root = document.body.firstChild;
  synced(root, name, "mount");
  return root;
}
const click = (el) => el.click();
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }));
const btn = (root, text) => [...root.querySelectorAll("button")].find((b) => b.textContent === text);
const nodesOf = (root) => { const r = []; const w = document.createTreeWalker(root, 4 | 128); for (let n; (n = w.nextNode());) r.push(n); return r; };

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("RCounter: clicks write only the dirty text nodes", () => {
  const root = mount("RCounter", { start: 3, label: "Hi, <there>", step: 2 });
  const b = root.firstChild, before = nodesOf(root);
  eq(b.textContent, "Hi, <there>: 3 x 2 = 6", "first text");
  const mo = new window.MutationObserver(() => {});
  mo.observe(root, { subtree: true, characterData: true, childList: true, attributes: true });
  click(b);
  const rec = mo.takeRecords();
  eq(rec.length, 2, "two text writes (count and doubled)");
  eq(b.textContent, "Hi, <there>: 5 x 2 = 10", "after one click");
  eq(root.firstChild, b, "button identity");
  eq(nodesOf(root).filter((n, i) => n !== before[i]).length, 0, "no node replaced");
  synced(root, "RCounter", "click");
  click(b); click(b);
  eq(state(root).count, 9, "state");
  eq(state(root).doubled, 18, "computed");
  synced(root, "RCounter", "three clicks");
  eq(errors.length, 0, "no error");
});

test("RParts: bind, attribute, block and raw parts through real events", () => {
  const root = mount("RParts", { title: "T<é>&\"'" });
  const input = root.querySelector("input");
  // bind:value: typing writes the state; the attribute part follows; the control stays.
  input.focus();
  input.value = "a<b & \"c\" 'd' é";
  fire(input, "input");
  eq(state(root).draft, "a<b & \"c\" 'd' é", "bound state");
  eq(root.querySelector("input"), input, "input identity");
  eq(input.value, "a<b & \"c\" 'd' é", "typed text kept");
  synced(root, "RParts", "typing");
  click(btn(root, "add"));
  eq(root.querySelectorAll("li").length, 1, "one item");
  synced(root, "RParts", "add");
  input.value = "two";
  fire(input, "input");
  click(btn(root, "add"));
  const lis = [...root.querySelectorAll("li")];
  eq(lis.length, 2, "two items");
  eq(lis[1].querySelector("button").textContent, "two", "second name");
  synced(root, "RParts", "add again");
  // A block part: the if swaps; the list keeps its elements.
  click(btn(root, "false"));
  eq(root.querySelector("em").textContent.startsWith("on, big is 20"), true, "if branch");
  eq(root.querySelector("h1").className, "hot", "attribute part");
  eq([...root.querySelectorAll("li")][0], lis[0], "li identity across the if");
  synced(root, "RParts", "flip");
  // toggle(i) and drop(i): arguments come from the data-args of a part.
  click(lis[0].querySelector("button"));
  eq(lis[0].className, "done", "toggled");
  synced(root, "RParts", "toggle");
  click(lis[0].querySelectorAll("button")[1]);
  eq(root.querySelectorAll("li").length, 1, "dropped");
  eq(root.querySelector("li"), lis[1], "keyed survivor identity");
  eq(root.querySelector("li button").getAttribute("data-args"), "[0]", "its argument follows its place");
  synced(root, "RParts", "drop");
  click(btn(root, "shout"));
  eq(root.querySelector("div i").textContent, "x", "raw part");
  eq(root.querySelector("p").textContent.includes("<&>\"'"), true, "text part is escaped text");
  synced(root, "RParts", "shout");
  eq(errors.length, 0, "no error");
});

test("RComputed: a chain recomputed in order", () => {
  const root = mount("RComputed", { base: 100 });
  eq(root.querySelector("p").textContent, "106 107 111", "initial (c1 c2 c3)");
  click(btn(root, "+5"));
  eq(root.querySelector("p").textContent, "121 122 136", "after +5");
  synced(root, "RComputed", "click");
  eq(errors.length, 0, "no error");
});

test("RWatch: the watch writes state and the DOM follows", () => {
  const root = mount("RWatch", {});
  for (let i = 0; i < 4; i++) click(btn(root, "+"));
  const s = state(root);
  eq(s.tenfold, 40, "written by the watch");
  eq(s.big, true, "second watch");
  eq(root.querySelector("p").textContent, "4 40 true", "shown");
  synced(root, "RWatch", "four clicks");
  eq(errors.length, 0, "no error");
});

test("RStruct: struct and array state under gw-key", () => {
  const root = mount("RStruct", {});
  eq(root.querySelector("p").textContent, "1,2 d=3", "initial");
  click(btn(root, "right"));
  eq(root.querySelector("p").textContent, "3,2 d=5", "after shift(2)");
  click(btn(root, "add"));
  click(btn(root, "add"));
  const lis = [...root.querySelectorAll("li")];
  eq(lis.length, 2, "two rows");
  synced(root, "RStruct", "adds");
  click(btn(root, "nudge"));
  eq(state(root).rows[0].at.y, 9, "write into contents");
  eq(root.querySelectorAll("li")[0].textContent.includes("3/9"), true, "shown");
  synced(root, "RStruct", "nudge");
  click(root.querySelectorAll("li button")[0]);
  eq(root.querySelectorAll("li").length, 1, "one row left");
  synced(root, "RStruct", "drop");
  eq(errors.length, 0, "no error");
});

// ---- RFetch: typed fetch through gwh.js against a stubbed fetch. Each call waits until the test answers it.
const tick = () => new Promise((r) => setTimeout(r, 0));
let calls = [];
globalThis.fetch = (u, o) => new Promise((resolve) => {
  calls.push({ u, o, answer: (status, body) => resolve({ ok: status >= 200 && status < 300, status, json: async () => body }) });
});
const nodeText = (root) => root.querySelector("p").textContent;

test("RFetch: a reply is decoded into state and shown; the flag set before the wait shows first", async () => {
  calls = [];
  const root = mount("RFetch", {});
  click(btn(root, "load"));
  eq(calls.length, 1, "one request");
  eq(calls[0].u, "/api/items", "its url");
  eq(nodeText(root).startsWith("loading"), true, "loading is in the DOM before the fetch resolves");
  eq(root.querySelector("p").className, "wait", "attribute part too");
  synced(root, "RFetch", "before the reply");
  calls[0].answer(200, [{ id: 3, title: "a<b>", done: false, extra: 1 }, { id: 4, title: "é", done: true }]);
  await tick();
  eq(state(root).items.length, 2, "two items");
  eq(Object.keys(state(root).items[0]).join(), "id,title,done", "extra keys are dropped");
  eq(root.querySelectorAll("li").length, 2, "shown");
  eq(nodeText(root).startsWith("ready"), true, "loading cleared");
  synced(root, "RFetch", "after the reply");
  eq(errors.length, 0, "no error");
});

test("RFetch: an int and a bool reply; a post with a reply, the CSRF header and the body", async () => {
  calls = [];
  const root = mount("RFetch", {});
  click(btn(root, "refresh"));
  eq(calls[0].u, "/api/count", "first get");
  calls[0].answer(200, 7);
  await tick();
  eq(state(root).count, 7, "count");
  eq(calls.length, 2, "second get after the first");
  calls[1].answer(200, true);
  await tick();
  eq(state(root).busy, true, "bool");
  synced(root, "RFetch", "refresh");
  // add: no token on the page, then one.
  click(btn(root, "add"));
  eq(root.querySelectorAll("li").length, 1, "optimistic row shows at once");
  const c = calls[2];
  eq(c.o.method, "POST", "post");
  eq(c.o.headers["Content-Type"], "application/json", "json");
  eq("X-CSRF-Token" in c.o.headers, false, "no token, no header");
  eq(c.o.body, '{"id":1,"title":"new","done":false}', "body");
  c.answer(200, { ok: true, note: "saved" });
  await tick();
  eq(state(root).note, "saved", "reply read");
  eq(root.querySelectorAll("li").length, 1, "row stays");
  synced(root, "RFetch", "saved");
  document.body.insertAdjacentHTML("beforeend", '<input type="hidden" name="_csrf" value="tok123">');
  click(btn(root, "add"));
  eq(calls[3].o.headers["X-CSRF-Token"], "tok123", "token from the page");
  calls[3].answer(200, { ok: true, note: "again" });
  await tick();
  eq(errors.length, 0, "no error");
});

test("RFetch: a status error rolls back the handler's writes; another handler's write in between survives", async () => {
  calls = [];
  const root = mount("RFetch", {});
  click(btn(root, "add"));
  eq(root.querySelectorAll("li").length, 1, "optimistic push shows");
  click(btn(root, "mark"));
  eq(state(root).busy, true, "other handler wrote");
  eq(nodeText(root).includes("true"), true, "and it shows");
  calls[0].answer(500, {});
  await tick();
  eq(state(root).items.length, 0, "push rolled back");
  eq(root.querySelectorAll("li").length, 0, "row gone from the DOM");
  eq(state(root).busy, true, "the other handler's write survived");
  eq(nodeText(root).includes("true"), true, "still shown");
  eq(errors.length, 1, "one gw:error");
  eq(errors[0].includes("500 from /api/items"), true, "its text: " + errors[0]);
  synced(root, "RFetch", "rollback");
});

test("RFetch: a bad reply rolls back, names the path, raises one gw:error", async () => {
  calls = [];
  const root = mount("RFetch", {});
  click(btn(root, "load"));
  eq(nodeText(root).startsWith("loading"), true, "loading shown");
  calls[0].answer(200, [{ id: 1, title: "ok", done: false }, { id: 2, title: 5, done: false }]);
  await tick();
  eq(errors.length, 1, "one gw:error");
  eq(errors[0].includes("bad reply from /api/items at [1].title"), true, "path: " + errors[0]);
  eq(state(root).items.length, 0, "nothing assigned");
  eq(state(root).loading, false, "flag restored");
  eq(nodeText(root).startsWith("ready"), true, "and shown");
  synced(root, "RFetch", "bad reply");
  // Other mismatches: root type, missing field, long string, float, big int.
  const bad = async (body, at) => {
    errors = [];
    calls = [];
    click(btn(root, "load"));
    calls[0].answer(200, body);
    await tick();
    eq(errors.length, 1, "error for " + JSON.stringify(body));
    eq(errors[0].endsWith("at " + at), true, `${JSON.stringify(body)}: ${errors[0]}`);
  };
  await bad({ id: 1 }, "");
  await bad([{ id: 1, done: false }], "[0].title");
  await bad([{ id: 1.5, title: "x", done: false }], "[0].id");
  await bad([{ id: 2 ** 60, title: "x", done: false }], "[0].id");
  await bad([{ id: 1, title: "x".repeat(25), done: false }], "[0].title");
  await bad([{ id: 1, title: "é".repeat(13), done: false }], "[0].title");
  await bad([{ id: 1, title: "x", done: 1 }], "[0].done");
  await bad([null], "[0]");
  errors = [];
  calls = [];
  click(btn(root, "refresh"));
  calls[0].answer(200, "7");
  await tick();
  eq(errors.length, 1, "string for an int");
  eq(state(root).count, 0, "count untouched");
});

test("RFetch: async propagates; a post without a decoder ignores the body", async () => {
  calls = [];
  const root = mount("RFetch", {});
  click(btn(root, "both"));
  eq(calls[0].u, "/api/items", "load first");
  calls[0].answer(200, [{ id: 9, title: "n", done: false }]);
  await tick();
  eq(calls.length, 2, "then ping");
  eq(calls[1].o.body, "0", "posts the count");
  calls[1].answer(200, "not json at all");
  await tick();
  eq(errors.length, 0, "no error");
  eq(root.querySelectorAll("li").length, 1, "list shown");
  synced(root, "RFetch", "both");
});

// ---- RClock and RClockAsync: lifecycle through gwl.js, with manual timers and swap() as the fragment write.
const timers = new Map();
let nextTimer = 1;
globalThis.setInterval = (f) => (timers.set(nextTimer, f), nextTimer++);
globalThis.clearInterval = (id) => timers.delete(id);
const fireTimers = () => [...timers.values()].forEach((f) => f());
const count = { m: 0, u: 0 };
{
  const h = defs.RClock.h, m = h.gw_m0, u = h.gw_u0;
  h.gw_m0 = (...a) => (count.m++, m(...a));
  h.gw_u0 = (...a) => (count.u++, u(...a));
}
// The server's root for a component with some state set, as a fragment string for swap().
function rootHtml(name, over) {
  const def = defs[name], s = { ...def.i({}), ...over };
  return `<div data-component="${name}">${def.r(s)}</div><script type="application/json">${json(s)}</script>`;
}
function lifePage() {
  document.body.innerHTML = "<div id=host></div>";
  G.hooks.a();   // stops whatever an earlier test left
  timers.clear();
  count.m = count.u = 0;
  errors = [];
  return document.getElementById("host");
}

test("RClock: the watch runs once at start before any event; mount runs once; every ticks update the DOM", () => {
  const host = lifePage();
  G.swap(host, rootHtml("RClock", { ticks: 3 }));
  const root = host.firstChild;
  eq(state(root).parity, true, "the watch ran at start (ticks is 3)");
  eq(state(root).started, true, "mount ran");
  eq(count.m, 1, "mount once");
  eq(root.querySelector("p").textContent, "3 true true", "shown before any event");
  synced(root, "RClock", "start");
  eq(timers.size, 1, "one interval");
  fireTimers();
  eq(root.querySelector("p").textContent, "4 true false", "a tick");
  fireTimers();
  fireTimers();
  eq(root.querySelector("p").textContent, "6 true false", "three ticks");
  synced(root, "RClock", "ticks");
  click(btn(root, "+"));
  eq(root.querySelector("p").textContent, "7 true true", "an event still works");
  eq(count.m, 1, "mount still once");
  eq(errors.length, 0, "no error");
});

test("RClock: a swap that removes the root stops the interval and runs unmount once; a new root starts", () => {
  const host = lifePage();
  G.swap(host, rootHtml("RClock", {}));
  const root = host.firstChild;
  eq(timers.size, 1, "interval running");
  G.swap(host, "");
  eq(host.firstChild, null, "root gone");
  eq(count.u, 1, "unmount once");
  eq(timers.size, 0, "interval stopped");
  fireTimers();
  G.swap(host, "<p>other</p>");
  eq(count.u, 1, "still once");
  eq(state(root).ticks, 0, "no tick after removal");
  G.swap(host, rootHtml("RClock", { ticks: 10 }));
  const again = host.querySelector("[data-component]");
  eq(count.m, 2, "mount ran for the new root");
  eq(timers.size, 1, "a new interval");
  fireTimers();
  eq(again.querySelector("p").textContent, "11 true true", "the new root ticks");
  eq(state(root).ticks, 0, "the old one does not");
  eq(errors.length, 0, "no error");
});

test("RClock: a root removed without a swap is stopped by its own timer", () => {
  const host = lifePage();
  G.swap(host, rootHtml("RClock", {}));
  host.innerHTML = "";
  eq(count.u, 0, "nothing noticed yet");
  fireTimers();
  eq(count.u, 1, "unmount ran from the tick");
  eq(timers.size, 0, "interval cleared");
  fireTimers();
  eq(count.u, 1, "once");
});

test("RClockAsync: an async mount and an async every update state through a stubbed fetch", async () => {
  calls = [];
  const host = lifePage();
  G.swap(host, rootHtml("RClockAsync", {}));
  const root = host.firstChild;
  eq(calls.length, 1, "mount fetched");
  eq(root.querySelector("p").textContent, "0 true", "busy shows before the reply");
  calls[0].answer(200, 5);
  await tick();
  eq(root.querySelector("p").textContent, "5 false", "mount result");
  fireTimers();
  eq(calls.length, 2, "tick fetched");
  calls[1].answer(200, 9);
  await tick();
  eq(root.querySelector("p").textContent, "9 false", "tick result");
  synced(root, "RClockAsync", "ticks");
  fireTimers();
  calls[2].answer(500, null);
  await tick();
  eq(state(root).n, 9, "a failed tick rolls back");
  eq(errors.length, 1, "and reports");
  G.swap(host, "");
  eq(timers.size, 0, "stopped");
});

// ---- RNestEvent: child-to-parent events (Addendum 12, 7.6).
const ekids = (root) => [...root.querySelectorAll("[data-component=RNestEventChild]")];
const ebtn = (k, text) => [...k.querySelectorAll("button")].find((b) => b.textContent.startsWith(text));

test("RNestEvent: a child's event runs the parent's handler; the child's own state is its own", () => {
  const root = mount("RNestEvent", {});
  const [a, b, c] = ekids(root);
  eq(a.getAttribute("data-emit-change"), "picked", "root attribute");
  eq(a.getAttribute("data-emit-named"), "heard", "second event");
  eq(b.getAttribute("data-emit-change"), null, "no listener, no attribute");
  click(ebtn(a, "+"));
  eq(root.querySelector("p").textContent, "2  false", "parent state and DOM");
  eq(state(root).got, 2, "got");
  eq(ebtn(a, "+").textContent, "+2/1", "the child updated itself");
  eq(state(a).taps, 1, "child state");
  eq(ekids(root)[0], a, "child identity");
  click(ebtn(a, "shout"));
  eq(root.querySelector("p").textContent, "2 a<b& true", "text and bool arguments");
  eq(state(root).said, "a<b&", "said");
  click(ebtn(a, "quiet"));
  eq(root.querySelector("p").textContent, "2 a<b& true", "an event-free handler sends nothing");
  tree(root, "RNestEvent", "events");
  eq(errors.length, 0, "no error");
});

test("RNestEvent: a child rendered by a block carries the listener too", () => {
  const root = mount("RNestEvent", {});
  click(ebtn(ekids(root)[0], "shout"));
  eq(state(root).loud, false, "qty 1 is not loud");
  click(ebtn(ekids(root)[0], "+"));
  click(ebtn(ekids(root)[0], "shout"));
  const d = ekids(root).find((k) => k.parentNode.tagName == "ASIDE");
  eq(d.getAttribute("data-emit-change"), "picked", "attribute from the block's HTML");
  click(ebtn(d, "+"));
  eq(state(root).got, 31, "parent handler ran");
  eq(ebtn(d, "+").textContent, "+31/1", "child state");
  tree(root, "RNestEvent", "block child");
  eq(errors.length, 0, "no error");
});

test("RNestEvent: an emit with no parent listener does nothing", () => {
  const root = mount("RNestEvent", {});
  const b = ekids(root)[1];
  click(ebtn(b, "+"));
  click(ebtn(b, "shout"));
  eq(ebtn(b, "+").textContent, "+11/1", "the child still works");
  eq(state(root).got, 0, "parent untouched");
  // A child that is not inside a component at all.
  document.body.innerHTML = `<div data-component="RNestEventChild" data-emit-change="picked">${defs.RNestEventChild.r(defs.RNestEventChild.i({ start: 5 }))}</div><script type="application/json">${json(defs.RNestEventChild.i({ start: 5 }))}</script>`;
  click(ebtn(document.body.firstChild, "+"));
  eq(ebtn(document.body.firstChild, "+").textContent, "+6/1", "a root with no parent");
  eq(errors.length, 0, "no error");
});

test("RNestEvent: a parent handler that throws rolls back the parent and leaves the child alone", () => {
  const root = mount("RNestEvent", {});
  const c = ekids(root)[2];
  click(ebtn(c, "+"));
  eq(state(root).got, 0, "parent write rolled back");
  eq(root.querySelector("p").textContent, "0  false", "parent DOM unchanged");
  eq(errors.length, 1, "one gw:error");
  eq(ebtn(c, "+").textContent, "+21/1", "the child's own write stands");
  eq(state(c).qty, 21, "child qty");
  tree(root, "RNestEvent", "throw");
});

// ---- REvents: events and modifiers (gwi.js listen, gwm.js).
const key = (el, type, k) => { const ev = new window.KeyboardEvent(type, { key: k, bubbles: true, cancelable: true }); el.dispatchEvent(ev); return ev; };
const at = (root, sel) => root.querySelector(sel);

test("REvents: a key filter runs the handler for its key only", () => {
  const root = mount("REvents", {}), el = at(root, "[data-on-keydown^='entered']");
  key(el, "keydown", "a");
  key(el, "keydown", "Escape");
  eq(state(root).n, 0, "other keys do nothing");
  const ev = key(el, "keydown", "Enter");
  eq(state(root).last, "enter", "Enter runs");
  eq(ev.defaultPrevented, true, ".prevent on the key handler");
  key(el, "keyup", "Escape");
  eq(state(root).last, "esc", "keyup.escape");
  key(at(root, "[data-on-keyup^='note.up']"), "keyup", "ArrowUp");
  eq(state(root).last, "up", "ArrowUp is .up");
  key(at(root, "[data-on-keydown^='note.space']"), "keydown", " ");
  eq(state(root).last, "space", "a space key is .space");
  key(at(root, "[data-on-keydown^='note.backspace']"), "keydown", "Backspace");
  eq(state(root).last, "back", "Backspace");
  synced(root, "REvents", "keys");
  eq(errors.length, 0, "no errors");
});

test("REvents: .prevent sets defaultPrevented and .stop stops propagation", () => {
  const root = mount("REvents", {});
  const ev = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  let seen = 0;
  const parent = () => seen++;
  document.body.addEventListener("click", parent);
  at(root, "button").dispatchEvent(ev);
  document.body.removeEventListener("click", parent);
  eq(ev.defaultPrevented, true, "prevented");
  eq(seen, 0, "a parent listener never sees a stopped click");
  eq(state(root).n, 1, "and the handler ran");
  const sub = new window.Event("submit", { bubbles: true, cancelable: true });
  at(root, "form").dispatchEvent(sub);
  eq(sub.defaultPrevented, true, "submit prevented");
  eq(state(root).n, 2, "submit handler ran");
});

test("REvents: .300ms runs the handler once after the last input; the bind updates at once", () => {
  const root = mount("REvents", {}), input = at(root, "[data-bind]"), pending = new Map(), real = [globalThis.setTimeout, globalThis.clearTimeout];
  let next = 1;
  globalThis.setTimeout = (f, ms, ...a) => (pending.set(next, [f, ms, a]), next++);
  globalThis.clearTimeout = (id) => pending.delete(id);
  try {
    input.value = "a";
    fire(input, "input");
    eq(state(root).text, "a", "bound at once");
    input.value = "ab";
    fire(input, "input");
    eq(state(root).text, "ab", "bound again");
    eq(state(root).n, 0, "handler waits");
    eq(pending.size, 1, "one timer, restarted");
    eq([...pending.values()][0][1], 300, "300ms");
    for (const [f, , a] of [...pending.values()]) f(...a);
    eq(state(root).n, 1, "handler ran once");
    eq(state(root).text, "ab", "text kept");
    synced(root, "REvents", "debounce");
  } finally { [globalThis.setTimeout, globalThis.clearTimeout] = real; }
  eq(errors.length, 0, "no errors");
});

test("REvents: focus, blur, dblclick and change handlers run", () => {
  const root = mount("REvents", {}), input = at(root, "[data-bind]");
  input.dispatchEvent(new window.FocusEvent("focus"));
  eq(state(root).last, "focus", "focus");
  input.dispatchEvent(new window.FocusEvent("blur"));
  eq(state(root).last, "blur", "blur");
  fire(input, "change");
  eq(state(root).last, "change", "change");
  at(root, "[data-on-dblclick]").dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true }));
  eq(state(root).last, "dbl", "dblclick");
});

// Nested components (step 9). The parent's innerHTML holds each child's live DOM, so the parent is compared with
// its children emptied, and every child root on its own.
const kidless = (html) => {
  const t = document.createElement("div");
  t.innerHTML = html;
  for (const k of t.querySelectorAll("[data-component]")) { k.innerHTML = ""; k.nextElementSibling?.remove(); }
  return norm(t.innerHTML);
};
const tree = (root, name, step) => {
  eq(kidless(root.innerHTML), kidless(defs[name].r(state(root))), `${name}: parent vs r(state) after ${step}`);
  for (const k of root.querySelectorAll("[data-component]")) synced(k, k.dataset.component, `${step} (${k.dataset.component})`);
};
const kids = (root) => [...root.querySelectorAll("[data-component=RNestChild]")];
const keyed = (root, k) => kids(root).find((c) => c.getAttribute("gw-key") == k);
const kidBtn = (k) => k.querySelector("button");

test("RNest: a parent click changes a child's prop; the child keeps its own state", () => {
  const root = mount("RNest", { title: "T<&>" });
  const [top] = kids(root), b = kidBtn(top);
  eq(top.getAttribute("gw-key"), null, "no key on an unkeyed child");
  eq(b.textContent, "1/0/10", "first render from props");
  click(b);
  click(b);
  eq(b.textContent, "1/2/12", "the child's own state");
  click(btn(root, "bump 1"));
  eq(kids(root)[0], top, "child identity");
  eq(kidBtn(top), b, "child button identity");
  eq(b.textContent, "2/2/22", "n from the parent, taps kept, computed follows");
  eq(state(top).taps, 2, "state kept");
  eq(top.querySelector(".kid").textContent, "T<&>", "label prop");
  tree(root, "RNest", "bump");
  click(btn(root, "flip"));
  eq(top.querySelector("em")?.textContent, "on", "bool prop shows the child's block");
  eq(state(top).taps, 2, "state kept again");
  tree(root, "RNest", "flip");
  click(btn(root, "flip"));
  eq(top.querySelector("em"), null, "and hides it");
  tree(root, "RNest", "flip back");
  eq(errors.length, 0, "no error");
});

test("RNest: a keyed list renders new children from props, and a prop change reaches them all", () => {
  const root = mount("RNest", { title: "t" });
  click(btn(root, "add"));
  click(btn(root, "add"));
  const [a, b] = [keyed(root, "10"), keyed(root, "11")];
  eq(kids(root).length, 3, "top child and two listed");
  eq(a.querySelector(".kid").textContent, "<kid&", "label from the item");
  eq(kidBtn(a).textContent, "11/0/110", "n = id + count, rendered from props");
  eq(kidBtn(b).textContent, "12/0/120", "second");
  tree(root, "RNest", "adds");
  click(kidBtn(a));
  click(kidBtn(a));
  click(kidBtn(b));
  click(btn(root, "bump 1"));
  eq(keyed(root, "10"), a, "keyed identity");
  eq(kidBtn(a).textContent, "12/2/122", "a: prop and own state");
  eq(kidBtn(b).textContent, "13/1/131", "b: prop and own state");
  tree(root, "RNest", "bump");
  click(btn(root, "add"));
  eq(kidBtn(keyed(root, "12")).textContent, "14/0/140", "a third child is new");
  eq(kidBtn(a).textContent, "12/2/122", "the old ones are untouched");
  tree(root, "RNest", "add after bump");
  click(btn(root, "x10"));
  eq(kids(root).length, 3, "one removed");
  eq(keyed(root, "11"), b, "b survives");
  tree(root, "RNest", "drop");
  eq(errors.length, 0, "no error");
});

test("RNest: reordering keeps each child's state, also for children never touched", () => {
  const root = mount("RNest", { title: "t" });
  for (let i = 0; i < 3; i++) click(btn(root, "add"));
  const [a, b, c] = ["10", "11", "12"].map((k) => keyed(root, k));
  click(kidBtn(a));
  click(kidBtn(a));
  click(btn(root, "rotate"));
  const order = kids(root).slice(1).map((k) => k.getAttribute("gw-key"));
  eq(order.join(), "11,12,10", "rotated");
  eq([keyed(root, "10"), keyed(root, "11"), keyed(root, "12")].join(), [a, b, c].join(), "same nodes");
  eq(keyed(root, "10"), a, "a is the same node");
  eq(state(a).taps, 2, "a kept its state");
  tree(root, "RNest", "rotate");
  click(btn(root, "bump 1"));
  // b and c were never clicked and moved; their state is still the server's, read next to their own script.
  click(kidBtn(c));
  eq(kidBtn(c).textContent, "14/1/141", "c: new prop, one tap");
  eq(kidBtn(b).textContent, "13/0/130", "b: new prop");
  eq(kidBtn(a).textContent, "12/2/122", "a");
  tree(root, "RNest", "bump after rotate");
  click(btn(root, "rotate"));
  eq(state(c).taps, 1, "c after a second rotate");
  eq(state(a).taps, 2, "a after a second rotate");
  tree(root, "RNest", "second rotate");
  eq(errors.length, 0, "no error");
});

test("RNest: a child that was never touched and moves first still reads its own state", () => {
  const root = mount("RNest", { title: "t" });
  for (let i = 0; i < 3; i++) click(btn(root, "add"));
  const [a, b, c] = ["10", "11", "12"].map((k) => keyed(root, k));
  click(btn(root, "back"));
  eq(kids(root).slice(1).map((k) => k.getAttribute("gw-key")).join(), "12,10,11", "last to front");
  eq(keyed(root, "12"), c, "c is the same node");
  eq(errors.length, 0, "no error");
  click(kidBtn(c));
  eq(kidBtn(c).textContent, "13/1/131", "c: its own props from the server, one tap");
  click(btn(root, "bump 1"));
  eq(kidBtn(c).textContent, "14/1/141", "c after a parent change");
  eq(kidBtn(a).textContent, "12/0/120", "a");
  eq(kidBtn(b).textContent, "13/0/130", "b");
  tree(root, "RNest", "back");
  eq(errors.length, 0, "no error");
});

test("RNest: a child inside an {#if} is created and removed with the block", () => {
  const root = mount("RNest", { title: "t" });
  click(btn(root, "flip"));
  const lit = root.querySelector("section [data-component]");
  eq(kidBtn(lit).textContent, "7/0/70", "rendered from the literal props");
  click(kidBtn(lit));
  tree(root, "RNest", "lit tap");
  click(btn(root, "flip"));
  eq(root.querySelector("section"), null, "gone");
  click(btn(root, "flip"));
  eq(kidBtn(root.querySelector("section [data-component]")).textContent, "7/0/70", "a fresh child after the block comes back");
  tree(root, "RNest", "back");
  eq(errors.length, 0, "no error");
});

test("gwc.js: a different component at the same place is replaced, not patched", () => {
  const root = mount("RNest", { title: "t" });
  const o = kids(root)[0], b = document.createElement("div");
  b.dataset.component = "RCounter";
  eq(hooks.c(o, b), true, "handled");
  eq(o.isConnected, false, "old root gone");
  eq(b.isConnected, true, "new root in place");
});

let pass = 0, fail = 0;
for (const [name, fn] of tests) {
  try { await fn(); pass++; console.log("PASS", name); }
  catch (err) { fail++; console.log("FAIL", name, "\n   ", String(err.stack || err).replaceAll("\n", "\n    ")); }
}
console.log(`\nreactive_dom: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
