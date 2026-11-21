## HTML 4.01: a document, not an application

### What there was

HTML 4.01 is a 1999 W3C recommendation. It has three variants:

- **Strict** — without deprecated presentational elements (`font`, `center`, color attributes); all styling is in stylesheets;
- **Transitional** — the same plus deprecated presentation; almost everyone wrote this;
- **Frameset** — for pages made of frames.

XHTML 1.0 (2000) is the same vocabulary in XML syntax. In 2003 people loved to declare it but almost always served it as ordinary HTML (`text/html`), and browsers read it as HTML. Real XHTML (`application/xhtml+xml`) IE6 did not understand at all.

### Why Clipper chose Transitional

The first line of every Clipper page:

```
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
```

Transitional — because the themes reproduce sites of that era, and they were styled with `bgcolor`, `width` and `align` attributes and tables. Such markup renders the same everywhere, including in browsers that know nothing of styles. Styles are added on top as an enhancement.

The `DOCTYPE` line is not a formality. Since IE6 (and earlier in IE5 for Mac and Mozilla) browsers choose a mode by it: with a full `DOCTYPE` and a DTD address — standards mode; without it or with an incomplete one — compatibility mode ("quirks mode"), where the old box model remains. Clipper gives a `DOCTYPE` without a DTD address — this turns on compatibility mode, in which tables and old attributes behave the way authors of those years expected.

### Tables for layout

Table layout is considered bad form today, and there are reasons: a table says "tabular data here", not "a menu column here". For screen readers that is bad.

But in 2003 a table was the only way to get columns that looked the same in all browsers. Clipper takes it deliberately: all four themes are tables with columns and header and footer bands.

The cost for the server is zero. The cost for the markup is a few extra bytes and semantics that are not there.

### What the server gets from the document model

An HTML 4.01 document is a finished thing. It does not load more of itself, does not build its own content and does not change after loading (apart from small things done by a script). For the server this means:

- **a page = the response to an address.** One request — one document. No "shell" that is then filled with data over ten requests.
- **the response can be cached as a whole.** It does not depend on what the browser does afterwards.
- **the response can be verified as a whole.** A test gets the page and compares text. Clipper's contract with the mockup works this way: 1200 cases, each a comparison of documents.
- **the response can be sent in parts.** The browser starts drawing a document without waiting for the end. The server can write as things become ready.

### What would change with modern markup

HTML5 added semantics (`nav`, `article`), forms with client-side validation, `canvas`, video. Almost none of this changes the server: semantic elements are the same bytes. Only what moves logic into the browser changes it: client-side field validation does not cancel server-side validation, and a `canvas` application requires data from the server, not documents. The document remains the cheapest kind of response for a server.
