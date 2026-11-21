## Where 2003 ends

An honest book about the old web must say what was bad in it and where Clipper deliberately steps out of it.

### What the 2003 web lacked

- **Security.** TLS of that era was SSL 3.0 and TLS 1.0 with weak ciphers; https was used by banks and hardly anyone else. Passwords often travelled in plain text. Almost nobody thought about request forgery from other sites' pages.
- **Accessibility.** Table layout confuses screen readers; images without captions, styling through attributes.
- **Languages.** Single-byte encodings kept a site within one language and its neighbours.
- **Liveliness.** Nothing updated by itself.

### Where Clipper steps out of the era

| what | from | why |
| TLS 1.3 | 2018 | security; old browsers will not connect to Clipper over https, http remains for them |
| form forgery protection | practice after 2005 | without it a site with writes is vulnerable |
| Argon2id for passwords | 2015 | hashes of that era (MD5, crypt) have long been broken |
| CSS variables and prefers-color-scheme | 2016–2019 | one markup for all modes; in an old browser the colors are lost |
| meta viewport | 2007 | modern phones |
| IPv6 | long ago, but not in 2003 | the 2026 network |
| SVG badges | 2001, but with almost no support | PNG and JSON are next to them |

The rule by which these exits were made: **everything concerning security is from 2026; everything concerning markup and protocol is from 2003.** An old browser must get a working site, but the server must not be vulnerable for the sake of an old browser.

One exception to the rule is CSS variables. This exit was made for the server's convenience, not security, and it hurts old browsers more than the others: a theme loses its colors. The chapter on CSS describes how to fix this.

### What is worth taking today

Not tables and not windows-1251 — those are decisions for Clipper's task. The principles are worth taking:

- a page is a function of the address and the data;
- every action works without a script;
- state is in the address, the form and the cookie, not in the client;
- after a write — a redirect;
- parsing is strict, addresses are unambiguous;
- styles and images are separate, with a long cache;
- everything that can be built in advance is built in advance.

These principles are not tied to a year. They make a server dumb — and a dumb server is fast, verifiable and long-lived. The 2003 web simply left no other choice; today it has to be made deliberately.
