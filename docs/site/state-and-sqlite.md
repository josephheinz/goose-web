# State and SQLite

Workers do not share memory. State that all workers must see lives in
`app/state.goose`, owned by the main thread. A worker sends a message and
waits for the reply, at most 5 seconds.

```goose
// app/state.goose
struct Note { id: i64, text: u8[..200] }
struct Msg { add: bool, text: u8[..200] }
struct Reply { notes: Note[] }

var notes: Note[>..<];
var next_id = 1;

fn handle(msg: const Msg&) -> Reply {
    if msg.add {
        notes.push(Note { id: next_id, text: msg.text });
        next_id += 1;
    }
    return Reply { notes: notes[..] };
}
```

```goose
// in a page or route
let reply, ok = state::ask(ctx, state::Msg { add: false, text: "" });
if !ok { /* timeout: answer 503 */ }
```

## Rules

- `Msg`, `Reply` and `fn handle(msg: const Msg&) -> Reply` are required.
  `fn init()` is optional and runs before the workers start.
- `handle` runs one message at a time. It needs no locks.
- A worker blocked in `state::ask` stalls its other connections. Keep
  `handle` short.
- An abort in `handle` ends the process.

## SQLite

`import sqlite;` in a `lib/` or `app/` file. `gweb` declares the package.

- Each worker opens its own connection to read:
  `sqlite::local(path)`, or `sqlite::local(path, sqlite::Mode.QueryOnly)`
  for a database the app writes.
- Workers never write. The owner holds the one writer, `sqlite::writer(path)`.
  A worker sends a `Msg`, and the owner runs the write as one transaction.
- `init` runs `sqlite::migrate` and exits if it fails.
- Map `sqlite::busy` to 503, `sqlite::constraint` to 409 and a missing row
  to 404.
- Commits use `synchronous=NORMAL`. Pass `durable: true` to `writer` to
  survive a power loss.

Full reference: [README](../../README.md#sqlite).
