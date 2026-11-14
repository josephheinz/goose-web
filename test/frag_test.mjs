// Driven by test/frag.sh. Runs client/gwf.js's frag() (with client/gwi.js) and client/gwq.js (gw-trigger) under jsdom
// with fetch stubbed.
import fs from "node:fs";
import { createRequire } from "node:module";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const read = (f) => fs.readFileSync(new URL("../client/" + f, import.meta.url), "utf8");
const src = (read("gwi.js") + "\n{\n" + read("gwf.js").replace(/^import .*$/m, "") + "\n}\n{\n" + read("gwq.js") + "\n}").replace(/^export /gm, "");
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
  new w.Function("document", "location", "CustomEvent", "dispatchEvent", "console", "fetch", "FormData", "URLSearchParams", "URL", "TextEncoder", "structuredClone", "WeakMap", "setTimeout", "clearTimeout", "history",
    src).call(w, w.document, w.location, w.CustomEvent, (e) => w.dispatchEvent(e), w.console, w.fetch, w.FormData, w.URLSearchParams, w.URL, w.TextEncoder, w.structuredClone, WeakMap, setTimeout, clearTimeout, w.history);
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
// gw-url (1.2): the address bar shows the fetched URL once the fragment lands, not before and not on failure.
const typed = (w, el, v) => { el.value = v; el.dispatchEvent(new w.Event("input", { bubbles: true })); };
{
  const form = (extra) => '<form id="f" action="/search" gw-target="b"' + extra + '><input id="q" name="q" value="goose"></form>';
  const p = page(OLD + form(" gw-url"), () => ({ status: 200, echo: "b", body: "<p>hits</p>", delay: 50 }));
  submit(p.w, p.d.getElementById("f")); await sleep(10);
  check(p.w.location.href == "http://x.test/", "gw-url: not before the reply: " + p.w.location.href);
  await sleep(80);
  check(p.box.innerHTML == "<p>hits</p>" && p.w.location.href == "http://x.test/search?q=goose", "gw-url: the form's URL after it lands: " + p.w.location.href);
  check(p.w.history.length == 1, "gw-url replaces, does not push: " + p.w.history.length);
  const l = page(OLD + '<a id="l" href="/list?page=2" gw-target="b" gw-url>2</a>', () => ({ status: 200, echo: "b", body: "<p>2</p>" }));
  click(l.w, l.d.getElementById("l")); await sleep(30);
  check(l.w.location.href == "http://x.test/list?page=2", "gw-url on a link: " + l.w.location.href);
  const n = page(OLD + form(""), () => ({ status: 200, echo: "b", body: "<p>hits</p>" }));
  submit(n.w, n.d.getElementById("f")); await sleep(30);
  check(n.box.innerHTML == "<p>hits</p>" && n.w.location.href == "http://x.test/", "no gw-url: the address stays: " + n.w.location.href);
  const e = page(OLD + form(" gw-url"), () => ({ status: 500, echo: "b", body: "" }));
  submit(e.w, e.d.getElementById("f")); await sleep(30);
  check(e.w.location.href == "http://x.test/", "gw-url: a failed reply leaves the address: " + e.w.location.href);
}
// gw-trigger (1.2): input submits after the pause, once for a burst; Enter cancels the wait; the last request wins.
{
  const form = '<form id="f" action="/search" gw-target="b" gw-trigger="input 300ms"><input id="q" name="q"></form>';
  const p = page(OLD + form, (url) => ({ status: 200, echo: "b", body: "<p>" + new URL(url).searchParams.get("q") + "</p>" }));
  const q = p.d.getElementById("q");
  typed(p.w, q, "g"); await sleep(50); typed(p.w, q, "go"); await sleep(50); typed(p.w, q, "goo");
  await sleep(150);
  check(p.sent.length == 0, "gw-trigger: nothing before the pause: " + p.sent.length);
  await sleep(300);
  check(p.sent.length == 1 && p.sent[0].url.endsWith("/search?q=goo") && p.box.innerHTML == "<p>goo</p>", "gw-trigger: one GET with the last text: " + p.sent.map((x) => x.url));
  check(p.sent[0]?.init.headers["GW-Fragment"] == "b", "gw-trigger: sent as a fragment request");
  typed(p.w, q, "goos"); submit(p.w, p.d.getElementById("f")); await sleep(450);
  check(p.sent.length == 2, "gw-trigger: Enter sends now and cancels the timer: " + p.sent.length);
  const o = page(OLD + '<form id="f" action="/search" gw-target="b"><input id="q" name="q"></form>', () => ({ status: 200, echo: "b", body: "x" }));
  typed(o.w, o.d.getElementById("q"), "a"); await sleep(400);
  check(o.sent.length == 0, "no gw-trigger: input sends nothing");
  let k = 0;
  const r = page(OLD + form, (url) => ({ status: 200, echo: "b", body: "<p>" + new URL(url).searchParams.get("q") + "</p>", delay: k++ == 0 ? 400 : 10 }));
  const rq = r.d.getElementById("q");
  typed(r.w, rq, "slow"); await sleep(350); typed(r.w, rq, "fast"); await sleep(700);
  check(r.sent.length == 2 && r.box.innerHTML == "<p>fast</p>", "gw-trigger: the last request wins: " + r.box.innerHTML);
}
if (bad) { console.error(bad + " of " + total + " checks failed"); process.exit(1); }
console.log("frag: " + total + " checks passed");
