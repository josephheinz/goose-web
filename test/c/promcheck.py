"""Checks a file against the Prometheus text exposition format (the subset goose-web emits)."""
import re
import sys

NAME = re.compile(r'^[a-zA-Z_:][a-zA-Z0-9_:]*$')
LNAME = re.compile(r'^[a-zA-Z_][a-zA-Z0-9_]*$')
VALUE = re.compile(r'^([+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?|NaN|[+-]Inf)$')
TYPES = {'counter', 'gauge', 'histogram', 'summary', 'untyped'}


def parse_labels(s, ln, errs):
    """s starts after '{'. Returns (labels, rest after '}')."""
    labels = {}
    i = 0
    while True:
        if s[i:i + 1] == '}':
            return labels, s[i + 1:]
        m = re.match(r'([^=,}"\s]+)="', s[i:])
        if not m:
            errs.append(f'{ln}: bad label syntax near {s[i:i+20]!r}')
            return labels, ''
        k = m.group(1)
        if not LNAME.match(k):
            errs.append(f'{ln}: bad label name {k!r}')
        i += m.end()
        v = ''
        while True:
            if i >= len(s):
                errs.append(f'{ln}: unterminated label value')
                return labels, ''
            c = s[i]
            if c == '\\':
                if s[i + 1:i + 2] not in ('\\', '"', 'n'):
                    errs.append(f'{ln}: bad escape in label value')
                v += s[i:i + 2]
                i += 2
            elif c == '"':
                i += 1
                break
            else:
                v += c
                i += 1
        if k in labels:
            errs.append(f'{ln}: duplicate label {k}')
        labels[k] = v
        if s[i:i + 1] == ',':
            i += 1
        elif s[i:i + 1] != '}':
            errs.append(f'{ln}: expected , or }} after label value')
            return labels, ''


def base_of(name, types):
    for suf in ('_bucket', '_sum', '_count'):
        if name.endswith(suf) and types.get(name[:-len(suf)]) == 'histogram':
            return name[:-len(suf)], suf
    return name, ''


def main(path):
    errs = []
    types = {}
    seen_sample = set()
    hist = {}  # (base, labels-without-le) -> dict
    text = open(path, encoding='utf-8').read()
    if text and not text.endswith('\n'):
        errs.append('missing final newline')
    for ln, line in enumerate(text.split('\n')[:-1] if text.endswith('\n') else text.split('\n'), 1):
        if line == '':
            errs.append(f'{ln}: empty line')
            continue
        if line.startswith('#'):
            parts = line.split(' ', 3)
            if len(parts) >= 3 and parts[1] in ('HELP', 'TYPE'):
                if not NAME.match(parts[2]):
                    errs.append(f'{ln}: bad metric name {parts[2]!r}')
                if parts[1] == 'TYPE':
                    t = parts[3] if len(parts) > 3 else ''
                    if t not in TYPES:
                        errs.append(f'{ln}: bad type {t!r}')
                    if parts[2] in types:
                        errs.append(f'{ln}: duplicate TYPE for {parts[2]}')
                    if parts[2] in seen_sample:
                        errs.append(f'{ln}: TYPE after samples for {parts[2]}')
                    types[parts[2]] = t
            continue
        m = re.match(r'([^\s{]+)', line)
        name = m.group(1)
        if not NAME.match(name):
            errs.append(f'{ln}: bad metric name {name!r}')
        rest = line[m.end():]
        labels = {}
        if rest.startswith('{'):
            labels, rest = parse_labels(rest[1:], ln, errs)
        vals = rest.split()
        if not vals or not VALUE.match(vals[0]) or len(vals) > 2:
            errs.append(f'{ln}: bad sample value in {line!r}')
            continue
        base, suf = base_of(name, types)
        if base not in types:
            errs.append(f'{ln}: sample {name} before its TYPE')
        seen_sample.add(base)
        if types.get(base) == 'histogram':
            key = (base, tuple(sorted((k, v) for k, v in labels.items() if k != 'le')))
            h = hist.setdefault(key, {'buckets': [], 'sum': None, 'count': None})
            val = float(vals[0].replace('+Inf', 'inf'))
            if suf == '_bucket':
                if 'le' not in labels:
                    errs.append(f'{ln}: bucket without le')
                else:
                    h['buckets'].append((labels['le'], val, ln))
            elif suf == '_sum':
                h['sum'] = val
            elif suf == '_count':
                h['count'] = val
            else:
                errs.append(f'{ln}: histogram sample without suffix')
    for (base, lab), h in hist.items():
        where = f'{base}{dict(lab)}'
        b = h['buckets']
        if not b:
            errs.append(f'{where}: no buckets')
            continue
        if b[-1][0] != '+Inf':
            errs.append(f'{where}: last bucket is not +Inf')
        les = [float(x[0].replace('+Inf', 'inf')) for x in b]
        if les != sorted(les) or len(set(les)) != len(les):
            errs.append(f'{where}: bucket bounds not increasing')
        counts = [x[1] for x in b]
        if counts != sorted(counts):
            errs.append(f'{where}: buckets not cumulative')
        if h['sum'] is None:
            errs.append(f'{where}: missing _sum')
        if h['count'] is None:
            errs.append(f'{where}: missing _count')
        elif counts and h['count'] != counts[-1]:
            errs.append(f'{where}: _count != +Inf bucket')
    for e in errs:
        print(f'promcheck {path}: {e}')
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
