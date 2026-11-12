#!/usr/bin/env node
// Stand-in for `gweb -C ROOT lsp-gen [--check] [--overlay SRC TMP]`: writes a fixed
// .gooseweb.lsp/ tree, logs its call to ROOT/.fake-gweb.log, prints canned errors on stderr.
import { mkdirSync, writeFileSync, appendFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const a = process.argv.slice(2);
const root = a[a.indexOf('-C') + 1];
const check = a.includes('--check');
const ov = a.indexOf('--overlay');
const overlay = ov < 0 ? null : { src: a[ov + 1], text: readFileSync(a[ov + 2], 'utf8') };
appendFileSync(join(root, '.fake-gweb.log'), JSON.stringify({ check, overlay }) + '\n');

const dir = join(root, '.gooseweb.lsp');
mkdirSync(dir, { recursive: true });
const files = {
  'main.goose': '// main\n',
  'page_html.goose': 'out.append(nme);\n',
  'Card.goose': '// card\nx = 1; // gw:line 3\n',
  'other.goose': '// one\n// two\n',
  'srcmap.txt': 'gwmap 1\nfile page_html.goose app/page.html\nL 1 1 0:0:0 11:7:3\nfile Card.goose components/Card.gshtml\n',
  'map.txt': 'page_html.goose\tapp/page.html\nCard.goose\tcomponents/Card.gshtml\nother.goose\tapp/other.goose\n',
};
for (const [n, t] of Object.entries(files)) writeFileSync(join(dir, n), t);

process.stderr.write('app/page.html:1: error: gweb says no\n');
if (check) process.stderr.write('app/page.html: error: check says no\ncomponents/Card.gshtml:2: warning: check warn\n');
