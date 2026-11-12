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
const { defs, state } = G;
for (const n of ["RCounter", "RParts", "RComputed", "RWatch", "RStruct"]) await import(pathToFileURL(`${dir}/${n}.js`).href);

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

let pass = 0, fail = 0;
for (const [name, fn] of tests) {
  try { await fn(); pass++; console.log("PASS", name); }
  catch (err) { fail++; console.log("FAIL", name, "\n   ", String(err.stack || err).replaceAll("\n", "\n    ")); }
}
console.log(`\nreactive_dom: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
