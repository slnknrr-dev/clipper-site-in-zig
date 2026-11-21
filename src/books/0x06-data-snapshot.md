# Part III. Data

## The catalog: an immutable snapshot

### Fork

Where books, series, poems and people live, and how the server gets to them. The catalog is read thousands of times more often than it changes.

### Paths

1. **A relational database** (standalone or embedded, like SQLite). Queries in a query language, indexes, transactions.
2. **Book files on disk, parsed on request.** FB2 is kept as is; the server opens and parses it.
3. **Everything in process memory**, loaded at startup from the source files.
4. **One prepared file**, mapped into memory.
5. **An LSM store or generations** — as in the first version: a base snapshot plus deltas merged from time to time.

### Choice

Path 4. The file `library.N.snap` contains everything that belongs to the catalog, already in the form in which the server sends it: tables sorted, strings in the page encoding, book text cut into frames and compressed. The server maps the file into memory and does not parse it. "Find a book" is a binary search over a table, and the result is a slice of mapped memory.

The file never changes. A new book means a new file numbered one higher, and a pointer file `library.current` that is switched last. A running server notices the new pointer and moves to the new snapshot without a restart.

Why this is good: immutability gives the rest for free. No locks — nothing to protect. No corruption on a crash — the old file is intact until the pointer is switched. No warm-up — the operating system pages the file in. Several processes share one memory — it is the same file.

### File structure

```
Header | text frames ... | books | series | pieces | persons | pages | frames | list | blob
```

Tables are arrays of fixed-size records sorted by number. Strings in records are not pointers but "offset, length" pairs inside the file: a pointer in a file is meaningless, because on the next run the file will be mapped at a different address. All long strings live in a shared `blob` area. Lists (books of a series, books of an author) live in a shared `list` area, and the record holds a "start, length" pair into it.

Why binary search and not a hash table. There are few numbers (thousands), the table is sorted anyway, and a search over it is a dozen comparisons in memory that is already in the processor cache. A hash table would need one more structure in the file and would not give the in-order traversal that lists need.

On opening, everything that will be used as an index or offset is checked once. After that the code trusts the snapshot. Reading stays free, and a corrupted file is rejected as a whole.

### Dead ends

**Parsing on request (path 2).** Parsing FB2 takes milliseconds per book. A list page of fifty books is fifty parses. It can be cached, but a cache of parsed data is a snapshot, only built in a hurry and on the heap.

**Everything in memory from sources (path 3).** Works for a small library, but every start is a parse of everything. With thousands of books that is tens of seconds of startup, and each process keeps its own copy. A snapshot gives the same thing, parsed once and shared by all processes.

**A relational database (path 1)** is not a dead end in general but a dead end under this frame. It would solve problems that do not exist here (arbitrary queries) and bring a dependency the frame forbids. Without the dependency it means writing your own DBMS, which is bigger than all of Clipper.

### Better — under other conditions

**With a million books.** Rebuilding the whole snapshot for each new book becomes unacceptable: a file of gigabytes. Then path 5 is better: a base snapshot plus small delta generations merged in the background. The first version did exactly that. Here it was dropped together with the "million" goal, and it is a fair trade: minus a whole merge subsystem.

**With frequent catalog changes.** If books are uploaded every minute, rebuilding for each one is wasteful. It is better to accumulate changes and rebuild every N minutes, showing new books from records until the rebuild. Clipper rebuilds immediately because uploads are rare.

**With a different byte order.** The format is tied to x86: numbers are stored little-endian. On a big-endian machine the file cannot be read. A portable format requires byte swapping on every read — that is, giving up "reading is free". The question is removed by limiting the targets, not solved.

### Price

The file format is a contract. Change the structure and old snapshots cannot be read. That is why the snapshot is derived data: the source books lie next to it in `books/`, and the snapshot can always be rebuilt. Keeping in such a format anything that cannot be restored would be a mistake.

Built-in books (this one among them) live inside the program, and the snapshot on disk. After a program update the snapshot is rebuilt at startup if the fingerprint of the built-in books has changed. Without this an old folder would keep the old book — a bug found only when a living person opened the site.
