import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createReader, encodeMessage } from '../../editor/lsp/server.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = join(here, '../../editor/lsp/server.mjs');
const PAGE = '<p>é {nme}</p>\n';
const CARD = '<script>\nlet x = 1;\n</script>\n<b>{x}</b>\n';
const OTHER = 'one\ntwo\n';

const clients = [];
after(() => clients.forEach((c) => c.p.kill()));

class Client {
  constructor({ env = {}, utf8 = false } = {}) {
    this.root = mkdtempSync(join(tmpdir(), 'gweb-lsp-test-'));
    for (const [f, t] of [['app/page.html', PAGE], ['components/Card.gshtml', CARD], ['app/other.goose', OTHER]]) {
      mkdirSync(dirname(join(this.root, f)), { recursive: true });
      writeFileSync(join(this.root, f), t);
    }
    this.utf8 = utf8;
    clients.push(this);
    this.msgs = []; this.pending = new Map(); this.id = 0;
    this.p = spawn(process.execPath, [SERVER, '--gweb', join(here, 'fake-gweb.mjs')], {
      stdio: ['pipe', 'pipe', 'inherit'],
      env: { ...process.env, GOOSE: join(here, 'fake-goose.mjs'), GWEB_LSP_DEBOUNCE_MS: '30', GWEB_LSP_INIT_TIMEOUT_MS: '400', ...env },
    });
    this.exited = new Promise((r) => this.p.on('exit', r));
    this.p.stdout.on('data', createReader((m) => {
      if (m.method === undefined) this.pending.get(m.id)?.(m); else this.msgs.push(m);
    }));
  }
  uri(rel) { return pathToFileURL(join(this.root, rel)).href; }
  notify(method, params) { this.p.stdin.write(encodeMessage({ method, params })); }
  request(method, params) {
    const id = ++this.id;
    return new Promise((r) => { this.pending.set(id, r); this.p.stdin.write(encodeMessage({ id, method, params })); });
  }
  async start() {
    const caps = this.utf8 ? { general: { positionEncodings: ['utf-8', 'utf-16'] } } : {};
    const res = await this.request('initialize', { rootUri: pathToFileURL(this.root).href, capabilities: caps });
    this.notify('initialized', {});
    return res.result;
  }
  open(rel, text) {
    this.notify('textDocument/didOpen', { textDocument: { uri: this.uri(rel), languageId: 'x', version: 1, text } });
  }
  async waitFor(pred, from = 0) {
    for (let i = 0; i < 500; i++) {
      const m = this.msgs.slice(from).find(pred);
      if (m) return m;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error('timed out; messages: ' + JSON.stringify(this.msgs));
  }
  async diags(rel, pred, from = 0) {
    const uri = this.uri(rel);
    return (await this.waitFor((m) => m.method === 'textDocument/publishDiagnostics' && m.params.uri === uri && pred(m.params.diagnostics), from)).params.diagnostics;
  }
  logs() { return readFileSync(join(this.root, '.fake-gweb.log'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)); }
  async stop() {
    await this.request('shutdown', null);
    this.notify('exit', null);
    const code = await Promise.race([this.exited, new Promise((r) => setTimeout(() => { this.p.kill(); r('killed'); }, 3000))]);
    rmSync(this.root, { recursive: true, force: true });
    return code;
  }
}

const range = (sl, sc, el, ec) => ({ start: { line: sl, character: sc }, end: { line: el, character: ec } });
const bySource = (ds, s) => ds.find((d) => d.source === s);

test('page.html: gweb error and goose diagnostic, mapped to the source', async () => {
  const c = new Client();
  const init = await c.start();
  assert.equal(init.capabilities.positionEncoding, 'utf-16');
  assert.equal(init.capabilities.textDocumentSync.change, 1);
  c.open('app/page.html', PAGE);
  const ds = await c.diags('app/page.html', (d) => d.length === 2);
  assert.deepEqual(bySource(ds, 'gweb').range, range(0, 0, 0, 14)); // whole line, utf-16 units
  assert.equal(bySource(ds, 'gweb').message, 'gweb says no');
  // "nme" is at byte 7 (after a two-byte e-acute): utf-16 column 6
  assert.deepEqual(bySource(ds, 'goose').range, range(0, 6, 0, 9));
  assert.equal(bySource(ds, 'goose').message, 'goose: page_html.goose');
  assert.equal(await c.stop(), 0);
});

test('utf-8 clients get byte columns', async () => {
  const c = new Client({ utf8: true, env: { FAKE_GOOSE_ENC: 'utf-8' } });
  assert.equal((await c.start()).capabilities.positionEncoding, 'utf-8');
  c.open('app/page.html', PAGE);
  const ds = await c.diags('app/page.html', (d) => d.length === 2);
  assert.deepEqual(bySource(ds, 'gweb').range, range(0, 0, 0, 15));
  assert.deepEqual(bySource(ds, 'goose').range, range(0, 7, 0, 10));
  await c.stop();
});

test('.gshtml (// gw:line) and a .goose file (map.txt identity); other files ignored', async () => {
  const c = new Client();
  await c.start();
  c.open('components/Card.gshtml', CARD);
  c.open('app/other.goose', OTHER);
  c.open('lib/util.goose', 'x\n');
  assert.deepEqual((await c.diags('components/Card.gshtml', (d) => d.length === 1))[0].range, range(2, 0, 2, 0));
  assert.deepEqual((await c.diags('app/other.goose', (d) => d.length === 1))[0].range, range(1, 0, 1, 0));
  assert.ok(!c.msgs.some((m) => m.params?.uri === c.uri('lib/util.goose')));
  await c.stop();
});

test('change runs lsp-gen with the buffer as overlay; close clears', async () => {
  const c = new Client();
  await c.start();
  c.open('app/page.html', PAGE);
  await c.diags('app/page.html', (d) => d.length === 2);
  const edited = '<p>{nme}</p>\n';
  c.notify('textDocument/didChange', { textDocument: { uri: c.uri('app/page.html'), version: 2 }, contentChanges: [{ text: edited }] });
  await c.waitFor(() => { try { return c.logs().length >= 3; } catch { return false; } });
  const calls = c.logs();
  assert.deepEqual(calls[0].overlay, null); // the run on `initialized`
  assert.equal(calls.at(-1).overlay.src, 'app/page.html');
  assert.equal(calls.at(-1).overlay.text, edited);
  assert.equal(calls.at(-1).check, false);
  const n = c.msgs.length;
  c.notify('textDocument/didClose', { textDocument: { uri: c.uri('app/page.html') } });
  await c.diags('app/page.html', (d) => d.length === 0, n);
  await c.stop();
});

for (const [name, mode] of [['child exits', 'exit'], ['child hangs on initialize', 'hang']]) {
  test(`fallback: ${name}`, async () => {
    const c = new Client({ env: { FAKE_GOOSE_MODE: mode } });
    await c.start();
    c.open('app/page.html', PAGE);
    const ds = await c.diags('app/page.html', (d) => d.length === 2 && d.every((x) => x.source === 'gweb'));
    assert.deepEqual(ds.map((d) => d.message).sort(), ['check says no', 'gweb says no']);
    const log = await c.waitFor((m) => m.method === 'window/logMessage');
    assert.match(log.params.message, /goose lsp unavailable/);
    assert.equal(c.msgs.filter((m) => m.method === 'window/logMessage').length, 1);
    assert.equal(c.logs().at(-1).check, true);
    // changes do not rerun in fallback; save does
    await new Promise((r) => setTimeout(r, 150)); // let queued runs settle
    const runs = c.logs().length;
    c.notify('textDocument/didChange', { textDocument: { uri: c.uri('app/page.html'), version: 2 }, contentChanges: [{ text: PAGE }] });
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(c.logs().length, runs);
    c.notify('textDocument/didSave', { textDocument: { uri: c.uri('app/page.html') } });
    await c.waitFor(() => c.logs().length > runs);
    await c.stop();
  });
}

test('fallback: goose binary missing', async () => {
  const c = new Client({ env: { GOOSE: '/nonexistent/goose' } });
  await c.start();
  const log = await c.waitFor((m) => m.method === 'window/logMessage');
  assert.match(log.params.message, /cannot start/);
  await c.stop();
});
