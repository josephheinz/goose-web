namespace p5_plain; import std; import net.http; import web; import web.template; import web.meta; fn render(out: u8[>..]&, req: const http::Request&, ctx: const web::Ctx&) { out.append("<h2>Plain</h2>\n"); 
if true { out.append("<p>x</p>"); } out.append("\n"); 
}
