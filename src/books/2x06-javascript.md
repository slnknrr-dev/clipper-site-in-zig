## 2003 JavaScript: an enhancement, not a foundation

### What there was

JavaScript 1.5 in Netscape and Mozilla and JScript in IE implemented ECMAScript 3 (1999): functions, objects, regular expressions, exceptions. The document model was DOM Level 1 (1998): `getElementById`, `getElementsByTagName`, creating and inserting elements. IE5 and later also had its own `document.all`, Netscape 4 had `document.layers`.

There were few events: `onclick`, `onsubmit`, `onload`, `onmouseover`. The `oncontextmenu` event — the right mouse button — appeared in IE5 and was supported by Mozilla.

And there was a thing few people knew about: `XMLHttpRequest`. It appeared in IE5 (1999) as an ActiveX object and in Mozilla 1.0 (2002) as a built-in object. The word "AJAX" would be coined only in 2005. Before that, requests from a page were rare and almost always went through a hidden frame.

### The rule of the era: everything works without a script

A good 2003 site did not depend on JavaScript. A script added convenience — a hint, a field check, a dropdown — but every action could be done without it as well. This was called progressive enhancement.

### Clipper's script

In all of Clipper there is one script — the context menu on the reading page for quotes and bookmarks. Here are its first lines:

```
function cmEl(id) {
  return document.getElementById ? document.getElementById(id) : document.all[id];
}
```

`getElementById` if it exists, otherwise `document.all` for old IE. Then `oncontextmenu` on the book's text: select a fragment, press the right button — the site's menu with "Quote" and "Bookmark" opens. Shift plus the right button gives the browser's usual menu.

And below the text there is a "Mark a fragment" form that does the same thing without the script. Without a mouse, without JavaScript, in Lynx — a quote can still be made.

### Why Clipper does not use XMLHttpRequest

A quote could be sent without reloading the page. But then:

- the server would gain a second entry point for the same operation — a response with data rather than a page;
- the page would gain state that is not in the address: "the quote was sent but the page was not updated";
- the site's behaviour would depend on whether the script ran.

Each item makes the server smarter (book 0, the "features versus simplicity" axis). Clipper chooses reloading: one operation — one path — one address for the result.

### The script and the server

For the server the rule "works without a script" means a simple thing: every action is a form or a link, and therefore an ordinary request the server knows how to handle. A script can only help the user fill in a form. The server never trusts what a script did and never depends on it.

### Price

A site without requests from the page cannot update itself: new forum messages are visible after a reload. For a 2003 forum that was the norm; for a chat it was not. Clipper is not a chat.
