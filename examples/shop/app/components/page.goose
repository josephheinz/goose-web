import std;
import net.http;
import web;
import Counter;
import TodoBox;

struct Props { counter: Counter::State, todos: TodoBox::State }

fn load(req: const http::Request&, ctx: web::Ctx&) -> Props {
    ctx.title.append("Components");
    var todos = TodoBox::State { .. };
    todos.next_id = 1;
    return Props { counter: Counter::State { count: 0 }, todos: todos };
}
