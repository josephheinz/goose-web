// goose-web lifecycle for components with @watch, @mount, @unmount or @every, imported by their modules as ./gwl.js.
// client/gwl.min.js is this file minified by client/build.sh.
import { defs, hooks, run, state } from "./gwi.js";

const eager = new Set(), live = new Map(), prev = hooks.a;

// A root is stopped once: its intervals end and its @unmount entries run (its state is still in gwi.js).
function stop(r) {
  const e = live.get(r);
  if (!e) return;
  live.delete(r);
  e[1].map(clearInterval);
  e[0].l?.u.map((k) => run(r, e[0], k, []));
}

// Starts each root of an eager component once: state, the watches with every bit, the mounts, the intervals.
function scan() {
  for (const n of eager) {
    for (const r of document.querySelectorAll(`[data-component="${n}"]`)) {
      if (live.has(r)) continue;
      const d = defs[n], ids = [];
      live.set(r, [d, ids]);
      state(r);
      if (d.w) run(r, d, 0, [], 0, 0, -1);
      d.l?.m.map((k) => run(r, d, k, []));
      d.l?.v.map(([ms, k]) => ids.push(setInterval(() => r.isConnected ? run(r, d, k, []) : stop(r), ms)));
    }
  }
  for (const r of [...live.keys()]) r.isConnected || stop(r);
}

hooks.a = () => { prev?.(); scan(); };

export function life(name) {
  eager.add(name);
  scan();
}
