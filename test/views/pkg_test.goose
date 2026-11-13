import std;
import net.http;
import gweb;
import gweb.testing;
import views;

fn test_package_view(t: gweb::Tester&) {
    gweb::expect(t, views::widgets_count() == 3, "the package's view joins the project's");
    gweb::expect(t, views::widgets_index("Banner") == 0, "Banner sorts first");
    var d: u8[>..] = [];
    gweb::expect(t, views::widgets_defaults("Banner", d) && d == "{\"text\":\"banner\"}", "and has its codec");
}
