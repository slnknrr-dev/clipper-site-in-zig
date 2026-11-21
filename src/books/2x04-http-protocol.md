# Part II. Protocol and data

## HTTP/1.1: what a server must be able to do

### What there was

HTTP/1.0 (RFC 1945, 1996) — a connection per request, no mandatory site name. HTTP/1.1 (RFC 2616, 1999) — what the 2003 web stood on and still stands on:

- the `Host` header is mandatory — many sites on one address;
- a connection by default lives longer than one request (keep-alive);
- requests can be sent back to back without waiting for responses (pipelining; browsers hardly used it);
- a body can be sent in chunks (`Transfer-Encoding: chunked`);
- parts of a file (`Range`) — for resuming downloads;
- conditional requests (`If-Modified-Since`, `If-None-Match`) and the 304 response — "you already have it";
- cache control (`Cache-Control`, `Expires`).

Cookies are separate: first the Netscape specification (1994), then RFC 2109 (1997) and RFC 2965 (2000), which browsers never fully implemented; in practice everyone lived by Netscape's.

### What of this Clipper does

| capability | in Clipper |
| Host | mandatory; without it — 400 |
| keep-alive | yes; the connection lives until the client closes it or goes quiet |
| pipelining | yes; several requests in one packet are handled in order |
| chunked in a request | no — 501; forms and uploads do not need it, the length is known |
| chunked in a response | not needed: the response length is known before sending |
| Range | yes, for downloads; suffix ranges too |
| ETag and 304 | for static files and immutable files |
| HTTP/2 | no — 505 |

### The dumb server and the response length

The most important HTTP/1.1 property for a server is that a response can be sent with `Content-Length`. For that the length must be known before sending. A server that builds the whole page into a buffer and sends it in one piece always knows it. Hence simplicity: no chunked transfer, no streaming generation, no need to keep a connection in an "still writing" state.

Clipper builds every page in full into a 6 MB buffer, computes the length and sends the header and body in one system call. This is possible because a 2003 page is a finished document of reasonable size.

### Caching on the browser side

The fastest request is the one that never happened. HTTP/1.1 gives two ways to avoid it:

- **a lifetime** (`Cache-Control: max-age`) — the browser does not ask at all until it expires;
- **validation** (`ETag` and `If-None-Match`) — the browser asks "has it changed", and the server answers 304 without a body.

Clipper serves styles, logos and strip images with a long lifetime and a content-based tag. Pages — without a lifetime: they change with every comment.

### Strict parsing

A 2003 server was often lenient: it accepted `\n` without `\r`, extra spaces, malformed headers. Clipper is strict: lines only with `\r\n`, a header up to 8 KB, a POST must have a length. This is not pedantry. If a server and the proxy in front of it understand one malformed request differently, an attack is built on that (request smuggling over a shared connection). Unambiguous parsing is a security property.

### What 2003 HTTP lacks — and does not need

HTTP/2 and HTTP/3 speed up the main thing — many small requests over one connection. For a page that consists of one document, one stylesheet and a couple of images, the gain is small. A dumb page makes a fast protocol almost unnecessary.
