// Driven by test/morph.sh. Runs client/gwi.js's morph under jsdom against test/morph/v1.js, the
// morph that had no keys.
import fs from "node:fs";
import { createRequire } from "node:module";

const here = new URL(".", import.meta.url);
const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><body><div id=root></div></body>");
const { window } = dom, document = window.document, root = document.getElementById("root");

// Pulls morph, and the key helper above it when there is one, out of a source file without importing it.
function extract(path) {
  const lines = fs.readFileSync(new URL(path, here), "utf8").split("\n");
  let s = lines.findIndex((l) => l.startsWith("const key ="));
  if (s < 0) s = lines.findIndex((l) => l.startsWith("function morph("));
  const m = lines.findIndex((l) => l.startsWith("function morph("));
  const e = m < 0 ? -1 : lines.findIndex((l, i) => i > m && l == "}");
  if (s < 0 || m < 0 || e < 0) throw new Error("cannot extract morph from " + path);
  return lines.slice(s, e + 1).join("\n");
}
function load(path) {
  const calls = [];
  const morph = new Function("D", "oops", extract(path) + "; return morph;")(document, (m) => calls.push(String(m)));
  return { morph, calls };
}
const N = load("../client/gwi.js"), O = load("morph/v1.js");
const keyed = fs.readFileSync(new URL("../client/gwi.js", here), "utf8").includes("\nconst key =");

const ctr = { moves: 0, ops: 0 };
const NP = window.Node.prototype, EP = window.Element.prototype, CP = window.CharacterData.prototype;
const insertBefore = NP.insertBefore;
NP.insertBefore = function (n, r) {
  ctr.ops++;
  if (n.isConnected) ctr.moves++;
  return insertBefore.call(this, n, r);
};
for (const name of ["append", "remove", "replaceWith"]) {
  for (const proto of [EP, CP]) {
    const f = proto[name];
    proto[name] = function (...a) { ctr.ops++; return f.apply(this, a); };
  }
}

function canon(n) {
  if (n.nodeType == 11) return [...n.childNodes].map(canon).join("");
  if (n.nodeType != 1) return n.nodeType == 3 ? "T(" + n.data + ")" : "?" + n.nodeType;
  const at = [...n.attributes].map((x) => x.name + "=" + x.value).sort().join(" ");
  return "<" + n.nodeName + " " + at + ">" + [...n.childNodes].map(canon).join("") + "</>";
}
function template(html) {
  const tp = document.createElement("template");
  tp.innerHTML = html;
  return tp;
}
function morphTo(impl, newHtml, force = 0) {
  const tp = template(newHtml), expected = canon(tp.content);
  impl.calls.length = 0;
  ctr.moves = ctr.ops = 0;
  impl.morph(root, tp.content, force);
  const got = canon({ nodeType: 11, childNodes: root.childNodes });
  if (got !== expected) throw new Error(`HTML mismatch\n new: ${newHtml}\n got: ${got}\n exp: ${expected}`);
  return { moves: ctr.moves, ops: ctr.ops, oops: [...impl.calls] };
}
function run(oldHtml, newHtml, impl = N, force = 0) {
  root.innerHTML = oldHtml;
  const before = [...root.childNodes];
  const r = morphTo(impl, newHtml, force);
  return { ...r, before, after: [...root.childNodes] };
}
const kept = (r) => JSON.stringify(r.after.map((n, i) => n === r.before[i]));

const li = (...ks) => ks.map((k) => `<li gw-key="${k}">${k}</li>`).join("");
const keyOf = (n) => n.getAttribute?.("gw-key");
const byKey = (nodes) => Object.fromEntries(nodes.filter(keyOf).map((n) => [keyOf(n), n]));
const same = (r, keys) => {
  const b = byKey(r.before), a = byKey(r.after);
  for (const k of keys) if (b[k] !== a[k] || !a[k]) throw new Error("identity lost for key " + k);
};
const eq = (x, y, m) => { if (x !== y) throw new Error(`${m}: got ${x}, want ${y}`); };
const attr = (s) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

let seed = Number(process.env.SEED ?? 20260101) >>> 0;
const seed0 = seed;
const rnd = () => (seed = (seed + 0x6d2b79f5) >>> 0, ((t) => ((t = Math.imul(t ^ (t >>> 15), t | 1)), (t ^= t + Math.imul(t ^ (t >>> 7), t | 61)), ((t ^ (t >>> 14)) >>> 0) / 4294967296))(seed));
const ri = (n) => Math.floor(rnd() * n), pick = (a) => a[ri(a.length)];

