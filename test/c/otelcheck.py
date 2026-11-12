#!/usr/bin/env python3
"""otelcheck.py FILE ASSERT...  Checks a request saved by fake_collector.py. Each ASSERT is PATH=VALUE:
path=/v1/traces, header:name=value, or a dotted path into the parsed OTLP body (list indexes are numbers),
e.g. resourceSpans.0.scopeSpans.0.spans.0.kind=2. len:PATH=N checks a list length; has:PATH=1 / has:PATH=0 checks
presence; attr:SPAN_INDEX:KEY=VALUE checks a span attribute (string, or int as its decimal string)."""
import json, sys

rec = json.load(open(sys.argv[1]))
body = json.loads(rec["body"])
SPANS = ["resourceSpans", 0, "scopeSpans", 0, "spans"]

def walk(path):
    cur = body
    for part in path.split("."):
        cur = cur[int(part)] if isinstance(cur, list) else cur[part]
    return cur

bad = 0
for a in sys.argv[2:]:
    k, _, v = a.partition("=")
    try:
        if k == "path": got = rec["path"]
        elif k.startswith("header:"): got = rec["headers"].get(k[7:].lower())
        elif k.startswith("len:"): got = str(len(walk(k[4:])))
        elif k.startswith("has:"):
            try: walk(k[4:]); got = "1"
            except (KeyError, IndexError): got = "0"
        elif k.startswith("attr:"):
            _, idx, key = k.split(":", 2)
            span = body["resourceSpans"][0]["scopeSpans"][0]["spans"][int(idx)]
            vals = {x["key"]: x["value"] for x in span["attributes"]}
            got = None
            if key in vals:
                (got,) = vals[key].values()
        else:
            got = walk(k)
            if not isinstance(got, str): got = json.dumps(got)
    except (KeyError, IndexError) as e:
        got = "<missing %s>" % e
    if got != v:
        print("otelcheck: %s: want %r got %r" % (k, v, got)); bad += 1
sys.exit(1 if bad else 0)
