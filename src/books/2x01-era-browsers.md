# Part I. The era

## Browsers of 2003

### Who was on the market

By 2003 the "browser war" was over. Internet Explorer 6 (2001) was on the overwhelming majority of machines — it shipped with Windows XP. Alongside lived:

- **Internet Explorer 5 and 5.5** (1999–2000) — on Windows 98 and 2000, and IE5 for Mac with its own engine, the best of its time;
- **Netscape 4.x** (1997) — already outdated but alive in organizations; with its own poorly compatible document model (`document.layers`);
- **Netscape 6 and 7, Mozilla 1.x** (2000–2003) — on the Gecko engine, the first browser to take standards seriously;
- **Opera 6 and 7** (2001–2003) — fast and small, Opera 7 with the new Presto engine;
- **Safari 1.0** (2003) — on KHTML, just released for Mac; Konqueror on Linux;
- **text browsers** — Lynx, Links: no images, styles or scripts.

And a separate world of phones: WAP browsers with WML, Japanese i-mode with simplified HTML. More on that in the chapter on mobile pages.

### What this means for a server

First: a site that wanted to work "for everyone" had to work in both Netscape 4 and Lynx. So everything essential — text, links, forms — had to do without scripts and without styles. Scripts and styles were decoration only.

Second: browsers understood the same styles differently. The most famous difference is the box model: IE5 included the border and padding in a block's width, the CSS standard did not. The same width gave different blocks. Hence tables for layout: every browser drew a table the same way.

Third: the browser was dumb. It held no application state, did not fetch data by itself (almost — see the chapter on JavaScript), did not build a page from pieces. It received a document and displayed it. Everything a site "knew" about a visitor lay on the server, in the address or in a cookie.

The third point is the main one for this book. A dumb browser requires the server to send finished output. But finished output is easy to cache, easy to verify and easy to send fast.

### Question: why does this matter today?

Modern browsers still understand HTML 4.01, tables, forms and ES3 JavaScript. Backward compatibility is one of the few promises of the web that has been kept. A page made for IE6 will open in a 2026 browser, and open fast. The reverse is not true: a 2026 page will not open in IE6 at all.

So the "up to 2003" restriction does not cut off modern users. It cuts off only capabilities. And which capabilities a site needs is decided not by the browser but by the task.

### How Clipper chooses its audience

Clipper aims at browsers of the IE5 and Netscape 6 level and above: tables, CSS level 2 where it worked, `getElementById` (with a fallback through `document.all` for old IE) and the `oncontextmenu` event. Netscape 4 and Lynx get a working site without styling: everything is readable, all forms work. That is the test of "the essential works without scripts and styles".
