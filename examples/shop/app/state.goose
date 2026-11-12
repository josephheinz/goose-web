// The todo list, owned by the main thread. Routes reach it with state::ask.
import std;

struct Todo { id: i64, title: u8[..200], done: bool }

enum Msg {
    List,
    Add { title: u8[..200] },
    Get { id: i64 },
    Update { id: i64, title: u8[..200], has_title: bool, done: bool, has_done: bool },
    Remove { id: i64 }
}

struct Reply { ok: bool, todos: Todo[] }

var todos: Todo[>..<];
var next_id = 1;

fn init() {
    for t in ["Feed the geese", "Write a route", "Run the benchmark"] {
        var title: u8[..200] = "";
        title.append(t);
        todos.push(Todo { id: next_id, title: title, done: false });
        next_id += 1;
    }
}

fn handle(msg: const Msg&) -> Reply {
    match msg {
        List => { return Reply { ok: true, todos: todos[..] }; },
        Add a => {
            todos.push(Todo { id: next_id, title: a.title, done: false });
            next_id += 1;
            return Reply { ok: true, todos: todos[todos.len - 1..] };
        },
        Get g => {
            let i = todos.find_index() { it.id == g.id };
            if i < 0 { return Reply { ok: false, todos: [] }; }
            return Reply { ok: true, todos: todos[i..i + 1] };
        },
        Update u => {
            let i = todos.find_index() { it.id == u.id };
            if i < 0 { return Reply { ok: false, todos: [] }; }
            if u.has_title { todos[i].title = u.title; }
            if u.has_done { todos[i].done = u.done; }
            return Reply { ok: true, todos: todos[i..i + 1] };
        },
        Remove r => {
            let i = todos.find_index() { it.id == r.id };
            if i < 0 { return Reply { ok: false, todos: [] }; }
            todos[i..todos.len - 1].move_from(todos[i + 1..]);
            todos.pop();
            return Reply { ok: true, todos: [] };
        },
    }
}
