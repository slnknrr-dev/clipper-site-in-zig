<script type="text/javascript"><!--
var cmSel = { text: "", para: null };
function cmEl(id) { return document.getElementById ? document.getElementById(id) : document.all[id]; }
function cmText() {
  if (window.getSelection) return String(window.getSelection());
  if (document.selection && document.selection.createRange) return document.selection.createRange().text;
  return "";
}
function cmPara() {
  var n = null;
  if (window.getSelection) { var s = window.getSelection(); if (s.rangeCount) n = s.getRangeAt(0).startContainer; }
  else if (document.selection && document.selection.createRange) n = document.selection.createRange().parentElement();
  while (n && !(n.id && /^p[0-9]+$/.test(n.id))) n = n.parentNode;
  return n ? n.id.substring(1) : null;
}
function cmHide() {
  var ids = ["cmenu", "cf-bookmark", "cf-quote"];
  for (var i = 0; i < ids.length; i++) { var e = cmEl(ids[i]); if (e) e.style.display = "none"; }
  return false;
}
function cmPlace(e, x, y) { e.style.left = x + "px"; e.style.top = y + "px"; e.style.display = "block"; }
function cmShow(ev) {
  cmSel.text = cmText(); cmSel.para = cmPara();
  if (!cmSel.text || cmSel.para === null) { if (!ev) alert(cmNoSel); return true; }
  var m = cmEl("cmenu"); if (!m) return true;
  var de = document.documentElement, bd = document.body;
  var sx = window.pageXOffset || (de && de.scrollLeft) || bd.scrollLeft || 0;
  var sy = window.pageYOffset || (de && de.scrollTop) || bd.scrollTop || 0;
  var x = ev ? (ev.pageX || ev.clientX + sx) : sx + 10, y = ev ? (ev.pageY || ev.clientY + sy) : sy + 60;
  cmHide(); cmPlace(m, x, y); m.cmX = x; m.cmY = y;
  return false;
}
function cmOpen(kind) {
  var f = cmEl("cf-" + kind), m = cmEl("cmenu"); if (!f) return false;
  f.elements["para"].value = cmSel.para; f.elements["text"].value = cmSel.text;
  var divs = f.getElementsByTagName("div");
  for (var i = 0; i < divs.length; i++) if (divs[i].className == "cq") divs[i].innerHTML = "";
  for (i = 0; i < divs.length; i++) if (divs[i].className == "cq") divs[i].appendChild(document.createTextNode("«" + cmSel.text + "»"));
  cmHide(); cmPlace(f, m.cmX, m.cmY);
  return false;
}
(function () {
  var t = cmEl("booktext"); if (!t) return;
  t.oncontextmenu = function (e) { e = e || window.event; if (e.shiftKey) return true; return cmShow(e); };
  var old = document.onmousedown;
  document.onmousedown = function (e) {
    e = e || window.event; var n = e.target || e.srcElement;
    while (n) { if (n.className == "cmenu" || n.className == "cform") return true; n = n.parentNode; }
    cmHide(); if (old) return old(e); return true;
  };
})();
//--></script>