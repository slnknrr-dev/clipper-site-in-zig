# Part I. The problem

## Problem statement

The question that started it all is an engineering one: how is a library with a community built if you build it today, and how cheaply can it be kept running?

There is a fashionable answer: a database, an application server, a cache, a queue, a load balancer, containers. It works, but its price is rarely said out loud. Five programs mean five configurations, five ways to fail and five security updates a month. A site for five thousand readers turns into a farm that has to be tended.

Clipper tests the opposite hypothesis: the same can be done with one program, if you honestly split the data into what almost never changes and what does, and never do on a request work that can be done in advance.

### Two adjectives

The problem is stated with two adjectives, each qualified with "enough".

**Fast enough in-memory storage.** Not the fastest, but fast enough that storage stops being the bottleneck. For a site this means: a catalog page is assembled without touching the disk and without parsing anything, and a member's post is not lost when the power cord is pulled.

**A dumb enough server.** Not the simplest, but one whose behaviour fits in your head in full. One thread. One event loop. Memory allocated at startup. No background jobs, pools or queues.

And the condition without which the first two would be trivial: **with this much functionality.** Blogs and articles, forums, anonymous boards with auto-deletion, members with rights, sessions, comments, quotes tied to a place in a book, bookmarks, upload of books in five formats and download in three, themes, embedding, sign-in from neighbouring sites. Writing a dumb server for a static site is easy. The interesting part is whether it stays dumb when people write on the site — and exactly where it stops being dumb.

### What counts as success

| requirement | how it is checked |
| the site behaves like the mockup | 1200 HTTP cases against the mockup and the server: status codes, redirects and page text match |
| bad input does not crash the server | tens of thousands of corrupted requests, forms and files: no panic, no 500, no leak |
| memory does not grow | process memory before and after 300 thousand requests: 100.6 and 100.7 MB |
| writes survive a crash | a journal with a torn last line opens without it and with everything else |
| the two stores are equivalent | one history of operations through both gives identical answers |
| no foreign code in the build | no C library, no third-party packages; targets are Windows from XP, 32 and 64 bit, and Linux |

The last row is a way to measure dependence on the environment. A program that runs on a 2001 system, by definition, demands nothing of a 2026 system. "Runs on XP" is easier to check than "minimal dependencies".

### What the problem excludes

- Not a million books. The first version aimed at a million and taught a lot, but here the size is "one community's library": thousands to tens of thousands of books.
- Not horizontal scaling. One machine; several processes on it — yes, several machines — no.
- Not a modern frontend. Pages are made with technologies up to and including 2003.
- No OCR of scans. Pictures in books were on this list at first too; later they came back — only from FB2 and EPUB: PNG, JPEG, GIF, WebP and SVG (chapter 0x16).

Each such refusal removes a subsystem from the program. The list of refusals is half the architecture, and the book will revisit it more than once: what if we had refused more, and what if less.

### Three attempts

Clipper was written three times. In this book the versions are called:

- **the first version** — written in Zig head-on, with special attention to storage. A million-book catalog, trigram search, zstd with dictionaries, memory profiles. The storage ideas come from it; so do the known dead ends.
- **the mockup** — a site in Bun, designed to agree on what the site should be like for people. It became an executable specification: tests compare the real server against it page by page.
- **the main version** — what you are reading. A merge of the first two and a global rewrite drawing on what they produced: the mockup's interface, the first version's storage design, pure Zig.

The first two versions were working tools and are not published; what remains of them in this book is conclusions and numbers.

The order is itself a finding of the research: first understand the data, then the interface, and only then write what will stay.
