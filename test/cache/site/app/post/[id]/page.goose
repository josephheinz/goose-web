import std;
import net.http;
import gweb;

fn static_paths() -> u8[..1024][>..] {
    var paths: u8[..1024][>..] = [];
    paths.push("/post/1");
    paths.push("/post/2");
    return paths;
}
