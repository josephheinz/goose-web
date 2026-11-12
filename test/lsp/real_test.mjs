// Against the real `goose lsp` and the built ./gweb. Skipped when either is missing.
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, cpSync, readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createReader, encodeMessage } from '../../editor/lsp/server.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const ROOT = join(here, '../..');
const SERVER = join(ROOT, 'editor/lsp/server.mjs');
const GWEB = join(ROOT, 'gweb');
const haveGoose = spawnSync('goose', ['version'], { stdio: 'ignore' }).status !== null;
const skip = !haveGoose ? 'goose not on PATH' : !existsSync(GWEB) ? 'ROOT/gweb is missing' : false;

const dir = skip ? null : mkdtempSync(join(tmpdir(), 'gweb-lsp-real-'));
const procs = [];
after(() => { procs.forEach((p) => p.kill()); if (dir) rmSync(dir, { recursive: true, force: true }); });

async function start() {
  const root = join(dir, 'notes' + procs.length);
  cpSync(join(ROOT, 'docs/site/tutorial/notes'), root, { recursive: true });
  const p = spawn(process.execPath, [SERVER, '--gweb', GWEB], { stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, GWEB_LSP_DEBOUNCE_MS: '100', GWEB_LSP_INIT_TIMEOUT_MS: '60000' } });
  procs.push(p);
  const msgs = [], pending = new Map();
  p.stdout.on('data', createReader((m) => { if (m.method === undefined) pending.get(m.id)?.(m); else msgs.push(m); }));
  const notify = (method, params) => p.stdin.write(encodeMessage({ method, params }));
  new Promise((r) => { pending.set(1, r); p.stdin.write(encodeMessage({ id: 1, method: 'initialize', params: { rootUri: pathToFileURL(root).href, capabilities: {} } })); });
  notify('initialized', {});
  const uri = (rel) => pathToFileURL(join(root, rel)).href;
  const src = (rel) => readFileSync(join(root, rel), 'utf8');
  let version = 1;
  const diags = async (rel, pred) => {
    for (let i = 0; i < 1500; i++) { // 30 s
      for (const m of msgs) {
        if (m.method !== 'textDocument/publishDiagnostics' || m.params.uri !== uri(rel)) continue;
        const hit = m.params.diagnostics.filter(pred);
        if (hit.length) return hit;
      }
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error('no diagnostic for ' + rel + '; got ' + JSON.stringify(msgs.filter((m) => m.method === 'textDocument/publishDiagnostics').map((m) => [m.params.uri.slice(-30), m.params.diagnostics.length])));
  };
  const open = (rel) => notify('textDocument/didOpen', { textDocument: { uri: uri(rel), languageId: 'x', version: 1, text: src(rel) } });
  const change = (rel, text) => notify('textDocument/didChange', { textDocument: { uri: uri(rel), version: ++version }, contentChanges: [{ text }] });
  return { diags, open, change, src, msgs, root };
}

const goose = (d) => d.source !== 'gweb' && d.severity === 1;

test('real: clean project has no goose errors', { skip, timeout: 120000 }, async () => {
  const c = await start();
  c.open('app/page.html');
  await new Promise((r) => setTimeout(r, 8000));
  const errs = c.msgs.filter((m) => m.method === 'textDocument/publishDiagnostics' && m.params.uri.endsWith('app/page.html')).flatMap((m) => m.params.diagnostics);
  assert.deepEqual(errs, []);
});

test('real: page.html error after a non-ASCII char, UTF-16 columns', { skip, timeout: 120000 }, async () => {
  const c = await start();
  c.open('app/page.html');
  const text = c.src('app/page.html').replace('{#if props.error.len > 0}', '<i>é</i>{#if props.error.len > "é"}');
  c.change('app/page.html', text);
  const [d] = await c.diags('app/page.html', goose);
  const line = text.split('\n').findIndex((l) => l.includes('> "é"'));
  assert.equal(d.range.start.line, line);
  assert.equal(d.range.end.line, line);
  const l = text.split('\n')[line];
  const s = l.indexOf('props.error.len'), e = l.indexOf('"é"') + 3;
  assert.equal(d.range.start.character, s);
  assert.equal(d.range.end.character, e);
});

test('real: component error maps to its line', { skip, timeout: 120000 }, async () => {
  const c = await start();
  c.open('components/CharCount.gshtml');
  const text = c.src('components/CharCount.gshtml').replace('<small>{s.text.len} / 200</small>', '<small>{s.text.len + "x"} / 200</small>');
  c.change('components/CharCount.gshtml', text);
  const [d] = await c.diags('components/CharCount.gshtml', goose);
  assert.equal(d.range.start.line, 5);
});

test('real: page.goose errors on line 1 and a later line', { skip, timeout: 120000 }, async () => {
  const c = await start();
  c.open('app/page.goose');
  const orig = c.src('app/page.goose');
  const late = orig.replace('ctx.title.append("Notes");', 'ctx.title.append(42);');
  c.change('app/page.goose', late);
  const [d1] = await c.diags('app/page.goose', goose);
  assert.equal(d1.range.start.line, orig.split('\n').findIndex((l) => l.includes('ctx.title.append')));
  const first = 'import nosuchmodule;\n' + late;
  c.change('app/page.goose', first);
  const ds = await c.diags('app/page.goose', (d) => goose(d) && d.range.start.line === 0);
  assert.ok(ds.length);
  const shifted = (await c.diags('app/page.goose', (d) => goose(d) && d.range.start.line === late.split('\n').findIndex((l) => l.includes('append(42)')) + 1));
  assert.ok(shifted.length);
});

test('real: a generated file not open in goose lsp is reread after it changes on disk', { skip, timeout: 120000 }, async () => {
  const c = await start();
  const f = join(c.root, 'app/state.goose');
  c.open('app/page.goose');
  await new Promise((r) => setTimeout(r, 6000)); // first generation, goose lsp up
  writeFileSync(f, readFileSync(f, 'utf8').replace('struct Reply {', 'struct Reply2 {'));
  c.change('app/page.goose', c.src('app/page.goose') + '\n');
  const ds = await c.diags('app/page.goose', (d) => goose(d) && /Reply/.test(d.message));
  assert.ok(ds.length);
});
