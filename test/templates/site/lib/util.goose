namespace util;
import std;
fn stars(out: u8[>..]&, n: i64) { for i in n { out.push(42); } }
fn hr(out: u8[>..]&) { out.append("<hr>"); }
