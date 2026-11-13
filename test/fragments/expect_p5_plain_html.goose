namespace p5_plain; import std; import net.http; import gweb; import gweb.site.template; import gweb.forms.valid; import gweb.site.meta; fn render(out: u8[>..]&, req: const http::Request&, ctx: const gweb::Ctx&) { out.append("<h2>Plain</h2>\n"); 
if true { out.append("<p>x</p>"); } out.append("\n"); 
}
