## Images, icons and embedding

### Image formats

- **GIF** — up to 256 colors, one-bit transparency, animation. Its LZW compression was patented by Unisys, and the patent expired right around 2003–2004; it was the reason PNG appeared.
- **JPEG** — photographs.
- **PNG** (1996) — lossless, full color. IE up to and including version six did not show PNG semi-transparency without a special filter.
- **BMP** — the uncompressed Windows image; browsers displayed it, but its size made it unfit for large images.
- **favicon.ico** — the site icon in tabs and bookmarks, introduced by IE5 in 1999; the browser simply requests `/favicon.ico`.

### What Clipper's server draws

Clipper draws images itself, without libraries:

- **theme header gradients** — a BMP one pixel wide and as tall as the header, at `/g/height/colors.bmp`. The browser repeats it horizontally. BMP beats PNG here: its header is 54 bytes and its data is just pixels that need no compression. For an image one pixel wide, size does not matter;
- **badges** — small images with counters (`/x/b/reads.png?id=0`): our own PNG encoder and a 3-by-5 pixel font. The same badge exists as SVG — a 2001 format that 2003 browsers hardly displayed — and as JSON.

Images are also a response to an address. The server draws them from parameters in the address, and the browser caches them by address. No state.

### Embedding through an iframe

`iframe` is an HTML 4.0 element: a page inside a page. It was supported by IE3 and later and by Netscape 6 and later (not Netscape 4). It was a way to show a piece of one site on another without scripts.

Clipper lets you embed almost anything: a book card, a chapter, a poem, quotes, an author page, counters, a banner. Addresses like `/e/b/N` return small self-contained pages meant for a frame.

For the server, embedding is just one more kind of page. No API, no access keys and no library for the other site: the other site inserts `<iframe src="...">`, and that is all.

### The dumb server and other sites

Compare this with modern embedding: a widget script that loads onto someone else's page, goes to your server for data and builds markup on the client. The server then maintains an API, tracks versions of the widget script and answers for what that script does on other people's pages. An `iframe` separates the two: your server serves your page, and the other site decides only where to show it.
