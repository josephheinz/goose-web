#!/usr/bin/env node
// gweb language server (DESIGN-ADDENDUM-18, D2/D3): diagnostics for .gshtml, page.html and
// page.goose, by proxying `goose lsp` over the generated files and mapping positions back.
import { spawn } from 'node:child_process';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const LSP_DIR = '.gooseweb.lsp';

// ---- framing ----------------------------------------------------------------------------

export const encodeMessage = (obj) => {
  const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...obj }));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
};

export function createReader(onMessage) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const end = buf.indexOf('\r\n\r\n');
      if (end < 0) return;
      const m = /content-length:\s*(\d+)/i.exec(buf.toString('latin1', 0, end));
      const start = end + 4;
      if (!m) { buf = buf.subarray(start); continue; }
      const stop = start + Number(m[1]);
      if (buf.length < stop) return;
      const body = buf.toString('utf8', start, stop);
      buf = buf.subarray(stop);
      try { onMessage(JSON.parse(body)); } catch (e) { console.error('lsp: bad message:', e.message); }
    }
  };
}

// ---- columns ----------------------------------------------------------------------------

export function byteToUtf16(text, byteCol) {
  let bytes = 0, units = 0;
  for (const ch of text) {
    if (bytes >= byteCol) break;
    bytes += Buffer.byteLength(ch);
    units += ch.length;
  }
  return units;
}

export function utf16ToByte(text, col) {
  let bytes = 0, units = 0;
  for (const ch of text) {
    if (units >= col) break;
    units += ch.length;
    bytes += Buffer.byteLength(ch);
  }
  return bytes;
}

// ---- srcmap.txt (D1) --------------------------------------------------------------------

// Returns { files: Map<gen, { src, lines: Map<genLine, { srcLine, segs: [{ g, s, len }] }> }> }.
export function parseSrcmap(text) {
  const rows = text.split('\n');
  if (rows[0].trim() !== 'gwmap 1') throw new Error(`unsupported srcmap header: ${rows[0]}`);
  const files = new Map();
  let cur = null;
  for (const row of rows.slice(1)) {
    const f = /^file (\S+) (.+)$/.exec(row);
    if (f) { cur = { src: f[2].trim(), lines: new Map() }; files.set(f[1], cur); continue; }
    const p = row.trim().split(/\s+/);
    if (p[0] !== 'L' || !cur) continue;
    const segs = p.slice(3).map((s) => { const [g, c, len] = s.split(':').map(Number); return { g, s: c, len }; });
    cur.lines.set(Number(p[1]), { srcLine: Number(p[2]), segs });
  }
  return { files };
}

// map.txt: `GEN\tSRC` per line. Adds files that srcmap.txt has no `file` record for.
export function mergeMapTxt(map, text) {
  for (const row of text.split('\n')) {
    const [gen, src] = row.split('\t');
    if (gen && src && !map.files.has(gen)) map.files.set(gen, { src: src.trim(), lines: new Map() });
  }
  return map;
}

const lineCount = (text) => Math.max(1, text.split('\n').length - (text.endsWith('\n') ? 1 : 0));

// Lines are 1-based, columns are 0-based bytes. genText and srcText are whole files; srcText
// may be omitted (no clamping). Returns { line, col } in the source.
export function mapPosition(map, genFile, genLine, genByteCol, genText, srcText) {
  const rec = map.files.get(genFile)?.lines.get(genLine);
  let line = genLine, col = 0;
  if (rec) {
    line = rec.srcLine;
    const segs = rec.segs;
    let seg = null;
    for (const s of segs) if (s.g <= genByteCol) seg = s;
    if (seg) col = genByteCol < seg.g + seg.len ? seg.s + (genByteCol - seg.g) : seg.s + seg.len;
  } else {
    const m = /\/\/ gw:line (\d+)/.exec(genText?.split('\n')[genLine - 1] ?? '');
    if (m) line = Number(m[1]);
  }
  if (srcText !== undefined) {
    line = Math.min(line, lineCount(srcText));
    col = Math.min(col, Buffer.byteLength((srcText.split('\n')[line - 1] ?? '').replace(/\r$/, '')));
  }
  return { line, col };
}