function genUnkeyedChild(depth) {
  if (ri(5) == 0) return pick(["x", "y", " ", "\n", "hello"]);
  const tag = pick(["li", "p", "span"]);
  const attrs = (ri(2) ? ` class="c${ri(3)}"` : "") + (ri(4) == 0 ? ` title="t${ri(3)}"` : "");
  return `<${tag}${attrs}>${depth > 0 ? genList(depth - 1, false, 3) : pick(["a", "b", ""])}</${tag}>`;
}
function genChild(depth, withKeys, pool) {
  if (withKeys && ri(5) < 3) {
    const tag = ri(8) == 0 ? "div" : "li";
    return `<${tag} gw-key="${ri(pool)}"${ri(3) == 0 ? ` data-v="${ri(3)}"` : ""}>${depth > 0 ? genList(depth - 1, true, 3) : ri(3)}</${tag}>`;
  }
  return genUnkeyedChild(depth);
}
const genArr = (depth, withKeys, max, pool = 6) => Array.from({ length: ri(max + 1) }, () => genChild(depth, withKeys, pool));
const genList = (depth, withKeys, max) => genArr(depth, withKeys, max).join("");

const keysOf = (html) => [...template(html).content.childNodes].map((n) => keyOf(n) && n.nodeName + " " + keyOf(n)).filter(Boolean);

let pass = 0, fail = 0;
function named(name, fn) {
  try { const info = fn(); pass++; console.log("PASS", name, info ?? ""); }
  catch (e) { fail++; console.log("FAIL", name, "\n   ", e.message.replaceAll("\n", "\n    ")); }
}

named("1 unkeyed equivalence, 2000 random pairs", () => {
  for (let i = 0; i < 2000; i++) {
    const a = genList(2, false, 6), b = genList(2, false, 6);
    const rn = run(a, b, N), ro = run(a, b, O);
    if (rn.ops !== ro.ops) throw new Error("op count differs\n old: " + a + "\n new: " + b);
    if (kept(rn) !== kept(ro)) throw new Error("identity differs\n old: " + a + "\n new: " + b);
  }
});
named("2 empty gw-key is unkeyed", () => {
  const a = `<li gw-key="">1</li><li gw-key="">2</li>`, b = `<li gw-key="">2</li><li gw-key="">3</li>`;
  const rn = run(a, b, N), ro = run(a, b, O);
  eq(rn.ops, ro.ops, "ops");
  eq(kept(rn), kept(ro), "identity");
});

