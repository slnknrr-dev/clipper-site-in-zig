---
title: Inside Clipper
year: 2026
annotation: A study of one online library: which paths existed, which turned out to be dead ends, and which decisions are better under which conditions. The main axis of the book is the trade-off between what a site can do and how simple its server can be: the less the site does, the dumber and faster the server may be, and vice versa. Data structures, storage, networking, caching, encoding, security, federation. Dedicated to the memory of Stiver. Text — CC BY-SA 4.0, code — MIT. Sources: https://github.com/slnknrr-dev/clipper-site-in-zig
---

## From the author

**Inside Clipper**

Yury Slinkin, 2026

In memory of Stiver.

You are reading book number zero. Nobody uploaded it: it is compiled into the server at build time and exists on every site built from these sources. The page you are looking at was served by the very code this book describes — so any claim in the book can be checked without leaving your chair.

This is not a manual and not a textbook. It is a research report. Its question: what has to be inside a library with a community — books, forums, members, quotes — for it to be fast, cheap and never fall over? The answer is not one decision but dozens of forks. For every fork the book lays out the paths: which was chosen, which were rejected, which proved a dead end, and which would have been better — under other conditions or with other resources.

The programming language and the web are barely discussed here. Where the server's design relies on a property of the language, the book refers to book 1, "Zig for the backend". Where it relies on browsers and standards — to book 2, "The 2003 Web for the backend". Both are built in with `-Dbooks=true` and live at `/b/1` and `/b/2`.

### Sources

All the code is here: https://github.com/slnknrr-dev/clipper-site-in-zig

File names in the book are paths relative to the root of that repository: `src/out.zig`, `build.zig`, `BACKLOG_RU.md`. The book itself is source code too: `src/books/0x*.md`, one file per page.

### Licenses

- The text of the book — Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0). You may copy, retell, translate and adapt it, commercially too — with attribution and under the same license.
- Clipper's code — MIT license.
- Author: Yury Slinkin, 2026, slnknrr.dev@gmail.com.

### How to read

The first pages are the dedication, the problem statement and the method. Then comes the main axis of the book: how a site's features determine how smart its server has to be. After that — one area per page: catalog storage, book text, members' records, search, networking, caching, moderation, encoding, security, federation. At the end — what the site can do, why this particular language was chosen, and what remains unverified.

Every area has the same shape:

- **fork** — what has to be decided;
- **paths** — what the options are;
- **choice** — what Clipper does and why;
- **dead ends** — what was tried or could have been tried, and why it does not work;
- **better** — which solution would be of higher quality, and under what conditions.

The last item matters most. A decision for which nothing better is named is either perfect or not thought through. There are no perfect decisions in this book.

### What the author warns about up front

About the library's contents. Clipper is an engine, not a collection. It neither calls for piracy nor helps it. The program contains not a single book, poem or record by anyone else: a fresh site holds only the books about itself, and everything else on it is written by people.

About the name. A clipper is a fast sailing ship. The ship in the logo stands for speed. Clipper is not Flibusta, not its copy and not a part of it.

About evidence. A claim counts as proven only if a test, a measurement or a found bug stands behind it. Where there is none, the book says "by construction" or "by reasoning". If the book and the code disagree, the code is right.

About numbers. Every number has conditions: machine, data, tool. Almost all measurements were taken on one laptop running Windows 11, with the client on the same machine and a ReleaseSafe build. That is neither the internet nor Linux.
