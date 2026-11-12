// Driven by test/frag.sh. Runs client/gwi.js's frag() under jsdom with fetch stubbed.
import fs from "node:fs";
import { createRequire } from "node:module";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const src = fs.readFileSync(new URL("../client/gwi.js", import.meta.url), "utf8").replace(/^export /gm, "");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let bad = 0, total = 0;
const check = (c, m) => { total++; if (!c) { bad++; console.error("FAIL: " + m); } };

// One page per case; reply(url, init) -> {status, echo, body, delay} or throws.
function page(body, reply) {
  const dom = new JSDOM("<!doctype html><body>" + body + "</body>", { url: "http://x.test/" });
  const w = dom.window, sent = [];
  w.fetch = async (url, init) => {
    sent.push({ url: String(url), init });
    const x = await reply(url, init);
    await sleep(x.delay || 0);
    return { ok: x.status < 300, status: x.status, url: String(url), text: async () => x.body,
      headers: { get: (k) => (k == "GW-Fragment" && x.echo ? x.echo : null) } };
  };
  w.console.error = () => {};
  new w.Function("document", "location", "CustomEvent", "dispatchEvent", "console", "fetch", "FormData", "URLSearchParams", "URL", "TextEncoder", "structuredClone", "WeakMap", "setTimeout", "clearTimeout",
    src).call(w, w.document, w.location, w.CustomEvent, (e) => w.dispatchEvent(e), w.console, w.fetch, w.FormData, w.URLSearchParams, w.URL, w.TextEncoder, w.structuredClone, WeakMap, setTimeout, clearTimeout);
  return { w, d: w.document, sent, box: w.document.getElementById("b") };
}
const click = (w, el) => el.dispatchEvent(new w.MouseEvent("click", { bubbles: true, cancelable: true, button: 0 }));
const submit = (w, f) => f.dispatchEvent(new w.Event("submit", { bubbles: true, cancelable: true }));
const TPL = '<template id="gw-loading"><i>loading</i></template>';
const OLD = '<div id="b"><p>old</p></div>';

{ // 422 with echo morphs
  const p = page(OLD + '<a id="l" href="/f" gw-target="b">x</a>', () => ({ status: 422, echo: "b", body: "<p>errors</p>" }));
  click(p.w, p.d.getElementById("l")); await sleep(30);
  check(p.box.innerHTML == "<p>errors</p>", "422 with echo morphs: " + p.box.innerHTML);
}
{ // 500 does not morph; 422 without echo does not either
  for (const x of [{ status: 500, echo: "b", body: "<p>boom</p>" }, { status: 422, body: "<p>no</p>" }]) {
    const p = page(OLD + '<a id="l" href="/f" gw-target="b">x</a>', () => x);
    click(p.w, p.d.getElementById("l")); await sleep(30);
    check(p.box.innerHTML == "<p>old</p>", "status " + x.status + " leaves DOM: " + p.box.innerHTML);
  }
}
{ // multipart POST sends FormData; urlencoded sends URLSearchParams
  const f = (enc) => '<form id="f" method="post" action="/u" gw-target="b"' + enc + '><input name="a" value="1"></form>';
  for (const [enc, cls] of [[' enctype="Multipart/Form-Data"', "FormData"], ["", "URLSearchParams"]]) {
    const p = page(OLD + f(enc), () => ({ status: 200, echo: "b", body: "ok" }));
    submit(p.w, p.d.getElementById("f")); await sleep(30);
    check(p.sent[0]?.init.body instanceof p.w[cls], "body is " + cls + " for [" + enc + "]");
    check(p.sent[0]?.init.method == "POST", "method POST");
  }
}
{ // fast reply: no loading
  const p = page(OLD + TPL + '<a id="l" href="/f" gw-target="b">x</a>', () => ({ status: 200, echo: "b", body: "<p>new</p>", delay: 50 }));
  let seen = false;
  new p.w.MutationObserver(() => { if (p.box.textContent.includes("loading")) seen = true; }).observe(p.box, { childList: true, subtree: true });
  click(p.w, p.d.getElementById("l")); await sleep(300);
  check(!seen && p.box.innerHTML == "<p>new</p>", "fast reply shows no loading: " + p.box.innerHTML);
}
{ // slow reply: loading then reply
  const p = page(OLD + TPL + '<a id="l" href="/f" gw-target="b">x</a>', () => ({ status: 200, echo: "b", body: "<p>new</p>", delay: 300 }));
  click(p.w, p.d.getElementById("l")); await sleep(200);
  check(p.box.innerHTML == "<i>loading</i>", "loading shown: " + p.box.innerHTML);
  await sleep(250);
  check(p.box.innerHTML == "<p>new</p>", "reply replaces loading: " + p.box.innerHTML);
}
{ // failure after loading restores
  const p = page(OLD + TPL + '<a id="l" href="/f" gw-target="b">x</a>', () => ({ status: 500, echo: "b", body: "", delay: 300 }));
  const old = p.box.firstChild;
  click(p.w, p.d.getElementById("l")); await sleep(200);
  check(p.box.innerHTML == "<i>loading</i>", "loading shown before failure");
  await sleep(250);
  check(p.box.innerHTML == "<p>old</p>" && p.box.firstChild == old, "failure restores same nodes: " + p.box.innerHTML);
}
{ // none, custom id, form without / with gw-loading
  const slow = () => ({ status: 200, echo: "b", body: "<p>new</p>", delay: 300 });
  const cases = [
    ['<a id="l" href="/f" gw-target="b" gw-loading="none">x</a>', "l", click, "<p>old</p>", "link none"],
    ['<a id="l" href="/f" gw-target="b" gw-loading="mine">x</a><template id="mine"><u>m</u></template>', "l", click, "<u>m</u>", "link custom id"],
    ['<form id="l" method="post" action="/f" gw-target="b"></form>', "l", submit, "<p>old</p>", "form without gw-loading"],
    ['<form id="l" method="post" action="/f" gw-target="b" gw-loading></form>', "l", submit, "<i>loading</i>", "form with gw-loading"],
    ['<form id="l" method="post" action="/f" gw-target="b" gw-loading="none"></form>', "l", submit, "<p>old</p>", "form gw-loading none"],
  ];
  for (const [h, id, fn, want, name] of cases) {
    const p = page(OLD + TPL + h, slow);
    fn(p.w, p.d.getElementById(id)); await sleep(220);
    check(p.box.innerHTML == want, name + ": " + p.box.innerHTML);
    await sleep(200);
  }
}
if (bad) { console.error(bad + " of " + total + " checks failed"); process.exit(1); }
console.log("frag: " + total + " checks passed");
