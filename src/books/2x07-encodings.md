## Encodings of the Russian web

### What there was

The Russian web of 2003 lived in several encodings at once:

- **windows-1251** — the Windows encoding; most sites and almost all users;
- **KOI8-R** — the Unix and mail encoding; many old sites and servers;
- **CP866** — the DOS encoding; by 2003 almost gone from the web;
- **UTF-8** — already supported by browsers but rarely used for Russian sites: twice as many bytes per letter on 56-kilobit modems.

Sites often served a page in several encodings at once — by the visitor's choice or by the browser's headers. There was a Russian build of Apache that re-encoded on the fly. Mojibake — text read in the wrong encoding — was commonplace.

### How the server announces the encoding

Two places, and both are needed:

- the response header `Content-Type: text/html; charset=windows-1251` — the browser sees it first;
- in the page itself `<meta http-equiv="Content-Type" content="text/html; charset=windows-1251">` — in case the page was saved to disk or the header got lost.

Clipper sends both.

### Why windows-1251 and not UTF-8

Book 0 covers this in detail; here — from the web's side. One byte per letter halved a page on a modem. For the server — one byte per character: case, search and string cutting without parsing multibyte sequences.

Characters outside the encoding are written in markup as numeric references `&#N;` — legitimate HTML 4.01, understood by every browser. The em dash, guillemets and ellipsis exist in windows-1251; arrows and mathematical symbols do not.

### What follows for the server

**One encoding inside.** A server that keeps text in several encodings will inevitably mix them up somewhere. Clipper keeps everything in windows-1251, and UTF-8 appears only at the boundaries: book files on input, exports and JSON on output.

**A form's encoding is the page's encoding.** The browser sends fields in the encoding in which it received the page. So if all pages are in one encoding, all forms arrive in it too.

**Addresses are the exception.** An address typed by hand in the browser's address bar is encoded by the browser in UTF-8. The server must be able to tell whether a parameter came in UTF-8 or in the page encoding. Clipper checks whether the bytes look like valid UTF-8 with non-ASCII characters, and if so re-encodes them.

### Price

A site in a single-byte encoding lives in one language and its neighbours. For a Russian-language library of 2003 that was natural. For a 2026 site it is a limitation that will one day have to be lifted: Georgian, for example, had to be cut from Clipper's build for exactly this reason.
