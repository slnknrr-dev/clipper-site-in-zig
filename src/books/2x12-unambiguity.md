## Unambiguity and primitiveness

### One page — one address

On the 2003 web everything a visitor sees is described by an address. Press "back" — you return to where you were. Copy the address — the recipient sees the same thing. Save it in bookmarks — a year later the same place opens.

Clipper keeps this property on purpose. The theme (`t=samlib-dark`) and the mobile version (`m=true`) are address parameters, not cookies, and the server carries them through all links and forms. A link with a theme sent to a friend will show them the same theme. The setting is not lost if cookies are disabled.

The price is that the server must append the parameters to every link. In Clipper the page writer handles this: an address opened with the `{U}` marker and closed with `{E}` gets the parameters by itself, and forgetting them is impossible.

### One action — one path

Every action is a form or a link handled by one handler. There is no second path "for the script". After a write — a redirect to the result's address. Reloading a page repeats nothing.

### Strict parsing

Unambiguity also concerns what the server accepts. A false address pairing — `/b/2/-1-1`, "a reply to itself" — gives 404, not "something similar". A malformed request gives 400.

There is also a place where Clipper does not keep unambiguity: a number with a leading zero (`/p/01`) opens the same page as `/p/1` — that is how the mockup behaves, and the server repeats it. A thing ends up with two addresses. It is a trifle, but duplicates in search engines and caches grow from exactly such trifles; it would be better to answer `/p/01` with a redirect to `/p/1`. A server that guesses what the client meant will one day guess wrong.

### Primitiveness as a property

Primitive does not mean bad. Primitive means made of a few simple parts, each of which can be understood separately. HTML 4.01 is a document. A form is name-value pairs. HTTP/1.1 is a request and a response. A cookie is a string. A site is assembled from these parts, and the server parses each part in a few dozen lines.

Compare with what the server must know if the client is an application: an exchange format, interface versions, client state, retries on a dropped connection, partial updates. Each of these is not only code but a contract that can be broken.

### Maintainability

A site made of primitive parts ages slowly. A 2003 page opens in a 2026 browser. A 1995 form submits the same way. A server that serves such pages need not be rewritten for a new framework every three years: its interface is standards that do not change.

This is the main argument of the book. The "web up to 2003" restriction was chosen not for the look but so that the site works for a long time, on anything and without constant care. The server for such a site can be dumb — and therefore fast, verifiable and understandable.
