// Makes from's children match to's, without keys. value and checked sync after recursing so a <select>
// has its new options first; the focused control keeps its value unless force is set.
function morph(from, to, force) {
  let a = from.firstChild, b = to.firstChild;
  while (b) {
    const nb = b.nextSibling;
    if (!a) { from.append(b); b = nb; continue; }
    const na = a.nextSibling;
    if (a.nodeName != b.nodeName) a.replaceWith(b);
    else if (a.nodeType != 1) { if (a.data != b.data) a.data = b.data; }
    else {
      for (const { name } of [...a.attributes]) if (!b.hasAttribute(name)) a.removeAttribute(name);
      for (const { name, value } of b.attributes) if (a.getAttribute(name) != value) a.setAttribute(name, value);
      morph(a, b, force);
      if ("form" in a) {
        if ((a != D.activeElement || force) && a.value != b.value) a.value = b.value;
        a.checked = b.checked;
      }
    }
    a = na;
    b = nb;
  }
  while (a) { b = a.nextSibling; a.remove(); a = b; }
}
