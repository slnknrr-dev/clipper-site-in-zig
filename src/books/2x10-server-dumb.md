# Part III. The dumb, straight server

## How servers were built

### CGI: a process per request

The Common Gateway Interface (1993): for every request the web server starts a program, passes it parameters through environment variables and standard input, and sends the client whatever it printed. A program in Perl, C, shell — anything.

CGI is as straight as it gets. One request — one process — one response. No shared state between requests apart from files and the database. The program can be run by hand from a console to see what it prints. A bug in one request does not touch the others.

The price is starting a process for every request. With Perl that is tens of milliseconds just for startup.

### mod_perl, PHP, FastCGI

The answer to CGI's price: keep the interpreter loaded. mod_perl (1996) embedded Perl in Apache, PHP (as an Apache module) did the same for PHP, and FastCGI (1996) was a constantly running process to which the web server passed requests over a socket. The model stayed the same — "request in, response out, state in the database" — but without starting a process.

### Static files

The fastest 2003 site was a set of ready files. Apache served them by the thousand per second on the hardware of the time. Many sites generated pages in advance — on a schedule or when data changed — and served them as files. Forums did this for archives, news sites for their home pages.

### What they have in common

All three models share one property: **a page is a function of the address and the data**. Not of the history of the user's actions, not of the browser's state, not of what ran in a script. That is what makes a server "dumb and straight": a request in, a document out, and in between nothing that cannot be read top to bottom.

## Clipper as a dumb, straight server

Clipper takes the best from each model.

**From static files** — everything that can be built in advance is built in advance. The catalog lies in an immutable file in ready-to-send form; templates are parsed at compile time; guest pages are cached whole. A guest gets a page almost like a file: 70 thousand pages per second from one thread.

**From CGI** — straightness: one request — one response — one pass through the code. No background jobs, no queues, no state except the data in the store. Any request can be repeated and give the same response.

**From FastCGI** — a constantly running process with no startup per request, and when needed several such processes on one socket.

And one difference from all three: there is no separate web server. Clipper accepts connections itself, parses HTTP itself and sends the bytes itself. One program instead of a bundle of Apache, a module and a database.

### Why a dumb server is fast

Not because it is written in a fast language, but because it has little to do:

- a page depends only on its address — it can be cached;
- a page is a finished document of known length — it can be sent in one call;
- state is in the address, the form and the cookie — the server need not remember what happened before;
- the client computes nothing — the server need not provide an API in addition to the pages.

Each of these properties follows from the 2003 browser being dumb. A dumb client permits a dumb server.

### Why a dumb server is maintainable

Code that does the same thing for every request is easy to read, easy to verify and easy to fix. A test compares documents. A bug is reproduced by repeating the request. Ten years later a new person opens the handler for an address and sees what it does — from parsing parameters to the last byte of the response.

### Price

A dumb server cannot do what requires intelligence: live updates, personal feeds, collaborative editing. If the product requires these, another server is needed. Book 0 shows this boundary as a ladder: Clipper stands on the third step of five and deliberately climbs no higher.
