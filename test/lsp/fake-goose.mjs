#!/usr/bin/env node
// Stand-in for `goose lsp`: one diagnostic per opened generated file at a known place.
// FAKE_GOOSE_ENC picks the position encoding; FAKE_GOOSE_MODE=exit|hang breaks initialize.
import { createReader, encodeMessage } from '../../editor/lsp/server.mjs';

const mode = process.env.FAKE_GOOSE_MODE;
const send = (o) => process.stdout.write(encodeMessage(o));
const at = (line, s, e) => ({ start: { line, character: s }, end: { line, character: e } });

function diag(uri) {
  const range = uri.endsWith('/page_html.goose') ? at(0, 11, 14) : uri.endsWith('/Card.goose') ? at(1, 0, 1) : at(1, 0, 3);
  return { range, severity: 1, source: 'goose', message: 'goose: ' + uri.split('/').pop() };
}

process.stdin.on('data', createReader((m) => {
  if (m.method === 'initialize') {
    if (mode === 'exit') process.exit(3);
    if (mode === 'hang') return;
    send({ id: m.id, result: { capabilities: { positionEncoding: process.env.FAKE_GOOSE_ENC ?? 'utf-16' } } });
  } else if (m.method === 'textDocument/didOpen' || m.method === 'textDocument/didChange') {
    const uri = m.params.textDocument.uri;
    send({ method: 'textDocument/publishDiagnostics', params: { uri, diagnostics: [diag(uri)] } });
  } else if (m.method === 'shutdown') send({ id: m.id, result: null });
  else if (m.method === 'exit') process.exit(0);
}));
