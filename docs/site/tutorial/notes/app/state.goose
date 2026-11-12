import std;

struct Note { id: i64, text: u8[..200] }
struct Msg { add: bool, text: u8[..200] }
struct Reply { notes: Note[] }

var notes: Note[>..<];
var next_id = 1;

// Runs on the main thread, one message at a time.
fn handle(msg: const Msg&) -> Reply {
    if msg.add {
        notes.push(Note { id: next_id, text: msg.text });
        next_id += 1;
    }
    return Reply { notes: notes[..] };
}
