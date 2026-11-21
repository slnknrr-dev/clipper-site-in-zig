## Forms: the only way to tell the server something

### What there was

In 2003 a browser could send data to a server in one way — a form. A form is sent with two methods:

- **GET** — the fields are appended to the address (`/s?q=Taman`). For search and anything that does not change data: the address can be saved and sent on.
- **POST** — the fields go in the request body. For anything that changes data.

And with two body encodings:

- `application/x-www-form-urlencoded` — `name=value&name=value`, special characters as `%XX`;
- `multipart/form-data` (RFC 1867, 1995) — for file uploads; the body is parts separated by a boundary.

### Field encoding

The browser encodes fields in the page's encoding. A page in windows-1251 — fields arrive in windows-1251. A character not in the encoding is sent by the browser as `&#N;` or replaced with a question mark. The `accept-charset` attribute could change this, but browsers understood it differently.

For the server this means: a form's encoding is not data but an agreement with its own page. Clipper keeps it simple: all pages in windows-1251, all forms arrive in windows-1251. The exception is addresses typed by hand or coming from other sites' pages: they arrive in UTF-8, and the server recognizes it.

### Redirect after POST

If the server answers a POST with a page, the "reload" button will submit the form again: a second comment, a second order. The solution of the time is redirect after POST: the server records the data and answers "look over there" (303 See Other in HTTP/1.1, in practice often 302), and the browser does an ordinary GET.

Clipper does this everywhere: a comment is recorded — 303 to the comment's address; sign-in — 303 back to where you came from. This gives unambiguity: every state of the site has an address, and reloading a page changes nothing.

### Protecting a form from forgery

Someone else's page may contain a form that submits data to your site. The browser attaches your cookies, and the server decides it is you. In 2003 people thought little about this; today it is mandatory.

Protection in the spirit of the era — without scripts: the server puts a hidden field with a token into every form, the same token lies in a cookie, and on POST the server compares them. Someone else's page does not know the token. Clipper protects every POST this way.

### File uploads

`multipart/form-data` is the only way to upload a file from a browser of that time. The body may be large, and parsing it entirely in memory is not an option. Clipper accepts a book upload of up to 50 MB streamed to a file on disk and only then parses it.

### What a form gives a dumb server

A form is the simplest possible "client tells server" protocol. No schemas, versions or serialization: fields and values. The server parses one grammar and gets pairs of strings. Everything that arrives is checked right at the boundary, and after that the program works with parsed data.

Compare with an application where the browser sends JSON to an API: a schema, versions, serialization errors, a second validation path. A form means less code on the server and fewer places for a bug.

### Price

Without scripts a form means a page reload. Every action is a full round: request, redirect, new page. On a slow link this is noticeable. Clipper accepts it: pages are small, the round is fast.
