# Part V. The boundary with the outside world

## 2003-era pages and windows-1251

### Fork

What exactly the server sends to the browser, and in which encoding it stores text.

### Paths for markup

1. A modern frontend: scripts build the page in the browser, the server sends data.
2. Server-side markup with modern CSS and scripts for convenience.
3. HTML 4.01, tables, CSS level 2, scripts only where things are awkward without them — as in 2003.

### Choice

Path 3. A page without scripts depends only on its address — so it can be built once and served to everyone (that is what makes the guest page cache possible). It weighs 5–30 KB and opens in any browser on any device. It sets a ceiling on complexity: if a feature cannot be made from a form and a link, it most likely should not be made.

The only script is a custom context menu on the reading page for quotes and bookmarks (`oncontextmenu`, works from Internet Explorer 5 on). Below the text there is a form that does the same without the script.

**Dead end:** path 1 under the requirement of a dumb server. It moves work into the browser but does not remove it from the server: the server still sends data, checks rights and stores records, and on top of that serves a programming interface. And a page without scripts stops working altogether.

### Paths for encoding

1. **UTF-8 everywhere.**
2. **windows-1251 for pages and data, UTF-8 at the boundaries** (book files, exports, JSON).
3. **UTF-16 inside** (as in Windows and Java).

### Choice

Path 2. A Cyrillic letter is two bytes in UTF-8 and one in windows-1251. For Russian text that is almost half the memory, traffic and snapshot size. But the main gain is simplicity: one byte, one character.

- Lowercasing is a 256-entry table.
- Case-insensitive search is a loop over bytes.
- A string can be cut anywhere without splitting a character in half.
- A trigram is three bytes, that is, a number.

Characters outside the encoding are written in markup as `&#N;` — legitimate HTML 4. Source strings are re-encoded at compile time, so the program does not re-encode a single piece of interface text on request.

### A dead end found in practice

The language mechanism (`-Dlang`) at first knew Georgian. A check showed where that leads: in markup Georgian letters would pass as `&#N;`, but in data — headings, names, book text — they would turn into question marks, and the built-in book builder would refuse such text. To make a real Georgian version, pages, forms, search and the snapshot format would all have to move to UTF-8. Georgian was cut from the build: `-Dlang=ka` is an error rather than a silently broken site.

English fits into windows-1251 entirely, so the English build (`-Dlang=en`) is a real one: the interface from the `src/t9n/en.t9n` catalog and English built-in books. The pages still stay in windows-1251.

This is a good example of how a decision made for the speed of Russian text determines, a year later, in which languages the site can exist at all.

### Better — under other conditions

**UTF-8 — for a multilingual library.** If the site must hold books in any language, path 1 is the only honest one. The price: case by Unicode tables, string cutting with character-boundary checks, case-insensitive search that is non-trivial (German sharp s, Turkish dotted and dotless i), Russian text almost twice the size. Frame compression eats part of the difference, but not all.

**A mixed scheme.** Store UTF-8 and re-encode on output for Russian pages. You get the drawbacks of both paths: both the size and the work on request. Dead end.

### Price

Forms: the browser sends text in the page encoding, and characters outside it arrive as `&#N;` or are lost. Addresses typed by hand arrive in UTF-8, and the server must recognize that (`cp.looksUtf8` exists only because of this decision). Built-in books are built only from text that fits in windows-1251.