// ---- gweb stderr ------------------------------------------------------------------------

// `path:line: error: msg`, `path:line: warning: msg`, `path: error: msg`. Line 0 or none -> 1.
export function parseGwebDiagnostics(stderrText, root) {
  const out = [];
  for (const row of stderrText.split('\n')) {
    const m = /^(.+?)(?::(\d+))?: (error|warning): (.*)$/.exec(row.replace(/\r$/, ''));
    if (!m) continue;
    let path = m[1];
    if (root && path.startsWith(root + '/')) path = path.slice(root.length + 1);
    out.push({ path, line: Math.max(1, Number(m[2] ?? 1)), severity: m[3] === 'error' ? 1 : 2, message: m[4] });
  }
  return out;
}

// ---- server -----------------------------------------------------------------------------

const taken = (rel) => /^components\/[^/]+\.gshtml$/.test(rel) || /^app\/.+\.(html|goose)$/.test(rel);

function runServer() {
  const argv = process.argv;
  const gweb = (argv.includes('--gweb') ? argv[argv.indexOf('--gweb') + 1] : null) || process.env.GWEB_BIN || 'gweb';
  const debounceMs = Number(process.env.GWEB_LSP_DEBOUNCE_MS ?? 250);
  const initMs = Number(process.env.GWEB_LSP_INIT_TIMEOUT_MS ?? 10000);
  const tmpDir = mkdtempSync(join(tmpdir(), 'gweb-lsp-'));

  let root = process.cwd(), editorEnc = 'utf-16', childEnc = 'utf-16';
  let stopping = false, fallback = false;
  const docs = new Map();            // uri -> { uri, rel, text }
  const gwebDiags = new Map();       // rel -> [{ line, severity, message }]
  let maps = { files: new Map() };
  const genIndex = new Map();        // abs gen path -> { gen, src }
  const srcGens = new Map();         // rel src -> [gen]
  const childDocs = new Map();       // abs gen path -> { version, text }
  const childDiags = new Map();      // abs gen path -> LSP diagnostics

  const send = (obj) => process.stdout.write(encodeMessage(obj));
  const log = (m) => console.error('gweb-lsp:', m);
  const logMessage = (type, message) => send({ method: 'window/logMessage', params: { type, message } });

  // -- child: goose lsp --
  let child = null, nextId = 1, readyResolve;
  const pending = new Map();
  const ready = new Promise((r) => { readyResolve = r; });
  const toChild = (obj) => { if (child && !child.stdin.destroyed) child.stdin.write(encodeMessage(obj)); };
  const notifyChild = (method, params) => toChild({ method, params });
  const requestChild = (method, params) => new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    toChild({ id, method, params });
  });

  function enterFallback(reason) {
    if (fallback || stopping) return;
    fallback = true;
    logMessage(2, `goose lsp unavailable (${reason}); using gweb lsp-gen --check on open and save`);
    child?.kill();
    readyResolve(false);
    childDiags.clear();
    if (docs.size) schedule([...docs.keys()].at(-1));
  }

  function startChild() {
    const bin = process.env.GOOSE || 'goose';
    child = spawn(bin, ['lsp'], { stdio: ['pipe', 'pipe', 'inherit'] });
    child.on('error', (e) => enterFallback(`cannot start ${bin}: ${e.message}`));
    child.on('exit', (code, sig) => enterFallback(`${bin} exited (${code ?? sig})`));
    child.stdin.on('error', () => {});
    child.stdout.on('data', createReader(onChild));
    const timer = setTimeout(() => enterFallback(`no initialize reply within ${initMs} ms`), initMs);
    const rootUri = pathToFileURL(root).href;
    requestChild('initialize', {
      processId: process.pid, rootUri, workspaceFolders: [{ uri: rootUri, name: 'root' }],
      capabilities: { general: { positionEncodings: ['utf-8', 'utf-16'] }, textDocument: { publishDiagnostics: {} } },
    }).then((res) => {
      clearTimeout(timer);
      if (fallback) return;
      childEnc = res?.result?.capabilities?.positionEncoding ?? 'utf-16';
      notifyChild('initialized', {});
      readyResolve(true);
    });
  }

  function onChild(msg) {
    if (msg.method === undefined) { pending.get(msg.id)?.(msg); pending.delete(msg.id); return; }
    if (msg.id !== undefined) { // a request from goose lsp: nothing to offer
      const result = msg.method === 'workspace/configuration' ? (msg.params?.items ?? []).map(() => null) : null;
      toChild({ id: msg.id, result });
    } else if (msg.method === 'textDocument/publishDiagnostics') {
      const path = fileURLToPath(msg.params.uri);
      childDiags.set(path, msg.params.diagnostics ?? []);
      const info = genIndex.get(path);
      for (const d of docs.values()) if (info && d.rel === info.src) publish(d);
    }
  }

  // -- generation --
  let running = false, queued = false, timer = null, lastUri = null;

  function schedule(uri) {
    lastUri = uri;
    clearTimeout(timer);
    timer = setTimeout(kick, debounceMs);
  }

  function kick() {
    if (running) { queued = true; return; }
    run().catch((e) => log(e.stack));
  }

  async function run() {
    running = true; queued = false;
    const doc = docs.get(lastUri);
    lastUri = null;
    try { await generate(doc); } finally { running = false; if (queued) kick(); }
  }

  const exec = (args) => new Promise((resolve) => {
    let err = '';
    const p = spawn(gweb, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', (e) => { log(`cannot run ${gweb}: ${e.message}`); resolve(err); });
    p.on('close', () => resolve(err));
  });

  async function generate(doc) {
    const args = ['-C', root, 'lsp-gen'];
    if (fallback) args.push('--check');
    if (doc) {
      const tmp = join(tmpDir, 'overlay');
      writeFileSync(tmp, doc.text);
      args.push('--overlay', doc.rel, tmp);
    }
    const diags = parseGwebDiagnostics(await exec(args), root);
    gwebDiags.clear();
    for (const d of diags) gwebDiags.set(d.path, [...(gwebDiags.get(d.path) ?? []), d]);
    loadMaps();
    if (!fallback && (await ready)) syncChild();
    for (const d of docs.values()) publish(d);
  }

  function loadMaps() {
    const dir = join(root, LSP_DIR);
    const read = (f) => { try { return readFileSync(join(dir, f), 'utf8'); } catch { return null; } };
    try { maps = parseSrcmap(read('srcmap.txt') ?? 'gwmap 1\n'); } catch (e) { log(e.message); maps = { files: new Map() }; }
    mergeMapTxt(maps, read('map.txt') ?? '');
    genIndex.clear(); srcGens.clear();
    for (const [gen, { src }] of maps.files) {
      genIndex.set(join(dir, gen), { gen, src });
      srcGens.set(src, [...(srcGens.get(src) ?? []), gen]);
    }
  }

  function syncChild() {
    for (const doc of docs.values()) {
      for (const gen of srcGens.get(doc.rel) ?? []) {
        const path = join(root, LSP_DIR, gen);
        let text;
        try { text = readFileSync(path, 'utf8'); } catch { continue; }
        const open = childDocs.get(path);
        const uri = pathToFileURL(path).href;
        if (!open) {
          childDocs.set(path, { version: 1, text });
          notifyChild('textDocument/didOpen', { textDocument: { uri, languageId: 'goose', version: 1, text } });
        } else if (open.text !== text) {
          open.version++; open.text = text;
          notifyChild('textDocument/didChange', { textDocument: { uri, version: open.version }, contentChanges: [{ text }] });
        }
      }
    }
  }

  // -- publishing --
  function mapChildDiag(d, path, doc) {
    const info = genIndex.get(path), gen = childDocs.get(path)?.text;
    if (!info || gen === undefined) return null;
    const genLines = gen.split('\n'), srcLines = doc.text.split('\n');
    const pos = (p) => {
      const gcol = childEnc === 'utf-8' ? p.character : utf16ToByte(genLines[p.line] ?? '', p.character);
      const r = mapPosition(maps, info.gen, p.line + 1, gcol, gen, doc.text);
      const text = (srcLines[r.line - 1] ?? '').replace(/\r$/, '');
      return { line: r.line - 1, character: editorEnc === 'utf-8' ? r.col : byteToUtf16(text, r.col) };
    };
    const start = pos(d.range.start);
    let end = pos(d.range.end);
    if (end.line < start.line || (end.line === start.line && end.character < start.character)) end = start;
    const { relatedInformation, ...rest } = d;
    return { ...rest, range: { start, end } };
  }

  function publish(doc) {
    const lines = doc.text.split('\n');
    const diagnostics = (gwebDiags.get(doc.rel) ?? []).map((d) => {
      const line = Math.min(d.line, lines.length) - 1;
      const text = lines[line].replace(/\r$/, '');
      const end = editorEnc === 'utf-8' ? Buffer.byteLength(text) : text.length;
      return { range: { start: { line, character: 0 }, end: { line, character: end } }, severity: d.severity, source: 'gweb', message: d.message };
    });
    if (!fallback) {
      for (const gen of srcGens.get(doc.rel) ?? []) {
        const path = join(root, LSP_DIR, gen);
        for (const d of childDiags.get(path) ?? []) {
          const m = mapChildDiag(d, path, doc);
          if (m) diagnostics.push(m);
        }
      }
    }
    send({ method: 'textDocument/publishDiagnostics', params: { uri: doc.uri, diagnostics } });
  }

  // -- editor --
  function relOf(uri) {
    let path;
    try { path = fileURLToPath(uri); } catch { return null; }
    const rel = relative(root, path).split(sep).join('/');
    return rel.startsWith('..') || !taken(rel) ? null : rel;
  }

  function open(uri, text) {
    const rel = relOf(uri);
    if (!rel) return;
    docs.set(uri, { uri, rel, text });
    schedule(uri);
  }

  function close(uri) {
    const doc = docs.get(uri);
    if (!doc) return;
    docs.delete(uri);
    send({ method: 'textDocument/publishDiagnostics', params: { uri, diagnostics: [] } });
    for (const gen of srcGens.get(doc.rel) ?? []) {
      const path = join(root, LSP_DIR, gen);
      if (childDocs.delete(path)) notifyChild('textDocument/didClose', { textDocument: { uri: pathToFileURL(path).href } });
      childDiags.delete(path);
    }
  }

  function onEditor(msg) {
    const { method, params, id } = msg;
    if (method === undefined) return;
    const reply = (result) => send({ id, result });
    switch (method) {
      case 'initialize': {
        const dir = params.rootUri ?? params.workspaceFolders?.[0]?.uri;
        root = dir ? fileURLToPath(dir) : params.rootPath ?? process.cwd();
        root = root.replace(/(.)\/+$/, '$1');
        if (params.capabilities?.general?.positionEncodings?.includes('utf-8')) editorEnc = 'utf-8';
        startChild();
        return reply({
          capabilities: { positionEncoding: editorEnc, textDocumentSync: { openClose: true, change: 1, save: { includeText: false } } },
          serverInfo: { name: 'gweb-lsp' },
        });
      }
      case 'initialized': return kick();
      case 'shutdown': stopping = true; return reply(null);
      case 'exit': return finish(stopping ? 0 : 1);
      case 'textDocument/didOpen': return open(params.textDocument.uri, params.textDocument.text);
      case 'textDocument/didChange': {
        const doc = docs.get(params.textDocument.uri);
        if (!doc) return;
        doc.text = params.contentChanges.at(-1).text;
        if (!fallback) schedule(doc.uri);
        return;
      }
      case 'textDocument/didSave': {
        const doc = docs.get(params.textDocument.uri);
        if (!doc) return;
        if (params.text !== undefined) doc.text = params.text;
        return schedule(doc.uri);
      }
      case 'textDocument/didClose': return close(params.textDocument.uri);
      default: if (id !== undefined) send({ id, error: { code: -32601, message: `method not found: ${method}` } });
    }
  }

  function finish(code) {
    stopping = true;
    if (child && !child.killed) {
      toChild({ id: nextId++, method: 'shutdown' });
      notifyChild('exit', null);
      child.kill();
    }
    rmSync(tmpDir, { recursive: true, force: true });
    process.exit(code);
  }

  process.stdin.on('data', createReader(onEditor));
  process.stdin.on('end', () => finish(stopping ? 0 : 1));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) runServer();