if (keyed) {
  named("3 rotate right", () => { const r = run(li(1, 2, 3, 4, 5), li(5, 1, 2, 3, 4)); same(r, [1, 2, 3, 4, 5]); eq(r.moves, 1, "moves"); });
  named("4 rotate left", () => { const r = run(li(1, 2, 3, 4, 5), li(2, 3, 4, 5, 1)); same(r, [1, 2, 3, 4, 5]); eq(r.moves, 1, "moves"); });
  named("5 adjacent swap", () => { const r = run(li(1, 2, 3), li(2, 1, 3)); same(r, [1, 2, 3]); eq(r.moves, 1, "moves"); });
  named("6 remove first of five", () => { const r = run(li(1, 2, 3, 4, 5), li(2, 3, 4, 5)); same(r, [2, 3, 4, 5]); eq(r.moves, 0, "moves"); });
  named("7 remove three in the middle", () => { const r = run(li(1, 2, 3, 4, 5), li(1, 5)); same(r, [1, 5]); eq(r.moves, 0, "moves"); });
  named("8 insert at front and middle", () => { const r = run(li(1, 2, 3), li(9, 1, 8, 2, 3)); same(r, [1, 2, 3]); eq(r.moves, 0, "moves"); });
  named("9 reverse of five", () => { const r = run(li(1, 2, 3, 4, 5), li(5, 4, 3, 2, 1)); same(r, [1, 2, 3, 4, 5]); return "moves=" + r.moves; });
  named("10 keyed conditional before an unkeyed input", () => {
    root.innerHTML = `<p><input name="q"></p>`;
    const inp = root.firstChild.firstChild;
    morphTo(N, `<p><span gw-key="err">bad</span><input name="q"></p>`);
    eq(root.firstChild.lastChild, inp, "input after show");
    morphTo(N, `<p><input name="q"></p>`);
    eq(root.firstChild.firstChild, inp, "input after hide");
  });
  named("11 keyed conditional in the middle", () => {
    root.innerHTML = `<label>a</label><input>`;
    const [lab, inp] = root.childNodes;
    morphTo(N, `<label>a</label><b gw-key="e">x</b><input>`);
    eq(root.firstChild, lab, "label after show"); eq(root.lastChild, inp, "input after show");
    morphTo(N, `<label>a</label><input>`);
    eq(root.firstChild, lab, "label after hide"); eq(root.lastChild, inp, "input after hide");
  });
  named("12 duplicate key in new", () => {
    const r = run(li(1), `<li gw-key="1">a</li><li gw-key="1">b</li>`);
    eq(r.oops.length, 1, "oops calls");
    if (!r.oops[0].includes("duplicate gw-key")) throw new Error(r.oops[0]);
  });
  named("13 duplicate key in old only", () => {
    const r = run(`<li gw-key="1">a</li><li gw-key="1">b</li><li gw-key="2">c</li>`, li(2, 1));
    eq(r.oops.length, 0, "oops");
    eq(r.after[1], r.before[0], "first duplicate kept");
  });
  named("14 same key, other tag", () => {
    const r = run(`<div gw-key="x">1</div>`, `<span gw-key="x">1</span>`);
    if (r.after[0] === r.before[0]) throw new Error("reused");
  });
  named("15 whitespace between keyed items, swapped", () => {
    const r = run(`\n<li gw-key=1>a</li>\n<li gw-key=2>b</li>\n`, `\n<li gw-key=2>b</li>\n<li gw-key=1>a</li>\n`);
    same(r, [1, 2]);
    if (r.moves > 2) throw new Error("moves " + r.moves);
    return "moves=" + r.moves;
  });
  named("16 nested keyed lists", () => {
    const inner = (...ks) => `<ul gw-key="L">${li(...ks)}</ul>`;
    root.innerHTML = inner("a", "b", "c");
    const ul = root.firstChild, [a, b, c] = ul.children;
    morphTo(N, inner("c", "a", "b"));
    eq(root.firstChild, ul, "outer");
    eq(ul.children[0], c, "c"); eq(ul.children[1], a, "a"); eq(ul.children[2], b, "b");
  });
  named("17 keyed list between unkeyed heading and footer", () => {
    const r = run(`<h2>T</h2>${li(1, 2, 3, 4)}<p>foot</p>`, `<h2>T2</h2>${li(4, 5, 2)}<p>foot2</p>`);
    same(r, [2, 4]);
    eq(r.after[0], r.before[0], "heading");
    eq(r.after[4], r.before[5], "footer");
  });
  named("18 key with quote, ampersand and angle bracket", () => {
    const k1 = `a"b&<c'`, k2 = `x&amp;y`;
    const mk = (...ks) => ks.map((k) => `<li gw-key="${attr(k)}">v</li>`).join("");
    const r = run(mk(k1, k2), mk(k2, k1));
    same(r, [k1, k2]);
    eq(r.oops.length, 0, "oops");
  });
  for (const force of [0, 1]) {
    named(`${19 + force} focused text input in a moved row, force ${force}`, () => {
      const row = (n) => `<li gw-key="${n}"><input value="row ${n}"></li>`;
      root.innerHTML = [1, 2, 3, 4, 5].map(row).join("\n");
      const inp = root.children[2].firstChild;
      inp.focus();
      inp.value = "abc";
      eq(document.activeElement, inp, "focused before");
      morphTo(N, [3, 1, 2, 4, 5].map(row).join("\n"), force);
      eq(root.firstChild, inp.parentNode, "row moved");
      eq(document.activeElement, inp, "still focused");
      eq(inp.value, force ? "row 3" : "abc", "value");
    });
  }

  const FUZZ = Number(process.env.FUZZ ?? 5000);
  named(`21 fuzz ${FUZZ} cases, seed ${seed0}`, () => {
    const check = (oa, na) => {
      const oh = oa.join(""), nh = na.join("");
      const r = run(oh, nh, N);
      const ok = keysOf(oh), nk = keysOf(nh);
      if (new Set(ok).size != ok.length || new Set(nk).size != nk.length) return;
      const key = (n) => keyOf(n) && n.nodeName + " " + keyOf(n);
      const bk = {}, ak = {};
      r.before.forEach((n) => { const k = key(n); if (k) bk[k] = n; });
      r.after.forEach((n) => { const k = key(n); if (k) ak[k] = n; });
      for (const k of nk) if (k in bk && bk[k] !== ak[k]) throw new Error("identity lost for " + k);
    };
    const fails = (x, y) => { try { check(x, y); return false; } catch { return true; } };
    for (let i = 0; i < FUZZ; i++) {
      const oa = genArr(3, true, 8), na = genArr(3, true, 8);
      try { check(oa, na); } catch {
        let A = oa, B = na, again = true;
        while (again) {
          again = false;
          for (let j = 0; j < A.length && !again; j++) { const c = A.filter((_, k) => k != j); if (fails(c, B)) { A = c; again = true; } }
          for (let j = 0; j < B.length && !again; j++) { const c = B.filter((_, k) => k != j); if (fails(A, c)) { B = c; again = true; } }
        }
        let msg = "";
        try { check(A, B); } catch (e) { msg = e.message; }
        throw new Error(`case ${i}\n old: ${A.join("")}\n new: ${B.join("")}\n error: ${msg}`);
      }
    }
  });
}

console.log(`\nmorph.sh: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
