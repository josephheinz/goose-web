// The owner's messages: the host's state.goose wraps Msg in one variant and calls handle (D9).
namespace cms;

import std;

enum Msg {
    Save { id: i64, props: u8[], widget: u8[] },
    Create { channel: i64, path: u8[], props: u8[], widget: u8[] },
    MediaAdd { name: u8[], size: i64 },
}
struct Reply { ok: bool, id: i64 }

fn handle(m: const Msg..&) -> Reply {
    match m {
        Save s => { return Reply { ok: save_node(s.id, s.props, s.widget), id: s.id }; },
        Create c => {
            let id = create_node(c.channel, c.path, c.props, c.widget);
            return Reply { ok: id > 0, id: id };
        },
        MediaAdd a => {
            let id = media_add(a.name, a.size);
            return Reply { ok: id > 0, id: id };
        },
    }
}
