import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSrcmap, mergeMapTxt, mapPosition, byteToUtf16, utf16ToByte, parseGwebDiagnostics } from '../../editor/lsp/server.mjs';

const MAP = `gwmap 1
file about_html.goose app/about/page.html
L 1 1 0:0:0 182:5:7
L 4 4 0:0:0 31:9:12 60:30:4
file about.goose app/about/page.goose
L 1 1 0:0:0 15:0:30
file Card.goose components/Card.gshtml
`;
const map = parseSrcmap(MAP);
const SRC = 'one\ntwo\nthree\n' + 'f'.repeat(40) + '\n';
const pos = (f, l, c, gen = '', src = SRC) => mapPosition(map, f, l, c, gen, src);

test('parse', () => {
  assert.deepEqual([...map.files.keys()], ['about_html.goose', 'about.goose', 'Card.goose']);
  assert.equal(map.files.get('about.goose').src, 'app/about/page.goose');
  assert.deepEqual(map.files.get('about_html.goose').lines.get(4), {
    srcLine: 4, segs: [{ g: 0, s: 0, len: 0 }, { g: 31, s: 9, len: 12 }, { g: 60, s: 30, len: 4 }],
  });
  assert.throws(() => parseSrcmap('gwmap 2\n'));
});

test('exact columns inside a segment', () => {
  assert.deepEqual(pos('about_html.goose', 4, 31), { line: 4, col: 9 });
  assert.deepEqual(pos('about_html.goose', 4, 35), { line: 4, col: 13 });
});

test('columns past a segment clamp to its end', () => {
  const src = 'x\nx\nx\n' + ' '.repeat(60) + '\n';
  assert.deepEqual(pos('about_html.goose', 4, 50, '', src), { line: 4, col: 21 });
  assert.deepEqual(pos('about_html.goose', 4, 59, '', src), { line: 4, col: 21 });
  assert.deepEqual(pos('about_html.goose', 4, 70, '', src), { line: 4, col: 34 });
});

test('before the first segment maps to 0; zero-length anchors', () => {
  assert.deepEqual(pos('about_html.goose', 4, 5), { line: 4, col: 0 });
  assert.deepEqual(pos('about_html.goose', 1, 3), { line: 1, col: 0 });
  assert.deepEqual(pos('about_html.goose', 1, 190, '', 'x'.repeat(20)), { line: 1, col: 12 });
  assert.deepEqual(pos('about_html.goose', 1, 190), { line: 1, col: 3 }); // clamped to the source line
  assert.deepEqual(pos('about.goose', 1, 20, '', 'x'.repeat(30)), { line: 1, col: 5 });
});

test('identity lines, no record', () => {
  assert.deepEqual(pos('about_html.goose', 2, 9), { line: 2, col: 0 });
  assert.deepEqual(pos('Card.goose', 3, 4), { line: 3, col: 0 });
  assert.deepEqual(pos('unknown.goose', 2, 4), { line: 2, col: 0 });
});

test('// gw:line N', () => {
  const gen = 'a\nb\nlet x = 1; // gw:line 4\n';
  assert.deepEqual(pos('Card.goose', 3, 5, gen), { line: 4, col: 0 });
});

test('lines past the source end clamp to the last line', () => {
  assert.deepEqual(pos('Card.goose', 9, 2), { line: 4, col: 0 });
  assert.deepEqual(pos('Card.goose', 9, 2, '', 'a\nb'), { line: 2, col: 0 });
  assert.deepEqual(pos('Card.goose', 9, 2, '', ''), { line: 1, col: 0 });
});

test('map.txt fills in files without records', () => {
  mergeMapTxt(map, 'Card.goose\tignored\nother.goose\tapp/other.goose\n\n');
  assert.equal(map.files.get('Card.goose').src, 'components/Card.gshtml');
  assert.equal(map.files.get('other.goose').src, 'app/other.goose');
  assert.deepEqual(pos('other.goose', 2, 3), { line: 2, col: 0 });
});

test('utf-8 <-> utf-16 columns', () => {
  const t = 'aé中\u{1F600}b'; // 1, 2, 3, 4 bytes; 1, 1, 1, 2 units
  const bytes = [0, 1, 3, 6, 10, 11], units = [0, 1, 2, 3, 5, 6];
  bytes.forEach((b, i) => {
    assert.equal(byteToUtf16(t, b), units[i]);
    assert.equal(utf16ToByte(t, units[i]), b);
  });
  assert.equal(byteToUtf16(t, 99), 6);
  assert.equal(utf16ToByte(t, 99), 11);
  assert.equal(byteToUtf16(t, 2), 2); // inside a character: rounds up
});

test('column clamp uses source bytes', () => {
  assert.deepEqual(mapPosition(map, 'about.goose', 1, 100, '', 'éé\n'), { line: 1, col: 4 });
});

test('gweb diagnostics', () => {
  const d = parseGwebDiagnostics([
    'app/page.html:3: error: bad {x}',
    'components/A.gshtml:0: warning: odd',
    'lib/m.goose: error: whole file',
    '/r/app/b.html:7: error: abs: path',
    'noise',
    'gweb: check passed',
  ].join('\n'), '/r');
  assert.deepEqual(d, [
    { path: 'app/page.html', line: 3, severity: 1, message: 'bad {x}' },
    { path: 'components/A.gshtml', line: 1, severity: 2, message: 'odd' },
    { path: 'lib/m.goose', line: 1, severity: 1, message: 'whole file' },
    { path: 'app/b.html', line: 7, severity: 1, message: 'abs: path' },
  ]);
});
