---
title: The 2003 Web for the backend: dumb but straight servers
year: 2026
annotation: What the web could do up to and including 2003, and why it is still worth knowing for those who write servers. Browsers, HTML 4.01, CSS, HTTP/1.1, forms, ES3-level JavaScript, encodings, images, mobile pages — from the server's point of view: what it must do, what it need not do, and where simplicity gives speed, maintainability and unambiguity. Using Clipper as the example — with an honest list of the places where Clipper steps out of 2003. Text — CC BY-SA 4.0, code — MIT. Sources: https://github.com/slnknrr-dev/clipper-site-in-zig
---

## From the author

**The 2003 Web for the backend: dumb but straight servers**

Yury Slinkin, 2026

Clipper serves pages the way they were made in 2003: HTML 4.01, tables, forms, a little JavaScript that can be switched off. This is not nostalgia but an engineering decision, and this book explains it — not from the design side but from the server side.

The main idea of the book: the 2003 web was built so that the server could be dumb. A page depended only on its address. State lived in the address, cookies and forms. The browser computed nothing; it only displayed. All a server had to be able to do was receive a request, find the data and assemble a response. Such a server is easy to make fast, easy to verify and easy to maintain for twenty years.

The modern web moved a lot of work into the browser, and the server did not become simpler for it: it serves data, checks rights, maintains a programming interface and on top of that serves an application running on the client. This book is about the other path and what it costs.

### Who it is for

For those who write servers and want to understand which client capabilities make a server smarter and which do not. For those thinking about sites that must work for a long time, on anything and without upkeep. And for those who simply want to know how things were built when they were built more simply.

### How to read

First — the browsers and standards of the era: what existed, what worked, what did not. Then — the protocol, forms, scripts, encodings, images and mobile pages, each time with the question "what of this must the server do". Then — the dumb, straight server as an architecture: CGI, Apache, prebuilt pages, Clipper. At the end — where Clipper steps out of 2003 and why.

Relation to the other books: book 0 tells how Clipper works, book 1 what language it is written in. This one — what it sends to the browser and why exactly so.

### Licenses

Text — CC BY-SA 4.0, code — MIT. Author: Yury Slinkin, 2026, slnknrr.dev@gmail.com. Sources: https://github.com/slnknrr-dev/clipper-site-in-zig
