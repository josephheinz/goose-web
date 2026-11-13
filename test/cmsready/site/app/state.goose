import std;
import cms.store;
import cms.msg;

// The package's messages carry text of any size, so Msg is variable (VARIABLE_MSG); the app adds one variant (D9).
const VARIABLE_MSG = true;

enum Msg { Cms { m: cms::Msg.. } }
struct Reply { cms: cms::Reply }

fn init() { cms::init(); }

fn handle(msg: const Msg..&) -> Reply {
    match msg {
        Cms c => { return Reply { cms: cms::handle(c.m) }; },
    }
}
