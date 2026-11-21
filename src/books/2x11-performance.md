## Speed: the modem, the table and the bytes

### The 2003 link

Most users of the Russian web in 2003 were on a modem: 33.6 or 56 kilobits per second, in practice 3–5 kilobytes per second. A 30 KB page took six to ten seconds to load. Every kilobyte was noticeable.

Hence the rules of the era:

- a page — up to a few tens of kilobytes;
- styles and scripts — in separate files, so that the browser takes them from cache on the next page;
- images — only the needed ones, with dimensions given (`width`, `height`), so that the browser lays out the page before they load;
- a single-byte encoding instead of UTF-8 for Russian text.

### Tables and render order

2003 browsers often did not show a table until it was fully loaded: to compute column widths they need the contents of all rows. A page laid out as one big table stayed white on a slow link until the very end of loading.

The techniques against this: several tables in a row instead of one; explicit column widths; `table-layout: fixed` in the styles, which allowed drawing from the first row. For the server a simple rule follows: the top of the page — header and navigation — should go out first and be a separate table.

### Compression in transfer

HTTP/1.1 allowed compressing a response (`Content-Encoding: gzip`), and browsers announced support. But IE5 and IE6 had bugs with caching compressed responses and with compressed styles and scripts; many sites enabled compression only for HTML.

Clipper does not compress responses. This is a deliberate price of simplicity: compressing on every request is processor work, and a cache of compressed pages is a second cache. Pages are small, and on a 2026 network a difference of a few kilobytes is unnoticeable. **Better** would be to keep a compressed copy next to the ordinary one in the guest page cache and send it to those who ask. This is not done.

### The server and speed today

Today the link is not the bottleneck, but the server often is. The same rules work from the other side: a small page — less work to build; a finished document — one system call to send; styles separate with a long cache — fewer requests to the server. Clipper's measurements on one laptop: a page from cache — 0.86 ms on average, past the cache — about 4 ms; 70 thousand and 15 thousand pages per second from one thread.

A dumb server's speed is not the result of optimizations but the result of not doing anything extra. The 2003 rules, invented for the modem, turned out to be rules for the processor.
